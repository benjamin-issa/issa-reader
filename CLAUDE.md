# Working on Issa Reader

## Before any release: test against Storyteller 2 and Storyteller 3

Every release — a TestFlight upload or an App Review submission — is tested
against **both** Storyteller generations, not one. The client supports both,
and each has shipped breakage the other could not show: 3.x answers the cover
route with a redirect that signed 1.2.0 out, and writes read-along entries 2.x
never did.

The servers are the ones pinned in `Tools/docker/compose.yaml`:

| Generation | Tag | Local address | Role |
| --- | --- | --- | --- |
| 2 | `web-v2.14.23` | `:8001` | release pin |
| 3 | `web-v3.0.0-beta.49` | `:8003` (`--profile v3`) | release pin |
| 2 | `web-v2.14.21` | `:8011` (`--profile legacy`) | compatibility smoke; required, because App Review runs it |
| 3 | `web-v3.0.0-beta.46` | `:8023` (`--profile legacy`) | compatibility smoke; recommended (the pin before beta.49) |
| 3 | `web-v3.0.0-beta.40` | `:8013` (`--profile legacy`) | compatibility smoke; recommended |

The two release pins are what "both servers" means below. Moving either pin —
a newer 3.x beta, or 3.0 going stable — means the whole run below again
against the new tag, and keeping the tag it replaced as a legacy row. How to
bring them up is in the README, under "A local server to talk to".

"All tests" means all of these, each against both servers where it talks to one:

1. **The package suites and the app suite**, every one, through
   `scripts/release-tests.sh`: `swift test --filter` each of `IssaCoreTests`,
   `IssaEPUBTests`, `IssaRenderTests`, `IssaPlaybackTests`, `IssaUITests` and
   `IssaAskTests`, one at a time, then `IssaSharedTests` through `xcodebuild
   test` on a simulator it creates and deletes. It sets `ISSA_RELEASE_RUN=1`,
   under which a suite whose input is absent records a failure instead of
   skipping, and it fails the run on any skipped test or any suite with no
   `Test run with` line; `.build/release-tests/summary.txt` is the record.
   The run includes the two real-model Ask suites (`RegressionQuestionsTests`,
   `SystemAnswerModelTests`), which need Apple Intelligence on and its model
   downloaded: a release run sees them run, and fails if they cannot. Only the
   two opt-in Ask recorders, `AskScorecardTests` (`ISSA_ASK_SCORECARD`) and
   `RethinkExperiments` (`ISSA_ASK_RETHINK`), are left out, by name. The
   suites carry captured responses and read-along books from every server
   generation above — in
   `Packages/IssaCore/Tests/Fixtures`, 2.14.21's at the top level, 2.14.23's
   in `v2-14-23/`, beta.40's in `v3/`, beta.46's in `v3/beta46/` and
   beta.49's in `v3/beta49/`, and the
   read-along books `readalong.epub` (2.x) and `readalong-v3.epub` (3.x) in
   the `Tests/Fixtures` of `IssaEPUB` and `IssaPlayback`.
2. **The real-alignment suites, with their files present.**
   `RealAlignmentTests` reads a read-along the 2.x server aligned
   (`/tmp/pw2.epub`); `RealAlignmentV3Tests` reads the ones the 3.x servers
   aligned: beta.49's (`/tmp/pw3.epub`, `/tmp/pw3-loop.epub`), beta.46's
   (`/tmp/pw3-beta46.epub`, `/tmp/pw3-loop-beta46.epub`) and beta.40's
   (`/tmp/pw3-beta40.epub`, `/tmp/pw3-loop-beta40.epub`), since upgrading a
   server does not re-align the books it already has. The seven files are
   kept in `Tools/docker/data/real-alignment/<tag>/` (gitignored) and copied
   into `/tmp` before the run. Outside a release run the suites skip when the
   files are absent; `scripts/release-tests.sh` turns that into a failure,
   so a release run has them in place and sees them run, not skip.
3. **Live checks, on every platform being shipped, against each server.** Sign
   in; the library and its covers load and the session survives them; Settings
   › Advanced shows the right server version; a book's status shows the
   server's label; reading a page saves a position (and, on 3.x, files a book
   that had no status); a read-along plays across the end of an audio file.
   Record which server each check ran against.

   On iPhone and iPad these run without the screen. `scripts/live-check.sh
   <server> <label>` installs the app fresh on a simulator (`--device` names
   one; the iPhone 17 Pro by default), pairs it by device code, drives every
   check above through `Apps/IssaLiveUITests`, then asks the server whether
   the position arrived, on 3.x whether the book was filed, and with
   `--audio` whether the read-along's position got past its first file. Its
   `.build/live-check/<label>/summary.txt` has a PASS or FAIL per check and
   is the record. Run it once per server per device, with `--audio` for the
   read-along (it plays through the speakers, so ask first) and `--fresh` to
   make the pairing a real one rather than a token the simulator kept.

   On Apple TV, `--platform tvos` runs `Apps/IssaLiveTVUITests` on the Apple
   TV 4K simulator, moving by the remote: the pairing, the library, the
   session surviving the covers and Settings' server version. The
   television shows no status label at all — a book opens straight into
   the read-along screen, which has none — so that check does not apply
   there. A page read and the read-along sit behind that screen, so on the
   television those two still need the screen. The Mac needs the screen for
   all of it: a signed Debug build, paired by device code (approved with
   `approve-device.mjs`, as the script does) and checked by hand.
   `scripts/mac-controls-check.sh <label>` then reads the running app's
   windows through the Accessibility API (the terminal running it needs
   Accessibility access in System Settings › Privacy & Security) and fails if
   any pop-up or pull-down is
   taller than a standard control or one a window should have is missing,
   writing `.build/mac-check/<label>.txt` as the record.

4. **The layout sweep** (`scripts/layout-sweep.sh`), which uses the built-in
   fixture rather than a server.

If either server cannot be brought up, the release waits. It does not ship on
the strength of one generation.

## Android releases

The Android app (`Android/`, phone and Android Auto) follows the same rule,
against the same servers. Every Android release, whether an upload to a Play
testing track or a production rollout, is tested against **both** release
pins, and against the legacy rows as "Older servers" below requires. "All
tests" on Android means all of these:

1. **Every module's suites**, through `scripts/android-release-tests.sh`. It
   runs each module's JVM and Robolectric tests through Gradle, one module at
   a time, under `ISSA_RELEASE_RUN=1`: `:core`, `:epub`, `:render`, `:playback`,
   `:ask`, `:ui`, `:render-android`, `:playback-android`, `:ask-android` and
   `:app`. It then verifies the screenshot baselines (`verifyRoborazziDebug`).
   It fails the run on any skipped test, any failure, or a module that ran no
   tests. `.build/android-release-tests/summary.txt` is the record.
   - **Fixtures.** The suites read the Swift suites' fixtures where they lie, in
     `Packages/*/Tests/Fixtures`, so every server generation's captured
     responses and both read-along books are decoded on Android too.
   - **Parser parity.** The run includes the chapter parser's parity check
     against the goldens in `Packages/IssaRender/Tests/Fixtures/parity/`.
     Those are written on the Mac by
     `ISSA_WRITE_PARITY_GOLDENS=1 swift test --filter ParityGoldenTests`, and
     written again and committed whenever the Swift parser's output changes.
     Absent goldens fail a release run on either platform: a position saved on
     one platform must land on the same sentence on the other.
   - **Real-model Ask suites.** `SystemAnswerModelTest` and
     `RegressionQuestionsTest` need Gemini Nano, which no emulator has. With
     `--ask-device <serial>` naming a phone that has it, they run there and
     must pass. Without such a phone to hand, the summary records them as NOT
     RUN, and only then may a release go ahead without them. The two opt-in
     recorders, `AskScorecardTest` and `RethinkExperiments`, are left out by
     name.
2. **The real-alignment suites, with their files present.** `:epub`'s
   `RealAlignmentTest` and `RealAlignmentV3Test` read the same seven
   `/tmp/pw*.epub` files as item 2 above, copied from the same place. Under
   the release switch they fail rather than skip when the files are absent.
3. **Live checks, against each server, on a phone or emulator running Android
   12 or later.** `scripts/android-live-check.sh <server> <label>` installs the
   app fresh (`--serial` names the device; the only one attached by default).
   It then:
   - pairs the app by device code, approved through `approve-device.mjs`;
   - drives the app through `Android/app/src/androidTest`'s live test: the
     library and its covers load and the session survives them, Settings ›
     Advanced shows the right server version, a book's status shows the
     server's label, and reading a page saves a position;
   - asks the server whether the position arrived and, on 3.x, whether the
     book was filed;
   - with `--audio`, checks that the read-along's position gets past its first
     file. It plays through the speaker, so ask first.

   `--fresh` clears the app's data so the pairing is a real one.
   `.build/android-live-check/<label>/summary.txt` is the record. Give an
   emulator the machine's LAN address, as a phone, not `10.0.2.2`: the
   server's sign-in has to see one host throughout.
4. **Android Auto, on the Desktop Head Unit, against each release pin.**
   `scripts/android-auto-check.sh <label>` walks the checklist:
   - the Recent, Library and Downloaded tabs;
   - playing from Recent;
   - the chapter queue;
   - the rate button;
   - voice search;
   - the steering-wheel bindings;
   - the error shown when signed out;
   - the hand-off to the reader when the car disconnects.

   `.build/android-auto-check/<label>.txt` is the record.
5. **The layout sweep.** `scripts/android-layout-sweep.sh` records every screen
   at 360, 375, 402, 412 and 440 dp. Its contact sheets in
   `docs/screenshots/android-sweep/_sheets` are compared by eye with the
   iPhone's in `docs/screenshots/sweep/_sheets`. As on the iPhone, they are the
   only coverage for a control whose inner padding drifted.

The Android code is held to "Older servers" below exactly as the Swift is.
Both platforms read the same fixtures, so a response captured for one is
decoded by the other.

## Older servers

The pins are what the client is tested against, not a new minimum. Every
release still works with `web-v2.14.21` and the 3.x betas up to `beta.40`
(and beta.46, the pin before beta.49):

- No code may need a route, field or behaviour that 2.14.21 or beta.40 lacks.
  Features are detected by what the server answers
  (`Session.probeCapabilities`), never by its version string; any newly
  decoded field is optional; a new probe uses only routes 2.14.21 serves,
  such as `GET /api/v2/user`.
- Captured responses are added beside the old ones, never in their place, so
  every unit run keeps decoding 2.14.21's, beta.40's and beta.46's next to the
  pins'.
- The real-alignment suites read books aligned by the older servers as well
  as the newer ones (item 2).
- Each release runs `scripts/live-check.sh --fresh` on an iPhone against the
  legacy servers too (`docker compose --profile legacy up -d`, then
  `setup.mjs` against `:8011`, `:8013` and `:8023`): against 2.14.21 it is
  required, since App Review's server runs it; against beta.40 and beta.46 it
  is recommended. Those
  runs also exercise the older device-approval page in `approve-device.mjs`,
  which the pins' runs no longer reach. An Android release does the same with
  `scripts/android-live-check.sh --fresh`: against 2.14.21 it is required,
  since Google Play's reviewers use the same server; against beta.40 and
  beta.46 it is recommended.

## The App Review server stays on Storyteller 2

The server Apple's reviewers sign into runs **Storyteller 2 (`web-v2.14.21`)
only**. Google Play's reviewers sign into the same server, under the same
rule. Do not upgrade it to 3.x, including after a release has been verified
against 3.x. Testing on both generations is for us; review is done on the stable
line. Its address, credentials and tooling are kept outside this repository and
stay there.
