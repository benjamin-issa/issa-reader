# Issa Reader

A native Apple client suite for **[Storyteller](https://storyteller-platform.dev/)** —
ebooks, audiobooks, and synchronised read-along on iPhone, iPad, Apple TV and the Mac.

Written in Swift 6 for iOS 26, macOS 26 and tvOS 26.

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
| Apple TV | Device-code sign-in, poster-shelf library, one-sentence-at-a-time read-along |
| Mac | Sidebar library, each book in its own window, menu-bar transport, `issareader://` links and Handoff |
| Widget | Current book, chapter and progress from a shared App Group snapshot |

`docs/VERIFICATION.md` records exactly what has been run, and what has not.

## Layout

```
Packages/
  IssaCore      models, networking, auth, sync, downloads
  IssaEPUB      EPUB container and package parsing, SMIL media overlays
  IssaRender    XHTML to styled text, TextKit 2 pagination, highlight geometry
  IssaPlayback  audio engine, read-along coordinator, control remapping
  IssaUI        design tokens, type ramp, bundled fonts
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
scripts/release.sh --archive-only             # archive all three apps
```

## Notes on the server

This client is written against Storyteller `web-v2.14.21`, the latest stable
tag, and is forward-looking about the rest: it probes for the endpoints the 3.x
line adds and lights them up when they are present, so a newer server gains
features without a client update. Settings shows which its server provides.

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
