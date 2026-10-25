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
