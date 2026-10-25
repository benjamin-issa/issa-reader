# Porting the Swift packages to Kotlin

The Android app is a port, not a rewrite: each Swift package has a Kotlin
module that keeps its types, its rules and its tests, so a fix on one side can
be found and made on the other. This file is how the two line up.

## Modules

| Swift | Kotlin module | Package | Kind |
| --- | --- | --- | --- |
| `Packages/IssaCore` | `:core` | `com.benjaminissa.issareader.core.*` | JVM |
| `Packages/IssaEPUB` | `:epub` | `com.benjaminissa.issareader.epub` | JVM |
| `Packages/IssaRender` (text, geometry, maths) | `:render` | `com.benjaminissa.issareader.render` | JVM |
| `Packages/IssaRender` (layout and drawing) | `:render-android` | `com.benjaminissa.issareader.render.android` | Android |
| `Packages/IssaPlayback` (logic) | `:playback` | `com.benjaminissa.issareader.playback` | JVM |
| `Packages/IssaPlayback` (AVFoundation parts) | `:playback-android` | `com.benjaminissa.issareader.playback.android` | Android |
| `Packages/IssaAsk` (engine) | `:ask` | `com.benjaminissa.issareader.ask` | JVM |
| `Packages/IssaAsk` (`SystemAnswerModel`) | `:ask-android` | `com.benjaminissa.issareader.ask.android` | Android |
| `Packages/IssaUI` | `:ui` | `com.benjaminissa.issareader.ui` | Android |
| `Apps/Shared`, `Apps/IssaReader-iOS`, `Apps/IssaWidgets` | `:app` | `com.benjaminissa.issareader.app` | Android app |

IssaCore's folders become sub-packages: `core.model`, `core.networking`,
`core.auth`, `core.diagnostics`, `core.download`, `core.store`, `core.sync`.

## Names

A Swift file `Foo.swift` becomes `Foo.kt` holding the same type. Acronyms
follow Kotlin's casing: `HTMLEntities` → `HtmlEntities`, `FNV1a` → `Fnv1a`,
`APIClient` → `ApiClient`, `EPUBPackage` → `EpubPackage`, `SMILTimeline` →
`SmilTimeline`, `sentenceID` → `sentenceId`. Swift extensions that add a few
members to a type become members or top-level extension functions in the file
of the type they extend.

## CarPlay and Now Playing

CarPlay becomes Android Auto, and the system half of Now Playing a Media3
media session; one `MediaLibraryService` is both.

| Swift | Kotlin |
| --- | --- |
| `CarPlaySceneDelegate` (tabs, rows, Up Next, the rate button, the alert) | `app.media.IssaPlaybackService`, `app.media.AutoBrowseTree` |
| `CarPlayBridge`, `AppServices.connectCarPlay()` | `app.media.MediaHost`, `app.media.AppMedia` |
| `CarPlayChapters` | `app.media.AutoChapters` |
| `RemoteCommandCenter`'s `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` | `playback.android.IssaSessionPlayer`, `SessionTransport`; the decisions stay in `playback.CommandRouter` |
| AirPods' decoded presses | `playback.android.HeadsetButtons` |
| The CarPlay scene connecting | `playback.android.CarPresence` |

Android Auto adds voice search (`app.media.VoiceSearch`), which CarPlay
never had, and names the controller behind each command, which iOS never
did (`playback.android.ControllerSurfaces`).

## Types

| Swift | Kotlin |
| --- | --- |
| `struct` (value type) | `data class` with `val`s; mutation through `copy` |
| `enum` without payloads | `enum class` |
| `enum` with associated values | `sealed interface` / `sealed class` |
| `Optional` | nullable type |
| `Codable` | `@Serializable`, read and written with `IssaJson` (`core/IssaJson.kt`) |
| hand-written `init(from:)` | a custom `KSerializer` doing the same tolerant decode |
| `Int` | `Int`, or `Long` where it can pass 2³¹ (byte counts, epoch milliseconds) |
| `TimeInterval` | `Double` seconds |
| `Date` | `java.time.Instant` |
| `NSRange` / UTF-16 offsets | `Int` offsets into a Kotlin `String` (also UTF-16) |
| `Character` (grapheme cluster) | walk with `java.text.BreakIterator.getCharacterInstance()` where clusters matter |
| `removingPercentEncoding` | `String.removingPercentEncoding()` (`core.model`) |
| `throws` | exceptions; the error enums become sealed exception hierarchies |
| `async` | `suspend` |
| `AsyncStream` | `Flow` |
| `actor` | a class whose state is guarded by a `Mutex`, or confined to one dispatcher |
| `@MainActor` state | state documented as main-thread-only; pure JVM modules take a `CoroutineDispatcher` |

Server shapes keep every newly decoded field optional (CLAUDE.md), and the JSON
written to the server omits absent values exactly as Swift's encoder does,
because Storyteller compares stored locators by deep equality.

## Comments

The Swift sources explain *why* at length, and many comments record a server
quirk or a bug that shipped. Keep that reasoning in the Kotlin, adapted to the
Kotlin names; drop only what is about an Apple API the port does not use.

## Tests

Every Swift suite in a package is ported into the matching module as a JUnit 4
class named after it (`UnitIntervalTests` → `UnitIntervalTest`), keeping every
test. A test's description becomes a backtick name or a short comment; a test
with `arguments:` loops over them. The suites read the Swift packages' fixtures
in place through `Fixtures` (`:testing`), so a captured response added for one
client is checked by both. Suites whose input lives outside the repository
(`/tmp/pw*.epub`, Gemini Nano) go through `ReleaseRun.require`, which skips on
an ordinary run and fails under `ISSA_RELEASE_RUN=1`.

A Swift test that cannot apply on Android is listed below with the reason,
rather than silently dropped.

### The app's suites

`Apps/IssaSharedTests` is ported into `:app`'s unit tests, under Robolectric
at SDK 36 with native graphics (chapters are laid out by `StaticLayout`). The
Swift suites are `@MainActor`; here one thread of the suites' own,
`issa-test-main`, plays the main thread (`TestMain`): `mainTest { }` runs the
body on it and every model is built on a `testScope()` that posts to it, so
the test and the code under test interleave only where something suspends, as
they do in Swift. `ScriptedServer` and `LifecycleServer` are `mockwebserver3`
dispatchers (`Servers.kt`); `SilentAudio`'s engine is `ScriptedBackend`, which
opens any file that exists as thirty minutes of silence and never ticks on its
own. Each test gets an emptied storage root (`FreshStorage`), and the local
library's store runs on the host's SQLite through the bundled driver's JVM
natives (`hostSqlite` in `app/build.gradle.kts`). "iPhone" in the copy deck is
"phone"; CarPlay is Android Auto; Spotlight is the launcher's dynamic shortcuts.

### Not ported

| Suite or test | Reason |
| --- | --- |
| IssaCore `IssaLogTests.describesTransportError`, the `code` expectation | A JVM exception has no `NSError` domain and numeric code. `IssaLog.describe` records the exception's class as `domain`; the test checks that, and that the message survives. |
| IssaCore `StorageRootTests.rootIsUnchangedOffTV` | Application Support and tvOS's Caches root do not exist on Android. Ported as: the root is the directory the app passes to `StorageRoot.configure`, it is not purgeable, and `Books/` sits under it. |
| IssaCore `DownloadFilenameTests.unreadableDirectoryThrows`, under a privileged user | Permissions do not bind root, which this suite runs as in the container. Where `chmod 000` still leaves the directory readable, the test checks the same refusal for a path that exists and cannot be listed (a file where the directory should be); otherwise it checks the unreadable directory itself. |
| IssaCore download suites: the real background `URLSession` | The transfers run through a `TransferBackend` the app provides. The suites drive a fake backend whose callbacks land a turn later, as a session's delegate queue does, so what is ported is every rule the manager keeps (fence, pause, cancel, validation, adoption); the session's own behaviour (an invalid session raising `NSGenericException`, a contested identifier) is not reproducible and belongs to the app's backend. |
| `RenderTests.swift` › `SegmentLineTests` › "every segment of one line of a real chapter comes back in one group": the `split >= 5` count | It counts the justified lines TextKit reports as two segments (a near-zero-width flush-right remainder), a TextKit artefact. Android's layout splits a line only where its direction changes, so the count is zero there by construction; the grouping of a genuinely split line is held by the bidirectional case instead. The rest of the test is ported. |
| `RenderTests.swift` › `SegmentLineTests` › "a line split by a run of the other direction is still one group": `lines.count == 3`, `first.count == 2` | Exact line and segment counts are TextKit's line breaking. Ported as the invariants they stood for: the fixture wraps, the line holding the direction change is more than one segment, all on one line. |
| `RenderTests.swift` › `PageBoundaryTests.spannedParagraphLayout()` at 320 × 400 | At 400 Android sets every sentence of the fixture on exactly two lines and every page holds twelve, so no sentence straddles a page and the fixture tests nothing; `:render-android` lays it out 370 tall, where every other break falls mid-sentence. |
| `ArchiveImageSourceTests.swift` › R-59 on AppKit (a plate's size in points at its DPI) | The Mac's `NSImage` behaviour. Android follows the iPhone and iPad (`UIImage`): a plate is laid out at its pixel size whatever resolution it is tagged with, and the ported test asserts that. |
| `WhitespaceStabilityTests.swift` (IssaAsk) | Both cases are about the passage chunker and the ranker, not the parser's string, so they belong to the Ask port. The parser half of `IndexOffsetTests.swift` is `:render`'s `IndexOffsetTest`. |
| `CarPlayRootTemplateTests` (IssaReader-iOS) `nowPlayingIsExcluded`, `unknownTypesAreRefused` | CarPlay's templates have no Android counterpart. Ported as `AutoBrowseTreeTest` against what Android Auto asks of its root — browsable folders only: a playable item stands for `CPNowPlayingTemplate`, a row neither browsable nor playable for `CPAlertTemplate`. |
| IssaPlayback `HandlerBoxTests` (both tests) | `HandlerBox` exists because `MPRemoteCommandCenter` is process-wide and `removeTarget(nil)` stripped every instance's handlers. Android has no shared command centre: each `MediaSession` owns its callback, and `CommandRouter` keeps no targets to remove. |
| IssaPlayback `GainTapPerTapStateTests` `unprepareDoesNotClearTheOtherTap` | Stages two `MTAudioProcessingTap`s whose prepare/unprepare callbacks interleave across a chapter change. Android has one `GainKneeAudioProcessor` per sink, configured anew for each format; `GainKneeAudioProcessorTest.theLevelSurvivesAReconfiguration` checks the level survives that. |
| IssaPlayback `GainTapPerTapStateTests` `scratchIsPerTap`, `scratchIsPerTrackOfOneMix` | Working room per tap and per track of one `AVAudioMix`. The Android stage is one processor on one audio thread, holding its own scratch; there is no second tap or track to share it with. |
| IssaPlayback `GainTapPerTapStateTests` `retainBalance` | Checks the `Unmanaged` retain/release balance of the tap's client info. Kotlin has no manual retain counts. |
| IssaAsk `SearchBookToolTests` (all 14) | The `searchBook` tool is not ported: ML Kit's Prompt API has no tool calling, so `AskEngine.usesSearchTool` is false and `forQuestion` registers no tool. The engine's handling of excerpts a tool showed is still covered by `AskEngineTest` with a stand-in tool. |
| IssaAsk `FailureTableTests`: `currentTable`, `legacyTable`, `toolCallUnwraps` | They assert FoundationModels' two error families and `ToolCallError`. `:ask-android`'s `FailureTableTest` asserts the ML Kit `GenAiException` table in their place, and unwrapping a cause chain stands in for the tool-call unwrap. |
| IssaAsk `RethinkExperiments`: variants T, TR, H, P1, S, SR and Z; the probe's capability lines; per-session token usage; the prewarm "same session" mode | They need tool calling, guided generation (`@Generable`), reasoning levels, `LanguageModelSession.usage` or a session to prewarm, none of which the Prompt API offers as used here. The other variants, the probe and the cold/shipped prewarm comparison are ported as an opt-in device suite. |
| App `ReaderInsetsTests` (all eight) | Every case is the Mac's toolbar reserve (`ReaderInsets.mac`): a window whose toolbar has not attached yet, full screen, a negative measurement. The Android reader has no window toolbar; it draws its own bar over the page, as the iPhone does. `ReaderInsetsTest` checks the rule that takes the place of the iPhone's sampled safe area instead: the edges are read ignoring whether the bars are showing, so hiding them with the chrome cannot move the page. |
| App `FontImportTests`, `BookFontImportTests`: the picked file as a security-scoped URL | A document grant is read through the content resolver; `FontImport.adopt(fileName, bytes, fonts)` is the import after that read, and the suites drive it. A face the app does not ship is made in the test by renaming a bundled file's family in place, since the repository carries no other font. |
| IssaShared `BrowserOutcomeTests` (all four) | They decide `ASWebAuthenticationSession`'s outcomes — a callback racing a cancel, `canceledLogin`, a foreign `NSError`. Android's browser sign-in is Chrome's Auth Tab, whose result codes `AuthTabBrowser` maps; `AuthTabBrowserTest` (`app.platform`) checks that mapping, and `BrowserSignInBeginTest.noAuthTabOffersTheDeviceCode` the fallback when there is no Auth Tab. |
| IssaShared `BookRoutingTests`: R-20 `searchGoesToItsOwnWindow`, R-58 `publishedYearReadsUTC`, R-61 `stagingIsKept`, `titleCrossing` | Helpers on views — `LibraryView` hosted in two windows, `BookDetailView.publishedYear`, the tag page's `StagingCache`, `BookListPage.hasScrolledPast` — which belong to the screens' port, not the model layer. The model half of the suite (`LibraryModeSwitch`, `showLibrary(fromReading)`, the resume refusal) is ported. |
| IssaShared `ScreenAwakeTests`: the three scene-table tests | They walk `UIScene` activation states across windows. Android has one activity and reads the process lifecycle (`ProcessLifecycleOwner`) into `AppModel.setForeground`; the rules the table fed — a visible reader, a playing narration, foreground only — are `AppModelScreenAwakeTest`. |
| IssaShared `RootWindowTests.localTapOpensOneWindow` (R-29) | An Ask answer's tap routed through `LocalBookRequests` to one of several windows: the Ask port's, and Android has one window. |
| IssaShared `LocalBooksWiringTests`: `tapOpensTheLocalReader`, `tapWaitsForTheLibrary`, `tapOnScreenBringsItForward` | `AskNotificationDelegate`'s routing of an answer notification's tap: the Ask port's. `servicesWireTheLibrary` is ported against `LocalBooksWiring.connect` with no question index (`ask = null`). |
| IssaShared `LocalBooksRootTests.undoManagerTakesItBack`, `LocalBooksHardeningTests.undoIsWithdrawn` (R-27) | Edit › Undo through the window's `UndoManager`. Android has no shared undo stack; the toast's Undo is the only undo, and `staleUndo`, `removeAndUndo` and `commitPendingRemoval` hold its rules. |
| IssaShared `LocalBooksHardeningTests`: `allowsClone` | Android copies every picked file through a stream, chunk by chunk; there is no clone to turn off, so `chunkedCopyReachesTheEnd` and `copyReportsArePercents` run against the one path there is. |
| IssaShared `LocalImportTests.readalongIsAligned`: `isExcludedFromBackup` | Android has no per-file flag. The test reads `data_extraction_rules.xml` instead and checks `Local/` is not among what it includes — naming what is included excludes everything else. |
| IssaShared `DownloadRemovalTests.reconcileRemovesExtractedFontsOnly` | Android extracts no `Fonts/<uuid>/`: `ReaderFonts.registerPublisherFace` registers a book's own face from its archive, in memory, so a reconcile has no font folder to sweep. Elsewhere in the suite the extracted-face canary is a recording `BookIndexes` (the per-book derived files a removal releases). |
| IssaShared `LocalAccountIsolationTests`: the question index's files and `Fonts/<uuid>/` | The index files are the Ask port's: the sign-out's kept set, which is what the index store is told to keep, stands in. There is no extracted-fonts folder (above). |
| IssaShared `ReadingBoundaryTests.indexStringMatchesTheLaidOutChapter` | It compares the reader's laid-out chapter with `AskIndexStore`'s string; the index store is the Ask port's. The reader's half, `readingBoundary()`, is ported. |
| IssaShared `CarPlaySurfaceTests` (both) | `CarPlayBridge` is a process singleton that announced the surface as an event, so a late listener could miss it. On Android the car's media service calls `AppGraph.setCarConnected`, which writes `AppModel.setControlSurface` — state, read rather than heard — and the bridge itself is the Android Auto port's. `ListeningHandoffReaderTest.theCarKeepsPlaybackWhileConnected` covers what the surface decides. |
| IssaShared `SpotlightIndexerTests.renewsBeforeExpiry` | Spotlight items expire a month after indexing; launcher shortcuts do not expire, so there is nothing to renew. The rest of the suite is `ShortcutPublisherTest` (an older schema's shortcuts replaced, a changed library at once, a departure overtaking a pass), with `localBooksAreNeverPublished` and `aShortcutOpensTheBook` added. |
| IssaShared `ListeningHandoffReaderTests.anUnresolvedStartWhoseTrackWillNotOpenSpeaksUp`: the decoder's refusal | AVFoundation refused the non-audio chunks itself. The scripted engine opens any file that exists, so this test gives it the decoder's rule — a file whose bytes are the test's sentence will not open — and the start must still report `WOULD_NOT_PLAY`. |
| IssaShared suites using an Opus file as "narration this device can't play" | Android decodes Opus. `TestMedia` (`LocalFixtures.kt`) stands for a device without that decoder, which is what those tests are about; what a real device decodes is `AndroidMediaSupport`'s, tested in `:playback-android`. |
| IssaSharedTests `AskCoordinatorTests.expiredJobSurvivesItsOwnCancellation`, and `AskCoordinator`'s background assertion (`backgroundTimeExpired`, `BackgroundAssertion`) | iOS holds the process awake to finish an answer and is told when that time runs out. Android has no such assertion, and AICore refuses a generation for an app not on screen (`BACKGROUND_USE_BLOCKED`), so the coordinator holds the question and asks it again when the app returns. `AskCoordinatorTest` checks that instead: held in the background, re-asked on return with its original boundary, re-asked at once if the refusal lands after the return, and never twice in a row. |
| IssaSharedTests `AskCoordinatorTests.notificationPromptIsAskedOnce`, `twoDismissalsAskOnce`: the trigger | The iPhone asks for notification permission when a sheet is closed on a working question; on Android it is asked the first time a question is asked (the reader's decision; Android 13's runtime permission needs the sheet on screen to ask). Ported as "asked once and remembered" and "two questions ask once". |
| IssaSharedTests `AskNotificationTapTests.readerOnScreenIsBroughtForward`, and the forward half of `otherBookIsNotForwarded` | `bringReaderForward` brings the Mac's reader window to the front. Android has one window: a tap for the book on screen is taken by its reader through `reopenRequest`. The halves about the request left behind are ported. |
| `AskPanel.swift` (the Mac's resizable Ask popover) | Mac only. The Android sheet is a bottom sheet whose content scrolls, and which grows to full height when an answer needs the room. |
| `AskStatusBadge`'s bounce when an answer arrives | SF Symbols' `.bounce` effect. The Android badge and sparkle pulse while working and carry the accent dot when ready, as the iPhone's do; the one-off bounce is not drawn. |
