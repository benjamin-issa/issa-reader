#!/usr/bin/env python3
"""A very small Google Play Developer API client, for the Android app.

The Play Console's twin of `scripts/asc-api.py`: it authenticates as a service
account and makes the handful of calls a release needs. Every change goes
through an *edit*, Play's draft of the app's store state, which is committed at
the end of a command or deleted if the command fails part-way.

The service account's key is read, never hard-coded, from
`~/.google-play-sa-creds.json` or wherever `ISSA_PLAY_CREDENTIALS` points. The
account needs access to the app under Users and permissions in the Play Console.
The JWT is signed with `openssl`, so nothing beyond the standard library and
the system's openssl is needed.

    scripts/android-play.py status                      # the app's tracks and releases
    scripts/android-play.py listing Android/play/listing      # the store listing: text, icon, graphic, screenshots
    scripts/android-play.py upload <bundle.aab> --track alpha --notes <file>
    scripts/android-play.py upload <bundle.aab> --track internal --track alpha --notes <file>
    scripts/android-play.py upload <bundle.aab> --track internal --publish --notes <file>

`upload` creates the release as a draft, on every track named, from one
upload: Play takes a version code once, so a second upload of the same bundle
for another track would be refused. A draft, because Play takes only drafts
for an app that has never been published, and a draft is what the Console
then sends for review once the app's declarations are complete. With
`--publish` the release is rolled out instead: for internal testing, which
Google does not review, that puts it on the testers' phones within the hour.
See docs/RELEASE.md, "Android".
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PACKAGE = "com.benjaminissa.issareader"
HOST = "https://androidpublisher.googleapis.com"
UPLOAD_HOST = "https://androidpublisher.googleapis.com/upload"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
# Seconds a request may take; a bundle upload gets longer.
TIMEOUT = 60
UPLOAD_TIMEOUT = 600
LANGUAGE = "en-US"

_token_cache = {}


class PlayError(Exception):
    def __init__(self, status, message):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status


def _credentials():
    path = Path(os.environ.get("ISSA_PLAY_CREDENTIALS", Path.home() / ".google-play-sa-creds.json"))
    if not path.is_file():
        sys.exit(f"error: no service account key at {path} (or set ISSA_PLAY_CREDENTIALS)")
    return json.loads(path.read_text())


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _token():
    """An OAuth access token for the service account, minted once per run."""
    if "token" in _token_cache:
        return _token_cache["token"]
    creds = _credentials()
    now = int(time.time())
    header = _b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = _b64(json.dumps({
        "iss": creds["client_email"], "scope": SCOPE, "aud": TOKEN_URL,
        "iat": now, "exp": now + 600,
    }).encode())
    signing_input = f"{header}.{claims}".encode()
    # The key goes to openssl on a pipe, never to a file.
    read_fd, write_fd = os.pipe()
    os.write(write_fd, creds["private_key"].encode())
    os.close(write_fd)
    try:
        signed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", f"/dev/fd/{read_fd}"],
            input=signing_input, capture_output=True, check=True, pass_fds=(read_fd,),
        ).stdout
    finally:
        os.close(read_fd)
    assertion = f"{header}.{claims}.{_b64(signed)}"
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion,
    }).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(TOKEN_URL, data=body), timeout=TIMEOUT) as reply:
            _token_cache["token"] = json.load(reply)["access_token"]
    except urllib.error.HTTPError as error:
        raise PlayError(error.code, f"the service account could not sign in: {error.read().decode()[:300]}") from None
    except (urllib.error.URLError, TimeoutError) as error:
        raise PlayError(0, f"could not reach Google to sign in: {error}") from None
    return _token_cache["token"]


def call(method, path, body=None, *, data=None, content_type=None, timeout=TIMEOUT):
    """One request; JSON in and out unless `data` carries raw bytes to upload.

    `path` is under HOST, or a whole URL (the upload host's). HOST is read
    here, at the call, not bound as a default when the function is defined.
    """
    url = path if path.startswith("http") else f"{HOST}{path}"
    headers = {"Authorization": f"Bearer {_token()}"}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    elif data is not None:
        payload = data
        headers["Content-Type"] = content_type or "application/octet-stream"
    request = urllib.request.Request(url, data=payload, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            text = reply.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode()
        try:
            detail = json.loads(detail)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            pass
        raise PlayError(error.code, detail) from None
    except TimeoutError:
        raise PlayError(0, f"no answer from Play within {timeout} seconds") from None
    except urllib.error.URLError as error:
        raise PlayError(0, f"could not reach Play: {error.reason}") from None


def _app(path=""):
    return f"/androidpublisher/v3/applications/{PACKAGE}{path}"


class Edit:
    """An edit, committed on success and deleted on failure."""

    def __init__(self, commit=True):
        self.commit = commit
        self.id = None

    def __enter__(self):
        self.id = call("POST", _app("/edits"), {})["id"]
        return self

    def path(self, rest=""):
        return _app(f"/edits/{self.id}{rest}")

    def __exit__(self, kind, value, tb):
        if kind is None and self.commit:
            call("POST", self.path(":commit"))
        else:
            # Best effort, and never in place of the error that brought us here.
            try:
                call("DELETE", self.path())
            except Exception:
                pass
        return False


def status():
    """Each track and its releases, read through an edit that is then thrown away."""
    with Edit(commit=False) as edit:
        tracks = call("GET", edit.path("/tracks")).get("tracks", [])
    if not tracks:
        print("no tracks yet")
    for track in tracks:
        print(track["track"])
        for release in track.get("releases", []) or [{"status": "empty"}]:
            codes = ", ".join(release.get("versionCodes", [])) or "-"
            print(f"  {release.get('status')}: {release.get('name', '')} ({codes})")


def listing(directory: Path):
    """The contact details, the listing text, the icon, the feature graphic and the phone screenshots, replaced whole."""
    locale = directory / LANGUAGE
    text = {name: (locale / f"{name}.txt").read_text().strip() for name in ("title", "short_description", "full_description")}
    if len(text["title"]) > 30 or len(text["short_description"]) > 80 or len(text["full_description"]) > 4000:
        sys.exit("error: the listing text is over Play's limits (30, 80, 4000 characters)")
    graphics = locale / "graphics"
    screenshots = sorted((locale / "phoneScreenshots").glob("*.png"))
    details = directory / "details.json"
    with Edit() as edit:
        if details.is_file():
            # The app's contact details and default language: what the
            # listing shows under "App support".
            call("PUT", edit.path("/details"), json.loads(details.read_text()))
            print("  details: contact email, website and default language")
        call("PUT", edit.path(f"/listings/{LANGUAGE}"), {
            "language": LANGUAGE, "title": text["title"],
            "shortDescription": text["short_description"], "fullDescription": text["full_description"],
        })
        for kind, files in (("icon", [graphics / "icon.png"]), ("featureGraphic", [graphics / "featureGraphic.png"]),
                            ("phoneScreenshots", screenshots)):
            if not files or not all(f.is_file() for f in files):
                print(f"  {kind}: nothing to upload")
                continue
            call("DELETE", edit.path(f"/listings/{LANGUAGE}/{kind}"))
            for file in files:
                call("POST", f"{UPLOAD_HOST}{edit.path(f'/listings/{LANGUAGE}/{kind}')}?uploadType=media",
                     data=file.read_bytes(), content_type="image/png")
            print(f"  {kind}: {len(files)} uploaded")
    print(f"listing for {LANGUAGE} committed")


def upload(bundle: Path, tracks: list[str], notes: Path | None, publish: bool = False):
    """The bundle, uploaded once, and a release of it on each of `tracks`: a draft, or rolled out with `publish`."""
    with Edit() as edit:
        made = call("POST", f"{UPLOAD_HOST}{edit.path('/bundles')}?uploadType=media",
                    data=bundle.read_bytes(), content_type="application/octet-stream", timeout=UPLOAD_TIMEOUT)
        code = str(made["versionCode"])
        release = {"versionCodes": [code], "status": "completed" if publish else "draft"}
        if notes:
            release["releaseNotes"] = [{"language": LANGUAGE, "text": notes.read_text().strip()}]
        for track in tracks:
            call("PUT", edit.path(f"/tracks/{track}"), {"track": track, "releases": [release]})
    print(f"version code {code} uploaded as a {'published' if publish else 'draft'} release on {', '.join(tracks)}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    listing_parser = commands.add_parser("listing")
    listing_parser.add_argument("directory", type=Path)
    upload_parser = commands.add_parser("upload")
    upload_parser.add_argument("bundle", type=Path)
    upload_parser.add_argument("--track", action="append", dest="tracks",
                               help="internal, alpha (closed), beta (open) or production; repeat for several (default alpha)")
    upload_parser.add_argument("--notes", type=Path)
    upload_parser.add_argument("--publish", action="store_true",
                               help="roll the release out rather than leave a draft (internal testing goes live without review)")
    args = parser.parse_args(argv)
    try:
        if args.command == "status":
            status()
        elif args.command == "listing":
            listing(args.directory)
        else:
            upload(args.bundle, args.tracks or ["alpha"], args.notes, args.publish)
    except PlayError as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
