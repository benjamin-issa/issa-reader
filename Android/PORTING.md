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
| IssaPlayback `HandlerBoxTests` (both tests) | `HandlerBox` exists because `MPRemoteCommandCenter` is process-wide and `removeTarget(nil)` stripped every instance's handlers. Android has no shared command centre: each `MediaSession` owns its callback, and `CommandRouter` keeps no targets to remove. |
| IssaPlayback `GainTapPerTapStateTests` `unprepareDoesNotClearTheOtherTap` | Stages two `MTAudioProcessingTap`s whose prepare/unprepare callbacks interleave across a chapter change. Android has one `GainKneeAudioProcessor` per sink, configured anew for each format; `GainKneeAudioProcessorTest.theLevelSurvivesAReconfiguration` checks the level survives that. |
| IssaPlayback `GainTapPerTapStateTests` `scratchIsPerTap`, `scratchIsPerTrackOfOneMix` | Working room per tap and per track of one `AVAudioMix`. The Android stage is one processor on one audio thread, holding its own scratch; there is no second tap or track to share it with. |
| IssaPlayback `GainTapPerTapStateTests` `retainBalance` | Checks the `Unmanaged` retain/release balance of the tap's client info. Kotlin has no manual retain counts. |
