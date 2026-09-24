# Issa Reader

A native Apple client suite for **[Storyteller](https://storyteller-platform.dev/)** —
ebooks, audiobooks, and synchronised read-along on iPhone, iPad, Apple TV and the Mac.

Written in Swift 6 for iOS 26, macOS 26 and tvOS 26, built with Xcode 27.

![Read-along on iPhone](docs/screenshots/ios-09-readalong-highlight.png)

## About Storyteller

[Storyteller](https://storyteller-platform.dev/) is a self-hosted platform that
automatically aligns an ebook with its audiobook, so you can move between
reading and listening and keep your place. It does the genuinely hard part:
transcribing the narration, matching it to the text, and writing the result into
the EPUB as standard [media overlays](https://www.w3.org/TR/epub-33/#sec-media-overlays).
Everything this app does with narration rests on that alignment.

- **Documentation** — <https://storyteller-platform.dev/>
- **Source** — <https://gitlab.com/storyteller-platform/storyteller> (MIT)
- **Self-hosting guide** — <https://storyteller-platform.dev/docs/installation/self-hosting/>
- **The official Storyteller apps** — <https://storyteller-platform.dev/docs/reading/storyteller-apps/>

Storyteller ships its own cross-platform apps, and they are the supported way to
read a Storyteller library. If you want the officially maintained client, start
there.

This project is independent and unaffiliated. It exists because a client written
for one family of platforms can lean on things a cross-platform one reasonably
does not: TextKit 2 pagination, WidgetKit, CarPlay, a tvOS app, a real Mac app,
Handoff between them. That is a narrower goal, not a better one.

No code is taken from Storyteller's own clients. This talks to a server over its
documented HTTP API, the same as any other client, and the alignment data it
reads is standard EPUB 3 — so nothing here requires Storyteller to change to
accommodate it.

## What works today

| | |
| --- | --- |
| Sign-in | Two routes on iPhone and Mac — the server's own login page in the system browser, or a pairing code — both ending in the same token. The browser route covers a password and every identity provider the server offers, so nobody has to know which kind of account they have. The device authorization grant ([RFC 8628](https://www.rfc-editor.org/rfc/rfc8628)) is the only route on Apple TV; verified end to end against Keycloak on iPhone and Apple TV |
| Library | Whole catalogue in one fetch, cached locally; instant search, and every shelf and Explore rail derived on device |
| Reader | Native TextKit 2 pagination, six bundled faces, four page themes, adjustable size and leading |
| Read-along | SMIL media overlays parsed into a book timeline; the highlight tracks real narration with exact glyph rectangles and turns pages to follow it |
| Playback | Variable rate with pitch correction, chapter and sentence navigation, Now Playing on the lock screen |
| CarPlay | Shelves and chapters as CarPlay lists, Now Playing, and a resume that lands on the sentence you left — the reader and the audiobook share one position anchor |
| Controls | Every external control remappable per surface — phone, CarPlay, headphones — including a car's steering-wheel buttons |
| Apple TV | Device-code sign-in, poster-shelf library, and a real page of the book with the spoken sentence highlighted, chapter marks on a timeline, and page turns from the remote |
| Mac | Sidebar library, each book in its own window, menu-bar transport, `issareader://` links and Handoff |
| Ask about a book | A question about the story so far, answered on the device by Apple Intelligence from the part you have actually read — never from further on. Off by default; iPhone, iPad and Mac with Apple Intelligence, not Apple TV |
| Widget | Current book, chapter and progress from a shared App Group snapshot |

## Layout

```
Packages/
  IssaCore      models, networking, auth, sync, downloads
  IssaEPUB      EPUB container and package parsing, SMIL media overlays
  IssaRender    XHTML to styled text, TextKit 2 pagination, highlight geometry
  IssaPlayback  audio engine, read-along coordinator, control remapping
  IssaUI        design tokens, type ramp, bundled fonts
  IssaAsk       per-book text index, bounded retrieval, on-device answering
Apps/
  IssaReader-iOS      iPhone and iPad, plus the CarPlay scene
  IssaReader-macOS    native Mac app
  IssaReader-tvOS     Apple TV
  IssaWidgets         WidgetKit extension
  Shared              views and app model used by more than one platform
Tools/
  docker    local Storyteller + Keycloak stack and its provisioning scripts
  scripts   fixture generation, and the app-icon generators (see Tools/design/app-icon/ICON.md)
  design    the app icon's SVG masters and spec
```

The Xcode project is generated: edit `project.yml`, then `xcodegen generate`.
It is not committed.

## Getting started

```bash
brew install xcodegen
xcodegen generate
swift test          # the package suites; no server needed
```

To sign and run on a device, create `Signing.local.xcconfig` next to
`Signing.xcconfig` with your own team:

```
ISSA_TEAM_ID = ABCDE12345
```

It is gitignored and overrides the defaults. `docs/RELEASE.md` covers what
shipping to TestFlight needs beyond that.

### A local server to talk to

```bash
cd Tools/docker
npm install
npx playwright install chromium
docker compose up -d
PUBLIC_HOST=$(ipconfig getifaddr en0) node setup.mjs
```

`docker compose up` brings up Storyteller `web-v2.14.21` and Keycloak;
`setup.mjs` waits for both, creates an admin account, wires Keycloak in as an
OIDC provider with group-derived permissions, and smoke-tests the endpoints the
client depends on. It is idempotent, and drives Storyteller's first-run screen
through Playwright's Chromium, hence the install step.

Everything must agree on **one host**. Auth.js sets the PKCE `state` cookie on
the origin that begins the OIDC redirect and reads it back on the callback, so
mixing `localhost` with the LAN address fails with "state value could not be
parsed" — and the LAN address is the only one a phone or Apple TV can reach.

```bash
node Tools/docker/verify-device-flow.mjs      # full sign-in round trip
node Tools/docker/verify-oidc-claims.mjs      # the claims Keycloak issues
scripts/release.sh --archive-only             # archive all three apps
```

The realm in `Tools/docker/keycloak/realm-issa.json` is imported only when
Keycloak does not already have it, so an edit to it takes
`docker compose up -d --force-recreate keycloak` before anything can see it;
`verify-oidc-claims.mjs` then says whether the tokens and userinfo carry
`email_verified` and the reader's group. Two things about that file are easy to
break. The `reader` user's `id` is pinned, because it becomes the `sub`
Storyteller links the account by, and a fresh one on re-import gets the sign-in
refused. And a client scope's `description` holds 255 characters: a longer one
stops Keycloak starting at all.

A Storyteller 3 beta can run beside it, on port 8003, for checking the client
against both generations. It needs its own **copy** of the library: 3.x
migrates the database one way, the stable server cannot open the result, and
the copy is tied to the `STORYTELLER_SECRET_KEY` it first boots with.

```bash
cd Tools/docker
docker compose stop && cp -Rp data/storyteller data/storyteller-v3 && docker compose up -d
docker compose --profile v3 up -d
STORYTELLER_URL=http://$(ipconfig getifaddr en0):8003 PUBLIC_HOST=$(ipconfig getifaddr en0) node setup.mjs
```

The provisioning scripts take `STORYTELLER_URL` for either server.

With a server up, `scripts/live-check.sh` runs the release rule's live checks
(CLAUDE.md) on an iPhone or iPad simulator:

```bash
scripts/live-check.sh http://$(ipconfig getifaddr en0):8003 v3-iphone
scripts/live-check.sh http://$(ipconfig getifaddr en0):8001 v2-ipad --device "iPad Pro 11-inch (M5)"
```

It installs the app afresh and signs it in by device code, approving the code
through `approve-device.mjs` as the fixture admin. `Apps/IssaLiveUITests` then
drives the real app through the library, Settings › Advanced's server version,
a book's status label and a page read, and the script asks the server whether
the position arrived and, on 3.x, whether the book was filed. `--audio` adds a
read-along crossing the end of an audio file, out of the speakers; `--fresh`
clears the simulator's keychain, so the pairing is a real one rather than a
remembered token. The verdicts, screenshots and the app's log land in
`.build/live-check/<label>/`. `--platform tvos` runs the television's share on
the Apple TV simulator, by remote: the pairing, the library, the session and
the server version.

## Notes on the server

This client is written against Storyteller `web-v2.14.21`, the latest stable
tag, and verified to behave the same against the 3.0 beta line
(`web-v3.0.0-beta.40`). It tells the two apart by feature, not by version
string: `GET /api/v2/server/public` exists only on 3.x, while a self-built 3.x
image reports its package version, which is still 2.14.21. Where they differ it
adjusts. Covers come from 3.x's content-addressed image route rather than the
cover route, which on 3.x only redirects. A status's label is shown where 3.x
lets an admin rename one. A book with no status, which 3.x allows and does not
advance, is shelved and advanced as 2.x would have. Settings › Advanced shows
the server's version beside the capabilities it offers.

The 3.x aligner also writes audio-only entries into read-along books — music,
credits, a chapter that is only narration — which share a sentence's place in
the text. Those are recognised from the book itself rather than the server,
because books aligned by either generation sit side by side on a 3.x server.

On 2.14.21, `GET /api/v2/books` takes no query parameters and returns the whole
library in one array, including this user's reading position and status. That
shapes the whole client, and in its favour: the catalogue is ingested once and
every search, filter and shelf is then built on device, which is faster than
round-tripping and works with no network at all.

A few details of the API are worth knowing if you are writing a client of your
own, and each is documented where the code handles it: dates arrive in three
formats and `StorytellerDate` parses all of them; `expires_in` on a token
response is not a duration, so validity is established by calling the API rather
than by arithmetic; `slow_down` in the device grant is a plain rate limit, so a
client should hold its polling interval steady rather than backing off the way
RFC 8628 §3.5 describes; and a book can be marked `ALIGNED` before its media
overlays are present, so narration is offered only once the timeline actually
has entries. All four were confirmed against a running instance, and all four
are straightforward to accommodate.

## Fonts

Six families ship with the app, all under the
[SIL Open Font License 1.1](https://openfontlicense.org/):

| | |
| --- | --- |
| [Literata](https://github.com/googlefonts/literata) | the default reading face |
| [Source Serif 4](https://github.com/adobe-fonts/source-serif) | |
| [Newsreader](https://github.com/productiontype/Newsreader) | |
| [Public Sans](https://github.com/uswds/public-sans) | also the interface face |
| [Lexend](https://github.com/googlefonts/lexend) | offered for reading proficiency |
| [OpenDyslexic](https://opendyslexic.org/) | |

Each licence is next to the fonts in
`Packages/IssaUI/Sources/IssaUI/Resources/Fonts/`.

## Licence

MIT — see [LICENSE](LICENSE). Storyteller itself is MIT, and the EPUB fixtures
used in the tests are Project Gutenberg texts.
