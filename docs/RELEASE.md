# Shipping a build

```
scripts/release.sh
```

That bumps `CURRENT_PROJECT_VERSION` in `project.yml` by one, regenerates the
Xcode project, then archives and uploads **iOS, tvOS and macOS** to App Store
Connect. Useful variations:

```
scripts/release.sh --platforms macos              # one platform
scripts/release.sh --build 18                     # a specific number, no bump
scripts/release.sh --build 18 --destination export  # local .ipa/.pkg, no upload
scripts/release.sh --archive-only                 # stop after archiving
```

Uploading is the one outward-facing step, and it consumes a build number
permanently. The script checks App Store Connect first and refuses to start a
six-minute archive it already knows will be rejected.

## Credentials

Two files in the home directory, read at run time and never hard-coded:

| File | What it is |
| --- | --- |
| `~/.app-store-connect-key.p8` | the App Store Connect API private key |
| `~/.app-store-connect-key.json` | `{"keyID": …, "issuerID": …}` beside it |

**`xcodebuild` cannot use the account signed into Xcode.** There is no
`Xcode-Token` keychain item for it to read, so every command-line invocation
prints `error: exportArchive No Accounts` and cannot mint or refresh a
provisioning profile. The API key is the only route from the command line, for
signing as well as for uploading. `scripts/asc-api.py` mints the ES256 JWT the
same key needs for direct API calls:

```
scripts/asc-api.py platforms                 # which platforms the record carries
scripts/asc-api.py builds --platform MAC_OS  # build numbers already spent
scripts/asc-api.py get '/v1/profiles'
```

## Signing as somebody else

Every Apple-account-specific value is in **`Signing.xcconfig`**: the team, the
bundle identifier, and the names of the two App Store profiles that Release pins
to. `project.yml` refers to them as `$(ISSA_TEAM_ID)`, `$(ISSA_BUNDLE_ID)`,
`$(ISSA_MACOS_PROFILE)` and `$(ISSA_TVOS_PROFILE)`, and `scripts/release.sh`
reads the same file to fill in the export plists, which carry no identity of
their own.

To build under a different account, do not edit that file — create
`Signing.local.xcconfig` beside it. It is gitignored, `#include?`d last, and
anything it sets wins:

```
ISSA_TEAM_ID = ABCDE12345
ISSA_BUNDLE_ID = com.yourname.issareader
```

The team identifier alone is enough to build and run. Shipping needs your own
App ID and profiles, and the App Group in the three `.entitlements` files plus
`CurrentBookSnapshot.appGroup` has to be renamed to match — those four are
literal strings on both sides of a container lookup, so they are changed
together or not at all.

## One team, one App ID, three different signing stories

The App ID is `UNIVERSAL`, so a single record and a single Apple Distribution
certificate cover all three platforms. How each archive is signed is not
uniform, and the reason is the same in two of the three cases: **automatic
signing mints a Development profile before it reaches the distribution one, and
a Development profile enumerates device UDIDs.** This team has registered iOS
devices and no others.

| Platform | Signing | Why |
| --- | --- | --- |
| iOS | automatic | there are registered iOS devices, so automatic works |
| tvOS | manual, pinned to `$(ISSA_TVOS_PROFILE)` | no registered Apple TV |
| macOS | manual, pinned to `$(ISSA_MACOS_PROFILE)` | no registered Mac |

macOS needs one thing the other two do not: **a Mac Installer Distribution
certificate**, because a Mac App Store upload is a signed `.pkg` and the `.app`
inside it is signed with a different identity. `-allowProvisioningUpdates` will
*not* create that certificate for you. Both macOS credentials were made through
the API on 2026-09-02:

```
# profile — note BOTH certificates. With only the distribution one, the export
# fails "Provisioning profile … doesn't include signing certificate
# '3rd Party Mac Developer Installer'".
scripts/asc-api.py post /v1/profiles <<'JSON'
{"data": {"type": "profiles",
          "attributes": {"name": "<the name in ISSA_MACOS_PROFILE>",
                         "profileType": "MAC_APP_STORE"},
          "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": "<bundle id record>"}},
                            "certificates": {"data": [{"type": "certificates", "id": "<Apple Distribution>"},
                                                      {"type": "certificates", "id": "<Mac Installer Distribution>"}]}}}}
JSON

# installer certificate — a plain RSA-2048 CSR, then import key and certificate
# together as a PKCS#12, which is the only format `security import` accepts here.
openssl req -new -newkey rsa:2048 -nodes -keyout k.key -out k.csr \
  -subj "/CN=<your name>/O=<your name>/C=US"
scripts/asc-api.py post /v1/certificates   # certificateType MAC_INSTALLER_DISTRIBUTION
openssl pkcs12 -export -inkey k.key -in cert.pem -out k.p12 -passout pass:…
security import k.p12 -k ~/Library/Keychains/login.keychain-db -f pkcs12 -P … \
  -T /usr/bin/productbuild -T /usr/bin/productsign -T /usr/bin/codesign -T /usr/bin/xcodebuild
```

Downloaded profiles go in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`
with the extension `.provisionprofile` on macOS (`.mobileprovision` elsewhere).

`scripts/export/macos.plist` pins **both** identities explicitly. Left to choose,
Xcode picked the installer certificate to sign the app with and failed with
"this identity cannot be used for signing code".

Replacing the **Apple Distribution** certificate invalidates every cached App
Store profile on the machine, and so breaks every other project signing with the
same team at the same time. The installer certificate is a separate type and
carries no such risk.

## The things no API can do

Two steps exist only as a checkbox in a web page. Both have cost real time.

- **CarPlay.** Identifiers → the App ID → **Capabilities** tab → "CarPlay Audio
  App" → tick → Save. Not the *Capability Requests* tab, which is where you ask
  for it and which still reads "No Status" afterwards. The writable
  `capabilityType` enumeration has 28 values and none of them is CarPlay.
- **Adding a platform to the app record.** App Store Connect → Apps → Issa
  record → **Add Platform** in the left sidebar → macOS. Until that is done a
  macOS upload is rejected, and `scripts/asc-api.py platforms` will show only
  `IOS` and `TV_OS`.

## Build numbers

One `CURRENT_PROJECT_VERSION` for every target, on purpose: App Store Connect
counts build numbers per platform, so sharing one keeps the three apps legible
as a single release. `manageAppVersionAndBuildNumber` is `false` in every export
plist, so a reused number fails loudly as
`ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE` rather than being silently renumbered.

## macOS App Store specifics

- **App Sandbox** is on in both configurations now. Debug signs with the Apple
  Development certificate rather than ad-hoc — ad-hoc gives the bundle a hash
  identifier, the sandbox cannot make a container from that, and the app trapped
  at launch. Debug deliberately carries no App Group, because that entitlement
  needs a profile and a macOS development profile needs a registered Mac;
  `PlaybackSettings` falls back to standard defaults when the group container is
  absent. Release has the group, granted by the store profile.
- **Hardened runtime** is on for Release.
- **`LSApplicationCategoryType`** is `public.app-category.books`. Without it the
  upload fails validation. `BOOKS` is a valid Mac App Store category — confirmed
  against `/v1/appCategories?filter[platforms]=MAC_OS`.
- A Release-signed build **will not launch on this machine** (`Launchd job spawn
  failed`): Gatekeeper refuses a Mac App Store signature outside the store. Test
  the sandboxed behaviour in the Debug build, which carries the same sandbox.

## Before a release: the layout sweep

```bash
scripts/layout-sweep.sh          # 375 / 402 / 440, about 8 minutes
scripts/layout-sweep.sh --all    # every width and the iPad, about 25 minutes
```

Builds once, then runs the layout invariants on one simulator at a time,
creating and **deleting** each device so peak disk is one of them. Contact
sheets land in `docs/screenshots/sweep/_sheets`, one per screen, every width
side by side with a hairline at `Metrics.screenMargin`.

Four of the recent shipped bugs were one bug — a subview with a rigid minimum
width larger than its container, or a margin that drifted from the token — and
each was found by eye, on one simulator, after shipping. Two of those four are
catchable by assertion. The other two are a control whose *inner* padding
drifted, and no assertion can see them: the text inside a `TextField` is not an
accessibility element and has no frame. **The contact sheets are the only
coverage for that class**, so do not drop them for being slow.

`LayoutInvariantsTests` is the test for the tests: it feeds the invariants
hand-built trees shaped like each of the four bugs and asserts that each one
fails. If those ever start passing, the sweep has stopped working.
