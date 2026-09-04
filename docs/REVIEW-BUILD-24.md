# Whole-repository review — build 24

Five `/code-review max` passes over `development @ 0cf8c34`, September 2026.
Every finding below is recorded, including the ones each pass ranked below its
own reporting cap. Nothing here has been fixed; this is the register, not a
changelog.

- **78 primary findings** — 9 critical, 41 high, 28 medium.
- **82 secondary entries** — real, verified, displaced by per-pass caps;
  a few group closely related items on one line.
- **2 claims disproved** and dropped, recorded in §2 so nobody re-files them.

Read §1 for what was and was not covered, §2 before trusting any single line,
and §11 if you only have an afternoon.

---

## 1 · Scope

| Pass | Target | Primary |
| --- | --- | --- |
| 1 | The build-24 sign-in rework (`1dcbef7..HEAD`, 18 files) | 15 |
| 2 | `Packages/IssaCore` | 15 |
| 3 | `Packages/IssaEPUB`, `IssaRender`, `IssaPlayback` | 14 |
| 4 | `Apps/Shared` | 15 |
| 5 | Platform targets, `IssaLayoutUITests`, `scripts/`, `Tools/scripts/`, `project.yml` | 20 |

Pass 1 is the one asked for as `max .`; it scoped itself to the last commit
range rather than the repository, which is why passes 2–5 exist. Six findings
were reached by more than one pass, are recorded once, and are marked
**corroborated** — so §3–§10 do not sum to the column above, and each pass's
below-the-cut list is folded into §11 rather than counted here.

Not covered: `Packages/IssaUI` was read only where other passes reached into it,
and the GRDB dependency was not audited.

---

## 2 · Corrections — do not re-file these

Two agent claims were measurably wrong. I tested both rather than relay them.

**`XMLParser` has no nesting cap.** One pass dismissed the stack-overflow
finding on the grounds that the parser rejects nesting past ~256. Measured:
depths of 200, 300, 1,000 and 50,000 all parse successfully with the exact
delegate configuration this code uses. F-4.3 stands.

**`appendParagraphBreak` is not quadratic.** One pass reported ~4×10⁹ character
copies per chapter from bridging `output.string as NSString` per block element.
Measured: 2,000 → 4,000 → 8,000 → 16,000 paragraphs runs 0.002s → 0.003s →
0.005s → 0.010s. Cleanly linear; the bridge is lazy. Dropped.

One finding is disputed and left in at reduced confidence: **F-8.13**, the
unbounded overlay placeholder. One agent's `ImageRenderer` probe saw truncation
rather than overflow. The configuration that would settle it (`--all`, at
accessibility-extra-large) was not run.

---

## 3 · Security · 9 findings

**F-3.1 · Critical · `IssaCore/Download/BookContentService.swift:115`** ·
corroborated ×3
Server-supplied `book.uuid` is interpolated into filesystem paths with no
validation, and `URL.appending(path:)` preserves `../` — verified by execution.
A hostile catalogue picks both path and bytes; `didFinishDownloadingTo` does
`createDirectory` + `moveItem` onto it, overwriting the preferences plist, the
SQLite catalogue or the App Group snapshot. The same uuid reaches
`Endpoint.files`, so CFNetwork collapses the dot segments and delivers the
`Authorization: Bearer` header to an arbitrary path on that host. Four sinks;
one `allSatisfy` at decode time closes all of them.

**F-3.2 · Critical · `IssaCore/Networking/ServerAddress.swift:60`** ·
corroborated ×3
A bare hostname probes HTTPS then silently falls back to cleartext HTTP, with
`NSAllowsArbitraryLoads` true in all three Info.plists and no
`NSAllowsLocalNetworking` or exception domains. An attacker who drops TCP to
:443 wins: the browser sign-in then opens `http://…/api/v2/token/app`, so the
server password and the 302 carrying the token both cross in the clear. The
only trace is one `IssaLog.warning`. This is what makes F-3.1 remotely
reachable.

**F-3.3 · Critical · `Apps/Shared/Sources/KeychainStorage.swift:48`** ·
corroborated ×2
The bearer token uses `kSecAttrAccessibleAfterFirstUnlock`, not the
ThisDeviceOnly variant, so it migrates in an encrypted backup — restoring onto a
second device yields a working credential documented as lasting thirty-five
years. The header justifies the weaker class by citing the widget, but no target
carries `keychain-access-groups` and the widget never touches the keychain.
Line 51 also discards every status code: `SecItemAdd`'s result is never read, so
a failed write is silent and the next launch drops to the sign-in form. On macOS
the query omits `kSecUseDataProtectionKeychain`, so items land in the legacy file
keychain where `kSecAttrAccessible` is ignored outright.

**F-3.4 · Critical · `IssaCore/Store/LibraryStore.swift:390`**
`setAccount` runs `UPDATE annotation SET account = ? WHERE account IS NULL`
unconditionally, and annotations written during an offline launch are NULL
because `enterLibrary` never ran. On a shared iPad, reader A's highlights and
quoted excerpts transfer to reader B on B's next sign-in. One-way, no undo, and
the class doc states annotations exist nowhere else.

**F-3.5 · High · `IssaCore/Auth/AppTokenGrant.swift:43`**
The sign-in callback is accepted with no origin, state or nonce binding — only
that the scheme is `storyteller` and `token` is non-empty. The session intercepts
that scheme from any navigation, and the login chain deliberately leaves the
reader's server for third-party IdPs. Over http an on-path attacker injects
`302 Location: storyteller://x?token=…`. A `state` parameter cannot be added
client-side (the server echoes nothing), so the fixes are refusing this route
over http and comparing the adopted identity against the stored account key.

> **Build 25 · partial.** The identity check landed —
> `AppModel.handOverIfTheAccountChanged(to:on:)` compares the adopted identity
> against `issa.account.<server>` and, on a mismatch, hands the device over
> cleanly instead of showing the arriving reader the departing one's shelf and
> posting the departing one's queued writes under the arriving one's token. A
> mismatch is not refused: a second reader on a household iPad is legitimate and
> is indistinguishable from an injected token from here. The browser row now also
> states, on an http server, that the sign-in page and the token it returns are
> both readable and the token replaceable.
>
> **The http refusal did not land and will not while 1.2 stands.** The residual
> is therefore unchanged: over http an on-path attacker can still inject
> `302 Location: storyteller://x?token=…` into the login chain, and this app will
> still adopt that token. What the identity check does is bound the blast radius
> and leave a trace. Over https the injection is not reachable at all —
> `ASWebAuthenticationSession` intercepts its callback scheme only from
> navigations inside its own web view. Reopen this if 1.2 is ever reopened.

**F-3.6 · High · `Apps/Shared/Sources/BrowserSignIn.swift:54`**
`prefersEphemeralWebBrowserSession = false` plus a route that mints a token with
zero interaction makes sign-out one-way. `Session.signOut()` has no handle on
Safari's cookie jar and `startURL` appends no `prompt=login`, so on a household
iPad reader B taps "In your browser" and lands in A's library holding a fresh
long-lived token.

> **Build 25 · won't fix, deliberately.** Non-ephemeral is the reason this route
> exists and `BrowserSignIn.swift:75` already says so: a reader already signed in
> to their library in Safari taps once and is done, which is what let the browser
> route replace the device grant on iPhone and Mac. Making the session ephemeral
> turns every sign-in back into a full login form and gives that up.
>
> The household-iPad case is **accepted, not overlooked**. What reduces it: the
> account hand-over added for F-3.5 means reader B landing in A's library is now
> a clean switch rather than A's shelf under B's name, and `Session.signOut()`
> revokes the token server-side rather than merely dropping it. What remains: B
> can still obtain a working token for A's account in one tap, because A's
> *browser* session was never this app's to end.
>
> Filed here so the next review does not re-file it as an oversight. Revisit if
> the server ever honours `prompt=login`, which would close it without costing
> the one-tap path.

**F-3.7 · High · `IssaEPUB/EPUBContainer.swift:125`**
The Zip64 EOCD magic is written as `0x06054B50` — the *regular* EOCD signature —
where APPNOTE 4.3.14 specifies `0x06064B50`. Every other signature in the file is
correct. Genuine Zip64 EPUBs are permanently unopenable (the download is cached),
and the guard rejects nothing: pointing `recordOffset` at the EOCD's own offset
satisfies it, after which count and offset are read from arbitrary trailing
bytes. The test suite encodes the bug, building a fixture with the wrong
signature and commenting that it is "the signature the parser checks for".

**F-3.8 · Medium · `Apps/Shared/Sources/Clipboard.swift:15`**
The diagnostics log and the device sign-in code go onto `UIPasteboard.general`
with no `.localOnly` and no `expirationDate`, so with Handoff on they sync to the
reader's other devices and are readable by any app they foreground.

**F-3.9 · Medium · `IssaCore/Diagnostics/LogStore.swift:184`**
`DiagnosticsView`'s `.task` unconditionally materialises the full plaintext log
to a date-named temp file — even if the reader never taps Share, and even
straight after "Clear log". No `.completeFileProtection`, never deleted. The real
log directory sets `isExcludedFromBackup`; this copy sidesteps all of it.

---

## 4 · Crashes · 6 findings

All uncatchable in Swift — Objective-C exceptions, index traps, stack
exhaustion. No `do/catch` on these paths helps.

**F-4.1 · Critical · `Apps/Shared/Sources/ReaderModel.swift:644`** ·
corroborated ×3
`playSelection()` passes an unvalidated `selection.location` to
`attribute(_:at:)`. It is the only reader of `selection` without a bounds check;
`selectedText` and `annotate` both verify `NSMaxRange`, and `locator(forRange:)`
carries a comment about this exact API raising. Reachable via a selection near
the end of a long chapter when narration crosses into a shorter one, since
`clearSelectionIfStale` only runs on the next view update.

**F-4.2 · Critical · `Apps/Shared/Sources/AppModel.swift:1497`** ·
corroborated ×2
`refresh(book:)` binds an index into `books`, suspends on the network, then
subscripts. `BookDetailView` fires it on every open. A concurrent sign-out
(`books = []`) or a refresh returning a shorter catalogue traps. The
non-crashing variant is worse: a reordered catalogue writes one book's server
data into another's slot, then persists it.

**F-4.3 · High · `IssaEPUB/XMLTree.swift:39`** · corroborated ×3
Every tree walk over an untrusted document is unbounded recursion —
`descendants`, `HTMLContentParser.render`, `SMILParser.walk`, `flatten`, and the
ARC release chain through `children`. 150,000 nested elements is ~1.2 MB of
XHTML that deflates to a few hundred bytes, a ~750:1 ratio that passes the
inflate ceiling. The iOS main-thread stack is 1 MB against macOS's 8, so the
real threshold is far below any desktop repro. See §2 — the "parser caps
nesting" objection is false.

**F-4.4 · High · `IssaEPUB/Inflate.swift:18`** · corroborated ×2
`plausibleCeiling = max(data.count * 1032, 64 * 1024)` bounds the compression
*ratio*, never the absolute size. A 4 MB entry declaring 4 GB uncompressed passes
and the next line does `Data(count: 4_000_000_000)` — jetsam kill, or an
uncatchable malloc abort. When `expectedSize` equals the ceiling the growth step
is a fixed point, so the allocation is attempted four times.

**F-4.5 · Medium · `Apps/Shared/Sources/ReaderModel.swift:1361, :1380`**
Two bare `spine[chapterIndex]` subscripts. `saveProgress` guards with
`spine.indices` and explains why: "a bare subscript here is the one place that
would trap rather than log." The `?? ""` defends only against a nil package.
`bookmarkOnCurrentPage` is read on every reader body pass.

**F-4.6 · Medium · `IssaPlayback/CommandMap.swift:302`**
One unrecognised enum raw value throws the whole decode, resetting every binding
and both skip intervals — verified by execution. Reachable by adding a case,
shipping, then rolling back. The initialiser's own doc asserts the opposite, and
`ReaderStyle.decodeCase` next door already solves it.

---

## 5 · Reading position · 9 findings

Four independently written "is this newer" rules that do not compose.

**F-5.1 · Critical · `Apps/Shared/Sources/AppModel.swift:932`** ·
corroborated ×2
Neither macOS nor tvOS ever flushes reading position. `flushOpenReaders()` has
exactly one caller, in the iOS target. The Mac has no `scenePhase` observer, no
`NSApplicationDelegate`, no `applicationWillTerminate`; the only save path is
`ReaderView.onDisappear`'s unstructured Task, and SwiftUI does not unmount the
hierarchy on termination. ⌘Q loses up to 20 seconds of turned pages, and the
queued write never leaves either because `drainPendingWrites()` never runs.
Pressing the TV button on tvOS is the same story.

**F-5.2 · Critical · `IssaCore/Sync/PositionGuard.swift:78`**
The high-water mark can only rise and has no re-baseline path. Guards are cleared
only on sign-out. Listen to 85% here, restart from chapter 1 on another device,
pull to refresh: `reconciled(with:)` correctly adopts the lower position, then
`start(atProgress:)` clears `steeredAt` so every tick writes as `.derived`, fails
the high-water test, and returns before both the queue and the store. The widget
advertises progress persisted nowhere. Only an explicit scrub clears it;
pressing Play cannot.

**F-5.3 · High · `Apps/Shared/Sources/AppModel.swift:1484`**
`writePosition` awaits a full network drain *before* persisting locally.
`enqueue` ends in `drainPendingWrites()`, one POST per item at URLSession's
60-second default. Offline, the queue row is written and the drain blocks; iOS
suspends the app and the local store was never updated — exactly what the
method's own doc says the code was changed to prevent. A one-line reorder of
1479 and 1484.

**F-5.4 · High · `IssaCore/Sync/MutationQueue.swift:71`**
The `supersedes` guard binds `ordering` with `let`, so it is skipped whenever the
queued row's ordering is NULL — which is every row written before migration
`v4-mutation-ordering`, added with no backfill. An out-of-order write then
deletes and replaces a row the doc calls possibly the only remaining copy of
where the reader is. The decoded payload carries a timestamp that would close
the gap.

**F-5.5 · High · `Apps/Shared/Sources/ReaderModel.swift:1333`**
`go(to annotation:)` falls through to resolving a foreign annotation's offset
against whatever chapter is loaded when the href matches no spine item — then
sets `.chosen` and schedules a save, an origin `PositionGuard` may not refuse.
Reachable after a publisher renames a chapter file.

**F-5.6 · High · `Apps/Shared/Sources/AppModel.swift:469`**
The detached `replaceCatalogue` task captures `store` by value, so `store = nil`
in `signOut` does not stop it. Sign-out suspends on its network POST, the task
interleaves, `clearAccountData()` runs its DELETE, and the previous account's
entire catalogue is re-inserted — the leak the `hasCredential` gate exists to
prevent.

**F-5.7 · High · `Apps/Shared/Sources/ReaderModel.swift:966`**
`reloadCurrentChapter()` anchors on `firstFragmentOnCurrentPage()`, which returns
the sentence straddling the page break — one that began on the *previous* page —
while `page(containingFragment:)` resolves by start. Every typography change
walks a narrated book backwards. `firstFragment(beginningOn:)` exists for exactly
this and `saveProgress` already uses it. `playFirstSentenceOnPage()` shares the
root cause.

**F-5.8 · Medium · `Apps/Shared/Sources/AppModel.swift:1381`**
`setRating` updates only the in-memory dictionary and never persists, unlike
`setStatus` two functions above. Rate offline, force-quit, relaunch offline: the
stars are gone. `refreshLibrary` compounds it by assigning server ratings
verbatim over an undrained queue, so an offline change flips back and then flips
again.

**F-5.9 · Medium · `IssaCore/Sync/MutationQueue.swift:183`**
`drain()` has no mutual exclusion and `pending()` never marks a row in flight, so
overlapping drains (from `enqueue`, reachability, `refreshLibrary`, foreground)
send the same write twice in no defined order. A collapsed row also inherits the
original `createdAt` while `pending()` orders strictly by it, so a later status
can be sent before an earlier position — and writing a position moves status
server-side.

---

## 6 · EPUB parsing · 11 findings

Most of these make ordinary, valid books fail. Several were confirmed by
executing the algorithm.

**F-6.1 · High · `IssaRender/HTMLContentParser.swift:355`** · corroborated ×2
The named-entity table covers only lowercase accented entities.
`replacingOccurrences` is case-sensitive, so `&Eacute;` or `&szlig;` reaches
`XMLParser` and fails with error 111 — verified. Any French or German book
opening a sentence with an accented capital has an unopenable chapter.
`&oelig;`, `&times;`, `&divide;` and the Greek block are missing too. Only books
carrying the long XHTML 1.1 DOCTYPE survive.

**F-6.2 · High · `IssaEPUB/SMIL.swift:9`** · corroborated ×3
`SMILClock` accepts non-finite and negative values — `"1e400"` is `+infinity`,
`"nan"` is NaN, `"-5"` is −5, all verified. One infinite duration makes every
later `cumulativeEnd` infinite, `progression(atBookTime:)` collapses to 0 for
every position, and `spineProgress` writes that 0 back as the reader's saved
place.

**F-6.3 · High · `IssaEPUB/SMIL.swift:81`** · corroborated ×3
`indexByFragment` is keyed on the fragment id alone, but EPUB requires ids unique
only *within* a document. A book numbering sentences per chapter makes every
navigation call resolve to chapter one: tapping a word in chapter 12 seeks to
chapter 1, end-of-track advance loops forever, and `narrationWindow` renders the
wrong chapter's sentences. `NarratedLine.id` is the fragment id, so SwiftUI also
gets duplicate Identifiable ids. Key on `(textHref, fragmentID)`.

**F-6.4 · High · `IssaEPUB/EPUBPackage.swift:145`** · corroborated ×2
`resolve()` mis-parses a fragment-only href: `"#ch2".split(separator: "#",
maxSplits: 1).first` is `"ch2"`, not `""`, because `omittingEmptySubsequences`
defaults true. Single-file books whose nav links to `<a href="#chapter-1">` get a
table of contents where every row points at a missing resource.

**F-6.5 · High · `IssaEPUB/Inflate.swift:38`** · corroborated ×3
`compression_decode_buffer` returns 0 for a valid stream decoding to zero bytes —
verified on the canonical `03 00` payload. Every branch fails, capacity cannot
grow, and after four iterations it throws `malformedArchive("inflate failed")`.
Python's `zipfile` writes empty members exactly this way, so a book with an empty
stylesheet has that entry permanently unreadable.

**F-6.6 · High · `IssaEPUB/Inflate.swift:42`**
"Buffer exactly full" is resolved as success. `compression_decode_buffer` returns
`dst_size` when output does not fit — verified, indistinguishable from a complete
result. An entry declaring 1,024 bytes that inflates to 40 KB returns the first
1,024 with no error: a chapter renders as a fragment, or an OPF is cut mid-tag
and the book reports `malformedPackage`, blaming the XML.

**F-6.7 · High · `IssaRender/HTMLContentParser.swift:218`** · corroborated ×2
Images are scaled to the column width only, never the page height.
`attachmentBounds` constrains width only, and `computePages`' anti-loop guard
gives the oversized line its own page whose content extent exceeds the canvas —
so the lower portion is painted outside it and turning forward skips past. No
page ever shows the bottom of a full-page plate.

**F-6.8 · Medium · `IssaEPUB/SMIL.swift:110`** · corroborated ×3
`documentRanges` merges two non-contiguous runs of one document into a spanning
range — the exact widening the `fileRanges` doc ten lines above forbids. For a
spine that revisits a document, the merged range swallows every intervening
chapter, corrupting the chapter scrubber and `spineProgress`.

**F-6.9 · Medium · `IssaEPUB/EPUBContainer.swift:176`**
Normalized entry keys collide and the last central-directory record wins. An
archive whose *first* `container.xml` is benign — what `unzip` and epubcheck show
— and whose trailing duplicate points elsewhere makes this reader load the
second. Shadows any spine document or `encryption.xml`. No duplicate detection.

**F-6.10 · Medium · `IssaEPUB/EPUBPackage.swift:228`**
A nav document that parses but yields no entries short-circuits the NCX fallback
the comment promises — it covers only the throwing case. A book whose nav uses
`<ul>` returns empty and the complete `toc.ncx` is never opened. Separately the
`epub:type == "toc"` test is exact equality on a space-separated token list, so
`epub:type="toc bodymatter"` is skipped.

**F-6.11 · Medium · `IssaEPUB/EPUBFontResolver.swift:236, :24`**
Two font bugs. The `CipherReference` URI is inserted un-normalized while
`chosen.path` was normalized, so an Adobe-obfuscated book writing
`URI="./OEBPS/fonts/Body.otf"` misses the guard and CoreText is handed XOR-
scrambled bytes. And the near-universal `url('fonts/X.otf?#iefix')` yields
extension `"otf?"`, so the reader is told a good OTF is unreadable.

---

## 7 · Audio & narration · 10 findings

`AudiobookCoordinator` was hardened against several of these; the read-along path
was written the same shape and never got the same fixes.

**F-7.1 · High · `IssaPlayback/AudioPlayer.swift:123`** · corroborated ×3
The audio session is activated on first play and never deactivated — `setActive(false)`
and `.notifyOthersOnDeactivation` appear nowhere in the repository. Music
interrupted by this app never receives the `.ended` interruption with
`.shouldResume` and stays silent until manually restarted.

**F-7.2 · High · `IssaPlayback/AudioPlayer.swift:254`** · corroborated ×3
`load()` writes `duration` and seeks across an `await` with no generation guard,
so a superseded load applies its values to the item that replaced it — the
highlight and the audio land on different sentences. `AudiobookCoordinator` has a
`loadGeneration` guard for exactly this, but it sits outside `player.load`, after
the damage; the read-along path has none.

**F-7.3 · High · `IssaPlayback/AudioExtraction.swift:35`** · corroborated ×2
Extracted audio is named by `lastPathComponent` only, so `Audio/ch01/track.mp3`
and `Audio/ch02/track.mp3` collide; the `fileExists` check then maps the second
to the first's bytes. Chapter 1's narration plays over chapter 12's highlighted
text for the whole book, and because `hrefs` is a `Set` the winner is not stable
between launches. Cached across sessions.

**F-7.4 · High · `IssaPlayback/ReadalongCoordinator.swift:146`** ·
corroborated ×2
`move(to:)` sets `activeEntry` itself and announces only the fragment, so a
chapter boundary coinciding with an audio-file boundary can never satisfy the
previous-document test. The page never turns, the highlight names a fragment not
in the loaded document, and `SleepTimer.chapterDidEnd()` is never called — the
book plays all night. `ReaderModel` documents this hole and patches it at its own
call site only.

**F-7.5 · High · `IssaPlayback/ReadalongCoordinator.swift:101`**
The end-of-file advance calls `play()` unconditionally. Pull AirPods at the
moment a chapter ends: the route handler pauses, then the queued
`advanceToNextFile()` resumes and the next chapter narrates aloud on the speaker.
Also resurrects playback after a phone call and after a sleep timer expires on a
boundary. `AudiobookCoordinator.advance()` guards this and has a regression test.

**F-7.6 · High · `Apps/IssaReader-tvOS/Sources/TVReadalongView.swift:29`**
The tvOS read-along screen never calls `model.setReaderVisible(true)` — the only
callers are in `ReaderView`, which tvOS does not render. So
`setHighFrequencyUpdates(false)` selects the 1.0 s idle observation interval over
0.20 s, and since `advance(to:)` is driven solely by `onTimeUpdate`, the sentence
highlight — the entire point of that screen — steps once a second and any
sentence shorter than the tick is never marked at all. `onVisibilityChanged` also
never fires, so `visibleReaderUUID` stays nil on tvOS.

**F-7.7 · Medium · `IssaPlayback/AudioPlayer.swift:152`**
`wasPlayingBeforeInterruption` is never cleared by a pause *during* the
interruption, so pausing on the lock screen mid-call still lets iOS resume the
book when the call ends.

**F-7.8 · Medium · `IssaPlayback/SleepTimer.swift:69`**
The duration timer counts wall-clock time regardless of playback and disarms
itself silently when it expires against a paused book — the moon reads "off" and
the reader presses play believing it is armed. No `deinit` cancelling the task,
and the mid-fade abandonment path returns without restoring volume.

**F-7.9 · Medium · `IssaPlayback/AudioPlayer.swift:256`** · corroborated ×2
`load(startAt: 0)` never resets `currentTime`, so for up to a second (the idle
interval, i.e. screen off) the player reports the previous file's position.
`previousChapter()` tests `currentTime > 3` against it and restarts the chapter
that just started.

**F-7.10 · Medium · `IssaPlayback/RemoteCommands.swift:55`**
`deinit` tears down the route observer but never the `MPRemoteCommandCenter`
targets — `handlers` was not hoisted into a non-isolated box and `tearDown()` is
main-actor isolated. The command centre is process-wide, so released instances
leave enabled commands whose blocks capture a nil `self` and still return
`.success`; iOS believes the command was handled and lock-screen controls become
dead no-ops.

---

## 8 · Sign-in, as shipped in build 24 · 15 findings

**F-8.1 · High · `Apps/Shared/Sources/SignInView.swift:264`**
The server-address field has no accessible name. `TextField("", text: $address)`
has an empty title and no prompt; the only descriptive string is the overlay
placeholder, which carries `.accessibilityHidden(true)`. VoiceOver announces a
bare "text field" on the app's first screen. No identifier either, so the layout
sweep's `field.` convention cannot key on it.

**F-8.2 · High · `IssaCore/Auth/AppTokenSignInFlow.swift:33`**
The only user-facing error tells the reader to try the username-and-password
route the same commit deleted. `BrowserSignIn.swift:59` names the renamed row.
The test asserts only `reason.contains("token")`, pinning the string without
catching the stale advice.

**F-8.3 · High · `Apps/Shared/Sources/SignInView.swift:331`**
A failed connect leaves the previous session intact, so the chooser and the
browser route target the *old* server. `connect`'s early returns fire before the
session is replaced and `serverURL` falls back to the existing session. Build 24
shortened this to one tap by returning a granted token off a single redirect.

**F-8.4 · High · `Apps/Shared/Sources/BrowserSignIn.swift:39`**
The `ASWebAuthenticationSession` completion handler discards the `NSError`, so
all three SDK failure codes collapse to "the reader closed the window" — no
message, no log, and the row can be tapped forever.

**F-8.5 · High · `Apps/Shared/Sources/SignInView.swift:148`**
The browser row is offered unconditionally with no capability check, and a server
lacking `/api/v2/token/app` dead-ends silently. The same diff deleted two working
probes that would have answered the question; `Endpoint.authProviders` survives
as a constant nothing reads.

> **Build 25 · closed.** `AppTokenGrant.isOffered(by:using:)` asks the route
> itself, unauthenticated, on an ephemeral session. It **fails open**: only a
> definite 404 or 405 hides the row, because a wrong "unavailable" hides the
> fastest way in from someone who has it while a wrong "available" costs one tap
> and lands on an error F-8.2 now words properly. The row is shown *disabled with
> the reason* rather than hidden — a row that silently disappears is the same
> failure as one that silently dead-ends. `Endpoint.authProviders` is untouched;
> it answers "does Auth.js exist", which is not the question.

**F-8.6 · Medium · `Apps/Shared/Sources/BrowserSignIn.swift:100`**
The presentation-anchor fallback fabricates a detached `ASPresentationAnchor()`
with no window scene — precisely the condition the SDK header warns produces
`presentationContextInvalid`, whose error F-8.4 then swallows.

**F-8.7 · Medium · `Apps/Shared/Sources/BrowserSignIn.swift:169`**
`finish()` has no task-identity guard, so a cancelled flow's outcome overwrites
the stage of the flow that replaced it and ejects the reader with the second
session live on screen. `begin()` is driven from `.onAppear`, which SwiftUI may
call again on the same view identity.

**F-8.8 · Medium · `Apps/Shared/Sources/DeviceSignIn.swift:45`**
`begin()` cancels the very task it is called from, so every device-code renewal
fails instantly and `maxRenewals` is dead code. On Apple TV, where the device
grant is the only route, a lapsed code gives "Couldn't sign in" instead of the
promised number changing on screen.

**F-8.9 · Medium · `IssaCore/Auth/AppTokenSignInFlow.swift:30`**
The route's only diagnostic records a provably constant value — `scheme` can only
be `storyteller`, since the callback is delivered only on a scheme match. The
diagnostic facts (which query-item names the server actually sent) are discarded,
and the `couldNotOpen` path logs nothing at all.

**F-8.10 · Medium · `IssaCore/Auth/AppTokenGrant.swift:35`**
The `isWebLink` guard the deleted flow carried was not re-established, so a
mistyped scheme reaches `ASWebAuthenticationSession`, `start()` returns false, and
the reader is told the browser failed and steered to a route that will fail
identically.

**F-8.11 · Medium · `Apps/Shared/Sources/SignInView.swift:130`**
Deleting `PasswordSignIn` removed the only log written when a credential crosses
a cleartext connection — at the same time as the credential became a long-lived
bearer token in a plaintext `Location` header. The surviving cleartext check
answers a different question and never fires for a typed `http://` address.

**F-8.12 · Medium · `Apps/IssaReader-tvOS/Sources/IssaReaderApp.swift:190`**
The tvOS placeholder silently lost `Palette.inkTertiary` in a change advertised
as being only about `verbatim`. Either the modifier was doing real work and the
placeholder now takes the system default on a ten-foot screen, or a prompt cannot
carry a colour — in which case the iOS overlay that cost F-8.1 was unnecessary.
Both cannot be true, and no build settles it.

**F-8.13 · Medium (disputed) · `Apps/Shared/Sources/SignInView.swift:265`**
The hand-rolled overlay placeholder has no `lineLimit` or `truncationMode` and
overlay does not clip, while `Typography.body` scales with Dynamic Type. See §2 —
one probe saw truncation instead, and the settling configuration was not run.

**F-8.14 · Medium · `README.md:22`, `docs/VERIFICATION.md:521`** ·
corroborated ×2
The README still reads "Three routes on iPhone and Mac" on a branch whose commit
is titled "Two ways in, not three". `VERIFICATION.md` asserts in the present
tense that the chooser "hides the password row", with a results table claiming
both were run — behaviour the next commit deleted, so it shipped in no build, in
a file whose third line reads "Nothing here is aspirational."

**F-8.15 · Medium · `IssaCore/Auth/DeviceGrant.swift:100`**
The surviving grant's type-level doc still describes the poll as "what runs
behind Continue in browser", inviting someone to wire the deleted flow back in.
`BrowserSignIn.swift:13/19/65/77` cite a poll, a task group and a `cancelAll()`
that exist nowhere — line 65 being the stated justification for the very
`finish(.byApp)` that makes the continuation one-shot.

---

## 9 · Main-actor stalls · 6 findings

**F-9.1 · High · `Apps/Shared/Sources/ReaderModel.swift:1143`** ·
corroborated ×3
In-book search parses and image-decodes every spine item on the main actor — an
unstructured `Task` inside a `@MainActor` class inherits main-actor isolation —
and `BookSearchView` fires it on every keystroke with no debounce. `Task.yield()`
yields only *between* chapters.

**F-9.2 · High · `Apps/Shared/Sources/DownloadsView.swift:229`** ·
corroborated ×3
`refresh()` is a synchronous whole-filesystem scan on the main actor: three
`stat`s per book plus two recursive directory walks over the extracted-audio tree
and the unbounded cover cache, re-run on every transfer state change. Keying on
`downloadsPending.count` also leaves totals stale when one transfer finishes as
another starts.

**F-9.3 · High · `Apps/Shared/Sources/ChapterListView.swift:60`** ·
corroborated ×2
`isCurrent(_:)` rebuilds the entire O(nav × spine) table of contents and re-walks
the page's attributes, and is called twice per rendered row.

**F-9.4 · Medium · `Apps/Shared/Sources/ReaderModel.swift:70`**
A cosmetic theme switch is in `needsReparse`, so changing page colour re-inflates
the chapter from the ZIP, discards every decoded plate, re-parses and re-lays
out. `style.didSet` also fires an unstored, uncancellable Task per assignment, so
holding the size stepper queues ~10 full reparses a second.

**F-9.5 · Medium · `Apps/Shared/Sources/BookDetailView.swift:902, :89, :46`** ·
corroborated ×2
Two whole-library grouping dictionaries rebuilt per body pass, the HTML blurb
re-parsed in `body`, and `book` resolved by O(N) scan at ~40 reads per pass — on
a screen that re-renders every two seconds while narrating, because it reads
`app.books`.

**F-9.6 · Medium · `IssaRender/Paginator.swift:518`, `HTMLContentParser.swift:258, :350`**
`draw(page:)` enumerates fragments from the document start, so drawing page N
visits all N−1 pages' fragments — from a `Canvas` closure re-rendering up to five
times a second during narration. `attributes(for:)` runs an uncached CoreText
descriptor match per text run when the distinct fonts number about twenty. And
`substituteNamedEntities` makes one full-document pass per entity.

---

## 10 · The safety nets themselves · 12 findings

The release guard and the layout sweep were both written to catch other bugs.
Each fails open, and the tests written to prove the sweep works cannot catch
that. Most of this is my own work from builds 23 and 24.

**F-10.1 · Critical · `scripts/release.sh:151`** · verified locally
The fixture-leak guard fails open. `grep -q` exits at the first match, `strings`
dies of SIGPIPE with output queued, and `pipefail` (set at line 17) promotes 141
to the pipeline status — so the `if` takes the else branch. Reproduced: a file
that *does* contain `IssaUITestFixture` reports `MISSED rc=141`; without pipefail
the same command reports `DETECTED`. The guard is correct only when there is
nothing to find.

**F-10.2 · High · `scripts/release.sh:148`**
Two more fail-open paths in the same loop. `nullglob` is not set, so an unmatched
pattern stays literal, `[ -f ]` skips it, and the script uploads having inspected
nothing — with no assertion that any binary was examined. `project.yml` sets no
`PRODUCT_NAME`, so the path match is incidental. And `strings` without `-` skips
the section Swift stores literals of ≤15 UTF-8 bytes in — measured on the real
13.4 MB Release binary. `IssaUITestFixture` survives only by being 18 bytes.

**F-10.3 · High · `project.yml:63`**
The "two independent gates" are one gate under two names.
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` appears twice in the whole generated
pbxproj: `DEBUG` on the project Debug config, and `"DEBUG ISSA_UITEST_FIXTURE"`
on the iOS app's Debug config. `ISSA_UITEST_FIXTURE` occurs nowhere else, so it
is exactly and only `#if DEBUG` — while three files assert it is a second lock.
Copy the Debug config for a Beta or TestFlight configuration and both flags
travel together, leaving only the guard that F-10.1 shows cannot fire. The value
also lacks `$(inherited)`. Deeper fix: `EXCLUDED_SOURCE_FILE_NAMES` for
`UITestSupport/*` on Release, so the compiler is never handed the fixture.

**F-10.4 · High · `Apps/IssaLayoutUITests/Sources/LayoutInvariants.swift:85`**
The system-subtree exemption is all-or-nothing. Once `containsOurContent` is true
for the `.tabBar` — which on iOS 26 is every signed-in screen, the reason the
check exists — the walk recurses into Apple's own buttons: type `.button`, none
of the five hardcoded system identifiers, no `rail.` ancestor. The margin
assertion then takes the minimum edge across them, so a screen whose content all
drifted to 140 pt passes as long as one system button sits near 16. It fails the
other way too, reporting Apple's metrics as this app's the first time they are
retuned.

**F-10.5 · High · `Apps/IssaLayoutUITests/Sources/LayoutInvariantsTests.swift:120`**
Every `XCTExpectFailure` in the tests-that-prove-the-sweep takes a bare
description and no `issueMatcher`, so each absorbs *any* recorded failure — and
the assertion under test has a second, unrelated failure path ("too few
measurable elements"). Revert the walk to skipping system subtrees on type alone
and `testTabBarHostingContentIsWalked` still passes, because the root is itself a
`.tabBar`, the tree is discarded, the minimum-samples failure fires, and the
expectation swallows it. These tests were the entire basis on which I reported
the sweep as validated.

**F-10.6 · High · `Apps/IssaReader-iOS/Sources/UITestSupport/FixtureLibrary.swift:67`**
The fixture books omit `status`, `createdAt` and `series`, so
`LibraryFilter.stage(of:)` files all six as unread, the recently-added rail is
empty, the series rail is empty, and "Also reading" is always empty. The
committed `library.png` confirms it: "Reading 0 · To read 6 · Finished 0" with a
book at 99%. `SeriesRail` — the one rail with a differently shaped header and the
sole producer of `rail.series` — is never measured at any of the eight widths.

**F-10.7 · High · `Tools/scripts/make-contact-sheet.py:80`**
Panels are normalised to constant pixel *height*, not constant points-per-pixel.
Computed from the committed screenshots: 375 pt → 506 px, 402 pt → 414 px,
440 pt → 414 px, summing with gaps to exactly the 1446 px of every committed
sheet. The docstring claims a 440 panel is 17% wider than a 375; in fact the 375
is 22% wider and two widths are pixel-identical. The tangerine 16 pt guides
inherit the same factor and land at 22, 16 and 15 px for one token — on the
sheets documented as the only coverage for the drift the frame assertions cannot
see.

**F-10.8 · High · `Apps/IssaLayoutUITests/Sources/LayoutReference.swift:48`**
A probe that parses wrong degrades to a green sweep asserting nothing. The parse
guard swallows every failure, so `read` succeeds whenever the element merely
exists; then `fields["margin"] ?? 16` restores the duplicated token this file's
own doc forbids, and `?? 0` makes `safe` equal the whole window, disabling the
safe-area half of two invariants. `LayoutProbe` is also a struct with no stored
properties, so SwiftUI runs its body once and latches `ReaderInsets.current()` —
benign only because all eight rows are portrait.

**F-10.9 · High · `Apps/IssaReader-iOS/Sources/UITestSupport/UITestFixture.swift:33`**
`installIfRequested()` writes the stub host into persistent `UserDefaults` — the
exact hazard its own doc comment says a launch argument was chosen to avoid — and
never removes it, not even on sign-out. Run the sweep with `--keep-devices`, then
launch the app normally: `issa.lastServer` still names the fixture host, so
`connect()` issues real cleartext requests to a host that does not resolve, with
ATS permitting it. The write is also unnecessary; the argument domain already
wins.

**F-10.10 · High · `Apps/IssaReader-iOS/Sources/IssaReaderApp.swift:275`**
`flushOnSuspend` abandons the flush entirely when `beginBackgroundTask` returns
`.invalid` (Background App Refresh off, Low Power), skipping even the on-device
`saveProgress()`. Separately, `identifier` is a local var captured by both the
expiration handler and the Task, so Swift boxes it and both see one storage; the
paths are not mutually exclusive, so `endBackgroundTask` can be called twice or
on `.invalid` while the real assertion is never ended — the outcome the comment
claims to prevent.

**F-10.11 · High · `Apps/IssaReader-macOS/Sources/IssaReaderApp.swift:52`**
`nowPlaying.configure(settings:)` runs from three macOS scenes and again for
every reader window, and is not idempotent — each call installs a fresh
self-re-arming `withObservationTracking` chain that nothing removes. Open a dozen
books and the next nudge of the skip interval fires fourteen
`remote.activate()` cycles, tearing down and re-registering the whole
`MPRemoteCommandCenter` target set each time.

> **Build 25 · closed.** Two guards. `configure` returns early when handed the
> same `PlaybackSettings` instance again, which covers every one of those scenes
> since they are all given the same `@State`-owned object; and the observation
> chain carries a generation, bumped by each real reconfiguration, so a chain
> installed against a *superseded* settings object stops re-arming instead of
> republishing forever. `NowPlayingController.remoteActivations` counts the
> cycles and is what the tests assert on — three configures produce one, and one
> change to the skip interval produces exactly one more.

**F-10.12 · Medium · `scripts/layout-sweep.sh:96`**
`$WORK` is cleared but `$OUT` never is, and the contact-sheet step is wrapped in
`|| true` while the script unconditionally prints its output path. Run `--all`
then the quick pass and the sheets mix three fresh panels with five from the
older build, unmarked. On a machine without Pillow the import raises, `|| true`
swallows it, every device reports "ok", and the script names a directory it never
wrote. The zero-tests guard exists against exactly this for the test action; the
screenshot half has no equivalent.

---

## 11 · Everything else · 82 secondary entries

Verified, but displaced by each pass's reporting cap. Grouped by area.

### IssaCore

- `Session.restore()` can never reach `.expired` — `loadIdentity` hard-codes
  `.signedOut` on 401 and the invalidation handler bails unless already
  `.signedIn`, so a returning reader with a lapsed token gets the blank server
  form the state exists to avoid.
- `APIClient.download` re-implements error mapping: 403 becomes "The server had a
  problem (403). It may be restarting", and FileManager failures escape as raw
  `CocoaError` rendering as "Something went wrong."
- `LogStore` is never flushed on suspend or terminate, so the entries immediately
  before a crash — the ones it exists to capture — are lost.
- `refreshLibrary` reconciles against in-memory `books` rather than persisted
  rows, so on the token-expiry path `replaceCatalogue` overwrites positions
  `recordPosition` wrote to disk.
- A book deleted server-side leaves its EPUB (often 300 MB–1 GB) on disk with no
  row and no prune API.
- `sessionDidBecomeInvalid` clears `tasks` but not `pausing`, stranding a marker
  that freezes a row at "downloading" with every control dead.
- `DurationText` and `hasRoom` guard `isFinite` but not magnitude, so
  `Int(seconds.rounded())` traps on a corrupt server value.
- The `st_token` playback cookie is scoped to path `/` with no `Secure`, and
  track URLs are built from an unvalidated server href that preserves `../`.
- `LibraryStore.upsert` rewrites all fifteen columns and re-fires the FTS5
  triggers every two seconds during narration, to move one progress number.
- Dead: `Endpoint.token`/`validate`/`authProviders`/`read`,
  `ServerCapabilities.unifiedEvents`/`sidebar`/`nextUp`, all of
  `LibraryMutationService`, `LibraryDerivation.tagCounts`. Two of the six
  sign-in probes set flags nothing reads.
- `TokenStore`'s doc and `MutationQueue`'s init comment both describe code that
  no longer exists; the nil-last comparator is written five times across two
  files.

### EPUB / Render / Playback

- `EPUBFontResolver.blocks` lets `depth` go negative on a stray top-level `}` and
  then finds no `@font-face` or `body` rule for the rest of the sheet;
  `@media`-wrapped body rules are invisible for the same reason.
- `EPUBContainer.swift:98` — stored entries bypass every size check, so
  `size(of:)` and `read().count` can disagree by 4 GB. One declared
  `uncompressedSize` of ~4.29e9 makes every real chapter's progress share round
  to zero for the whole book.
- `XMLTree.swift:111` — de-prefixing attributes clobbers real ones in
  `Dictionary` order, which is per-process random. `<item href="a" opf:href="b">`
  resolves to either at random, so the same book parses two ways on two opens.
- `Paginator.sentenceRange(at:)` re-implements the nearest-enclosing-fragment
  search 80 lines from `fragmentID(at:on:)` but drops the deterministic tie-break
  that code carries a four-line comment explaining — and iterates
  `fragmentRanges.values`, so it *cannot* tie-break by id.
- `Paginator.paintedCharacterRange` repeats the from-the-start walk, and
  `spokenText(on:)` calls it per page for VoiceOver.
- `ReaderChrome.swift:56` — `max(window.width - margin * 2, 1)` does not clamp
  NaN, because Swift's `max` returns its first argument when the comparison is
  false. `fits(_:)`, which exists to detect this, is never called outside tests.
- `min(max(x, 0), 1)` has the arguments the wrong way round at four sites —
  `AudiobookCoordinator:111`/`:141`, `ReadalongCoordinator:184`, `SMIL:179`,
  `EPUBPackage:63` — so NaN passes through. `EPUBPackage.bookProgress` returns
  NaN and `ReaderModel.spinePosition` does `Int(scaled)` on it.
- `BookSearch.hits` records the match location but discards `found.length`, and
  case/diacritic folding makes the matched length differ from the needle's —
  `("Straße").range(of: "ss", …)` returns a 1-unit range for a 2-unit needle.
- `BookSearch.swift:62` re-searches the excerpt from its start, so it emphasises
  the first occurrence in the 40 characters of leading context, not the hit.
- `HTMLContentParser.swift:118` — `<ul>`/`<ol>` only bump an indent counter; no
  bullet or number is ever emitted, so ordered lists lose their numbering.
- `HTMLContentParser.swift:188` — duplicate `id` attributes overwrite
  `fragmentRanges` while the run attribute keeps the first, so the two disagree
  and reopening the book can teleport the reader forward.
- `HTMLContentParser.swift:120` — `case "pre", "code"` makes *inline* `<code>`
  preformatted, injecting literal newlines mid-sentence.
- `HTMLContentParser.swift:91` — `Context.alignment` is declared, read, never
  assigned; the `??` is dead and `Context` copies a whole `ReaderStyle` per node.
- `XMLTree.swift:18` — `parent` is `weak`, written on every node, read by
  nothing: a side-table allocation and locked store per node per parse.
- `EPUBFontResolver` strips comments and walks each stylesheet grapheme-by-
  grapheme three times, on the main actor at book open, even when the reader's
  typeface is bundled and the answer will be discarded.
- `LocatorAnchoring.swift:51` documents a chapter-length sanity check it does not
  implement; `:94` searches raw text for a quote that `quote()` normalised, so
  the anchor is dead for any quote spanning a paragraph break.
- `EPUBXMLNode` claims `@unchecked Sendable` while exposing mutable `public var`s
  with no synchronisation.
- `SMILTimeline.window` traps on overflow for a large `after`; `SleepTimer.start`
  is public, validates nothing, and never terminates for `.infinity`.
- `AudioPlayer.seek` records the requested time, not the clamped one, and
  discards the `Bool` that says the seek was superseded.
- `AudiobookCoordinator:52` calls `startTime(ofTrackAt:)` on every time tick — an
  O(n) filter that allocates, five times a second — bypassing the
  `cachedTrackSpan` that exists for it.
- `RemoteCommands:218` returns `.success` before the handler runs and even when
  the binding resolves to `.none`.
- `AudioPlayer.effectiveRate` reads `timeControlStatus`, which is
  `.waitingToPlayAtSpecifiedRate` right after `play()`, and nothing KVO-observes
  it — so the rate published to Now Playing is 0 until the 5-second poll.
- Playback speed policy is written five times and has drifted: the buttons walk
  to 5.0× and 0.5×, speeds in no menu anywhere; the system menu stops at 3.0 and
  floors at 0.75; CarPlay stops at 2.0. `PlaybackSettings.playbackRate` clamps
  nothing, so a 5.0 is persisted and restored.
- `AudiobookManifest.startTime`/`locate` hand-roll a linear walk that
  `SMILTimeline.index(atBookTime:)` already does as a binary search.
- `ReadalongCoordinator.moveChapter` rebuilds the book's document list by
  reducing over every entry, then calls a linear `firstEntry(inDocument:)` —
  while `documentRanges` already precomputes it, and the two orderings disagree.
- `EPUBPackage.parseManifest` re-implements `resolve` inline and gets absolute
  hrefs wrong: `href="/OEBPS/Text/ch1.xhtml"` becomes `OEBPS/OEBPS/Text/ch1.xhtml`.
- `EPUBFontResolver` hardcodes the readable-format list that
  `CustomFonts.readableExtensions` already owns, so the two gates can disagree
  and the reader is promised a font that then fails to register.
- `SleepTimer.remainingText` hand-rolls a clock format with no hours branch, so
  the 60-minute preset counts down as "60:00" beside a transport that would write
  "1:00:00". `DurationText` is a third spelling.
- `CustomFonts.register` keys by file URL and claims that stops two books' fonts
  colliding; CoreText's family namespace is process-wide, so it does not.

### Apps/Shared

- `AppModel.swift:1064` — `startListening` never re-checks liveness after two
  suspension points, so a book started just before sign-out plays for the
  departed account with a revoked token and a 15-second writer that logs "write
  dropped" forever.
- `AppModel.swift:178` — `connect`'s early returns leave `phase` at `.launching`,
  which renders a blank screen with no controls and no recovery. A stored
  `issa.lastServer` that `candidates` cannot parse gives a permanently blank app;
  uninstalling is the only way out.
- `AppModel.swift:1345` — the Wi-Fi-only refusal writes to `loadError`, which is
  rendered only when the library is empty, so "Save for offline" on cellular is a
  completely silent no-op.
- `AppModel.swift:349` — `signOut` misses `pendingBook`, `readerRequest`,
  `visibleReaderUUID`, `pendingWrites`, `listeningError`, `libraryMode`,
  `arrangement` and `PlaybackSettings.bookStyles`. A widget tap's `pendingBook`
  survives into the next account, which shares the uuid.
- `AppModel.swift:716` — annotations, the one datum with no server copy, are
  written fire-and-forget through `try?` on an optional store, with no log at
  either layer. A failed store open discards every highlight for the session.
- `AppModel.swift:422` — `watchForExpiry` polls every 2 s forever to mirror a
  property `Session` already publishes, including on a locked phone playing a
  14-hour audiobook, and leaves a 2 s window where a signed-in-looking library
  401s.
- `AppModel.swift:278`/`:299` — two hand-synchronised `switch session.state`
  blocks; `connect` is exhaustive and `adopt` uses `default:`, the drift the
  comment says was already fixed once.
- `AppModel.swift:581` — `libraryMode` and `arrangement.shelf` are a two-field
  machine no single writer owns, persisted two different ways;
  `LibraryView.swift:77` papers over it by making the segmented control lie.
- `AppModel.swift:14` — a 1,500-line `@Observable` doing seven jobs, with the
  most safety-critical path in the app (`writePosition`) reachable only through
  the simulator. All 22 test files test package types.
- `ReaderView.swift:171` — `retryOpen` runs in an uncancellable Task outside the
  `.task(id: pageSize)` that `open()`'s three cancellation checks rely on, so a
  rotation during a retry starts a second concurrent `open()` and two
  `AudioExtraction` passes writing the same files.
- `ReaderModel.swift:1076` — `move(toChapter:landingOnLastPage:)` bounds-checks
  at the top of the loop, after the previous iteration committed the empty
  chapter, so walking off the spine strands the reader on a blank cover.
- `ReaderModel.swift:984` — the `?? 0` reflow fallback dumps the reader at page 1
  whenever the anchor is the synthetic trailing page's offset, which
  `.ensuresExtraLineFragment` produces. `pageCount` counts that page too, so the
  footer reads "12 / 13" on the last page with text.
- `ReaderView.swift:60-64` — five `Bool`s encode "which one sheet is up", 32
  states for 6 legal ones; if two are ever true the loser's binding never resets
  and that sheet can never open again. On macOS `showsPlayer` is never written
  and never presented.
- `ReaderView.swift:696-719` — eight copy-pasted `.onReceive` blocks, one per
  `ReaderCommand`; a ninth command compiles fine and silently does nothing.
- `ReaderView.swift:1016` — highlight geometry is recomputed at drag frame rate
  (60–120 Hz) because `body` is invalidated by `selection`, for geometry that
  cannot have changed.
- `ReaderModel.swift:103` — `downloadHost: AppModel?` makes the per-book model
  depend on the god object for two methods, and completes a reference cycle;
  `ReaderModel` cannot be constructed in a test without `UserDefaults` and a
  keychain.
- `ReaderModel.swift:824`, `:1606` — `narrationContext()` and `hasPublisherFont`
  have no callers anywhere.
- `MacBookInspector.swift:22` — the Mac inspector reuses one `BookDetailView`
  across selections with no `.id(bookID)`, so `@State` and one-shot `.task`
  survive: book B shows "Downloaded" for a file never fetched and book A's
  listen error under B's button.
- `CoverImage.swift:210` — the previous book's decoded art stays in `@State`
  while the new fetch runs, so the continue card and mini player show the wrong
  cover beside the right title; `:246` — `.task(id: book.uuid)` omits `updatedAt`
  and `shape`, so a replaced cover is never re-fetched and the whole
  version-keyed cache is never consulted; `:248` — fetches are never cancelled
  when a cell scrolls away, so fast scrolling makes covers appear *slower* and
  thrashes the 80-entry LRU.
- `DownloadsView.swift:146` — a size-unknown transfer draws a determinate bar
  frozen at 0%, visually identical to a dead one. `State.isIndeterminate` exists
  for this and is used only by tests.
- `BookPrimaryAction.resolve`/`.intent` and `DownloadStatusText.short` have no
  production call sites while two untested view copies ship and have drifted —
  "Paused · 42%" against "Paused at 42%", "Downloaded" against "Done".
- `LibraryView.swift:134` — search results are assigned with no
  `Task.isCancelled` check and neither `AppModel.search` nor the store checks
  cancellation, so a slower earlier query overwrites a newer one.
- `BookLinks.swift:163` — `BookRail` uses a non-lazy `HStack` while
  `relatedRails` passes uncapped arrays, so a prolific narrator kicks off 120
  cover fetches on open.
- `CurrentBookPublisher.swift:87` — `coverMatches` in the "nothing moved" guard
  means a book with no cover art rewrites the snapshot, reloads the widget and
  re-fires a doomed fetch on *every* publish; `:140` overwrites the shared cover
  before checking the snapshot still belongs to that book.
- `ReaderView.swift:266` — `BookActivity.make` builds a configured
  `NSUserActivity` the caller discards, hand-copying four of six properties and
  dropping both privacy ones, so `isEligibleForSearch = false` never applies.
- `ServerAddress.swift:36` — userinfo is preserved through `normalize`, then
  persisted to plaintext `UserDefaults`, used as a plaintext keychain attribute,
  and rendered verbatim on the Settings screen. `IssaLog` scrubs it; three other
  sinks do not.
- `DeviceCodeView.swift:107` — the comment "Never pass a URL carrying the device
  code here" sits inside the function whose only caller passes exactly that;
  `:207` — a `try? await Task.sleep` swallows cancellation, so a second tap
  clears "Copied" instantly.
- `NowPlayingSheet.swift:77` — a private `Book.hasText` shadows the tested
  `Book.isReadable`, one of six sites open-coding a `servableFormats` ladder that
  has already caused a shipped bug.
- `BookDetailView.swift:15` — a dead `@Environment(\.dynamicTypeSize)` that,
  being a `DynamicProperty`, re-evaluates the whole 900-line body on every
  Dynamic Type change for a value nothing reads.
- Eight hand-rolled capsules where `ChipLabel` is the named shared one, drifted
  three ways (padding 3 / 4 / `spacing8`, two grounds, `stroke` vs
  `strokeBorder`); `BookDetailView` has the screen's only unscaled sizes where
  `Metrics.scaled(_:)` is the convention; `SeriesRail` is a near-verbatim copy of
  `BookRail` down to the comment; the font importer is duplicated wholesale
  between two settings screens; `ListeningView` hand-rolls the empty state
  `PalettePlaceholder`'s doc names it for.

### Platform targets, harness, tooling

- `LayoutInvariants.swift:282` — `assertScrollContentFits` disagrees with its
  three siblings about scope in both directions: no `isOnScreen` filter (so a
  prefetched cell gives an intermittent red), and bleed checked on self and
  children but never ancestry (so a scroll view under `rail.*` is held to its
  parent's width). The identifier convention means one thing in three functions
  and another in the fourth.
- `LayoutInvariantsTests.testSystemChromeIsIgnored` is vacuous — its node is type
  `.other`, not in `measured`, so the assertion returns before `isSystemChrome`
  is consulted; the test passes if that function is deleted.
- `FixtureLibrary.swift:103` — the fixture's saved position names
  `OEBPS/text/ch01.xhtml` while `make-readalong-fixture.py` writes
  `OEBPS/ch01.xhtml`. Invisible only because no sweep destination opens the
  reader, so the per-device cost of planting that EPUB buys no coverage.
- `IssaReaderApp.swift:312` (iOS) — Spotlight indexing is keyed on
  `app.books.count`, strictly weaker than the `SpotlightIndex.version(of:)` the
  codebase defines for the job, so a same-size change never re-indexes. It is
  also the only call site: macOS never indexes, yet `signOut` clears an index the
  Mac never wrote.
- `CarPlaySceneDelegate.swift:102` — the shared Now Playing template is installed
  as a tab and then pushed onto the stack; the push is rejected and
  `completion: nil` discards it, so the driver taps a row, audio starts, and the
  screen does not change — what the file's own comment calls "indistinguishable
  from a crash at the wheel". `:166` has the same blind spot against the
  five-template limit.
- `IssaReaderApp.swift:331` (macOS) — the "Book Info" toggle is one-way: the
  setter ignores `true` and clearing the id immediately satisfies the `.disabled`
  condition, so the control greys out and cannot bring the inspector back.
- `scripts/asc-api.py` — `builds()`/`platforms()` fetch one `limit=200` page and
  ignore `links.next`, and `urlopen` has no `timeout=`, so a stalled connection
  hangs the release before it archives anything.
- `release.sh:111` bumps `CURRENT_PROJECT_VERSION` in the tracked `project.yml`
  with no revert on failure, so a failed archive burns a build number.
- `make-readalong-fixture.py` declares a non-existent OPF namespace
  (`http://www.w3.org/2000/opf`) and its `clock()` renders `00:00:60.00` for
  durations just under a minute.
- `$WORK` under `${TMPDIR:-/tmp}` is a guessable path that `mkdir -p` accepts
  pre-created, with the archive and signed artifacts inside it.
- `LayoutSweepTests.swift:85`'s comment says "No fixture flag" four lines above
  the launch arguments that pass one.
- The macOS Playback menu clamps `playbackRate` to 0.5–5.0 while the only other
  rate UI offers 0.75–3.0, and the value is persisted into the App Group shared
  with iOS.

---

## 12 · What to fix first

Ordered by exposure over cost.

| # | Fix | Why it leads | Effort |
| --- | --- | --- | --- |
| 1 | `release.sh` guard (F-10.1) | Reports clean whenever the fixture *is* present. Drop `-q`, or capture `strings` to a variable first. | 1 line |
| 2 | Validate `book.uuid` (F-3.1) | One `allSatisfy` at decode closes the traversal at all four sinks. | ~10 min |
| 3 | Reorder `writePosition` (F-5.3) | Swap 1479 and 1484 so the local save precedes the drain. | 1 line |
| 4 | Bound `playSelection` (F-4.1) | The `NSMaxRange` check its two siblings already carry. | 1 line |
| 5 | Keychain `ThisDeviceOnly` (F-3.3) | Stops a 35-year token restoring onto a second device. | 1 line |
| 6 | Flush on Mac/tvOS quit (F-5.1) | Fires on every ⌘Q today. `flushOpenReaders()` already exists. | ~30 min |
| 7 | `EXCLUDED_SOURCE_FILE_NAMES` (F-10.3) | Makes the fixture gate real instead of nominal, and does not depend on F-10.1. | ~15 min |
| 8 | Sign-in error copy (F-8.2) | Live in build 24, directing readers to a deleted route. | ~20 min |
| 9 | Label the server field (F-8.1) | First screen, unusable under VoiceOver. Move the placeholder to `prompt:`. | ~15 min |
| 10 | `tvOS setReaderVisible` (F-7.6) | The read-along highlight is the point of that screen and it steps once a second. | ~15 min |
| 11 | Absolute cap in `Inflate` (F-4.4) | Turns a jetsam kill into the thrown error the comment already claims. | ~15 min |
| 12 | Uppercase named entities (F-6.1) | Makes French and German books openable. Table addition, no logic change. | ~20 min |
| 13 | Deactivate the audio session (F-7.1) | Stops permanently suppressing other apps' audio. | ~30 min |

Fixing the sweep (F-10.4 through F-10.8) is a larger piece of work and does not
belong on this list as line items — but until it is done, a green sweep is not
evidence, and that should be stated wherever the sweep's result is quoted.

---

## 13 · Method

Five `/code-review max` passes, each fanning out across ten or more angles with
adversarial verification, plus a gap sweep on the fifth. Findings recorded here
survived that verification. The strongest EPUB and playback findings were
confirmed by executing the actual algorithm — path resolution, SMIL clock
parsing, `compression_decode_buffer`, `XMLParser` entity handling, the CSS block
scanner — rather than by reading it. F-10.1 and the two corrections in §2 I
reproduced myself.

No code was changed. No `CLAUDE.md`, `AGENTS.md`, lint or format config exists
anywhere in the repository, so no conventions findings were possible; the
user-level `CLAUDE.md` governs Terraform and AWS for a different repo.

Severity is exposure, not effort. **Critical**: a crash, a silent loss of the
reader's place, or an exposure reachable by someone on the same network.
**High**: wrong behaviour a reader would notice. **Medium**: cost, drift, or a
latent trap.
