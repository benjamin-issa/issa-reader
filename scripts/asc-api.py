#!/usr/bin/env python3
"""A very small App Store Connect API client.

`xcodebuild` cannot borrow Xcode's signed-in account — there is no
`Xcode-Token` keychain item for it to read — so every command-line dealing with
App Store Connect authenticates with the API key instead. This mints the ES256
JWT that needs and does one request.

Credentials live beside each other in the home directory and are read, never
hard-coded:

    ~/.app-store-connect-key.p8     the private key
    ~/.app-store-connect-key.json   {"keyID": ..., "issuerID": ...}

Usage:

    scripts/asc-api.py get  '/v1/apps?filter[bundleId]=<the app>'
    scripts/asc-api.py post /v1/profiles < body.json
    scripts/asc-api.py platforms                 # which platforms the record has
    scripts/asc-api.py builds --platform MAC_OS  # build numbers already spent
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

HOST = "https://api.appstoreconnect.apple.com"
# Seconds a request may take. Without one, a connection App Store Connect
# accepted and never answered held release.sh at its duplicate-build guard
# until someone pressed Ctrl-C.
TIMEOUT = 60


def _signing_value(key, default=""):
    """Read one setting out of Signing.xcconfig, letting the local file win.

    The same two files, in the same order, that Xcode reads through `#include?`
    and that `release.sh` parses — so which app record this talks to and which
    app the build produces cannot disagree.
    """
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    value = default
    for name in ("Signing.xcconfig", "Signing.local.xcconfig"):
        path = os.path.join(root, name)
        if not os.path.exists(path):
            continue
        with open(path) as handle:
            for line in handle:
                stripped = line.strip()
                if stripped.startswith("//") or "=" not in stripped:
                    continue
                name_part, _, val = stripped.partition("=")
                if name_part.strip() == key:
                    value = val.strip()
    return value


BUNDLE_ID = _signing_value("ISSA_BUNDLE_ID")


def _credentials():
    home = os.path.expanduser("~")
    key_path = os.path.join(home, ".app-store-connect-key.p8")
    meta_path = os.path.join(home, ".app-store-connect-key.json")
    for path in (key_path, meta_path):
        if not os.path.exists(path):
            sys.exit(f"missing {path} — see docs/RELEASE.md")
    with open(meta_path) as handle:
        meta = json.load(handle)
    with open(key_path, "rb") as handle:
        return meta["keyID"], meta["issuerID"], handle.read()


def _token():
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils

    key_id, issuer, pem = _credentials()
    key = serialization.load_pem_private_key(pem, password=None)

    def segment(payload):
        return base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=")

    now = int(time.time())
    signing_input = segment({"alg": "ES256", "kid": key_id, "typ": "JWT"}) + b"." + segment(
        {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"})
    # App Store Connect wants the raw r||s pair, not the DER sequence
    # `cryptography` produces.
    r, s = utils.decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    signature = base64.urlsafe_b64encode(raw).rstrip(b"=")
    return (signing_input + b"." + signature).decode()


def call(method, path, body=None):
    """Returns (status, decoded JSON).

    `path` is either a path on HOST or a full URL that App Store Connect
    handed back (a `links.next`), which must be on HOST: the token goes
    with the request, so a link anywhere else is refused, not followed.
    """
    url = path if path.startswith(("http://", "https://")) else HOST + path
    if not url.startswith(HOST + "/"):
        sys.exit(f"refusing to send the App Store Connect token to {url}")
    request = urllib.request.Request(
        url, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + _token(),
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {"raw": raw.decode(errors="replace")}
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        sys.exit(f"App Store Connect did not answer {method} {path} within {TIMEOUT} s: {error}")


def paged(path):
    """Every item of a list endpoint, following `links.next` to the end.

    One page is at most 200 items. Reading only the first was how the
    duplicate-build guard could miss a number once a platform had more
    uploads than that.
    """
    items, url = [], path
    while url:
        status, data = call("GET", url)
        if status != 200:
            sys.exit(f"HTTP {status}: {json.dumps(data)[:400]}")
        items += data.get("data", [])
        url = (data.get("links") or {}).get("next")
    return items


def app_id():
    status, data = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")
    if status != 200 or not data.get("data"):
        sys.exit(f"could not find the app record ({status}): {json.dumps(data)[:400]}")
    return data["data"][0]["id"]


def platforms():
    """The platforms the app record actually carries.

    A macOS upload is rejected until macOS is one of them, and no endpoint can
    add it — like the CarPlay capability, it is a checkbox in App Store Connect.
    """
    items = paged(f"/v1/apps/{app_id()}/appStoreVersions"
                  "?fields[appStoreVersions]=platform&limit=200")
    return sorted({item["attributes"]["platform"] for item in items})


def builds(platform):
    """Build numbers already uploaded for one platform.

    A build number is spent permanently on a successful upload, and
    `manageAppVersionAndBuildNumber` is false, so reusing one fails as
    ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE — better caught before the archive.
    """
    # Newest first, and every page: the numbers release.sh asks about are the
    # newest, and the server's default order is not documented.
    items = paged(f"/v1/builds?filter[app]={app_id()}"
                  f"&filter[preReleaseVersion.platform]={platform}"
                  "&fields[builds]=version&sort=-version&limit=200")
    return sorted({item["attributes"]["version"] for item in items},
                  key=lambda v: (len(v), v))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for verb in ("get", "post", "patch"):
        one = sub.add_parser(verb)
        one.add_argument("path")
    sub.add_parser("platforms")
    builds_parser = sub.add_parser("builds")
    builds_parser.add_argument("--platform", required=True,
                               choices=["IOS", "MAC_OS", "TV_OS"])
    args = parser.parse_args()

    if args.command == "platforms":
        print("\n".join(platforms()))
        return
    if args.command == "builds":
        print("\n".join(builds(args.platform)))
        return

    body = json.loads(sys.stdin.read()) if args.command in ("post", "patch") else None
    status, data = call(args.command.upper(), args.path, body)
    print(f"HTTP {status}", file=sys.stderr)
    print(json.dumps(data, indent=2))
    sys.exit(0 if 200 <= status < 300 else 1)


if __name__ == "__main__":
    main()
