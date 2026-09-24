# Working on Issa Reader

## Before any release: test against Storyteller 2 and Storyteller 3

Every release — a TestFlight upload or an App Review submission — is tested
against **both** Storyteller generations, not one. The client supports both,
and each has shipped breakage the other could not show: 3.x answers the cover
route with a redirect that signed 1.2.0 out, and writes read-along entries 2.x
never did.

The two servers are the ones pinned in `Tools/docker/compose.yaml`:

| Generation | Tag | Local address |
| --- | --- | --- |
| 2 | `web-v2.14.21` | `:8001` |
| 3 | `web-v3.0.0-beta.40` | `:8003` (`--profile v3`) |

Moving either pin — a newer 3.x beta, or 3.0 going stable — means the whole run
below again against the new tag. How to bring both up is in the README, under
"A local server to talk to".

"All tests" means all of these, each against both servers where it talks to one:

1. **The package suites and the app suite**, every one:
   `swift test --filter` each of `IssaCoreTests`, `IssaEPUBTests`,
   `IssaRenderTests`, `IssaPlaybackTests`, `IssaUITests` and `IssaAskTests`,
   then `IssaSharedTests` through `xcodebuild test`. They carry captured
   responses and read-along books from both generations
   (`Packages/IssaCore/Tests/Fixtures` and its `v3/`, `readalong.epub` and
   `readalong-v3.epub`).
2. **The real-alignment suites, with their files present.**
   `RealAlignmentTests` reads a read-along the 2.x server aligned
   (`/tmp/pw2.epub`); `RealAlignmentV3Tests` reads two the 3.x server aligned
   (`/tmp/pw3.epub`, `/tmp/pw3-loop.epub`). Both skip silently when the files
   are absent. A release run has them in place and sees them run, not skip.
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
   session surviving the covers and Settings' server version. A status
   label, a page read and the read-along sit behind the poster grid and the
   read-along screen, so on the television those three still need the
   screen. The Mac needs the screen for all of it: a signed Debug build,
   signed in through the browser and checked by hand.

4. **The layout sweep** (`scripts/layout-sweep.sh`), which uses the built-in
   fixture rather than a server.

If either server cannot be brought up, the release waits. It does not ship on
the strength of one generation.

## The App Review server stays on Storyteller 2

The server Apple's reviewers sign into runs **Storyteller 2 (`web-v2.14.21`)
only**. Do not upgrade it to 3.x, including after a release has been verified
against 3.x. Testing on both generations is for us; review is done on the stable
line. Its address, credentials and tooling are kept outside this repository and
stay there.
