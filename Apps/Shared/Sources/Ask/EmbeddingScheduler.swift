#if !os(tvOS)
import Foundation
import IssaAsk
import IssaCore
#if canImport(UIKit)
import UIKit
#endif

/// Pure thermal, battery, and tier pacing rules for on-device book embeddings.
///
/// Separated from `EmbeddingScheduler` so every combination of thermal state,
/// battery level, charging state, Low Power Mode, Ask-sheet urgency, sustained
/// catch-up heat protection, and ANE contention backoff is unit-testable
/// without device hardware.
enum EmbeddingPolicy {
    enum Tier: Sendable, Equatable {
        /// Spans up to and including the reader's current chapter (`spineIndex <= current`).
        case catchUp
        /// Unread chapters ahead of the reader (`spineIndex > current`).
        case lookAhead
    }

    struct DeviceConditions: Sendable, Equatable {
        var thermalState: ProcessInfo.ThermalState
        var isLowPowerMode: Bool
        var isCharging: Bool
        /// `0.0...1.0` on iOS when battery monitoring is available; `nil` on macOS/Simulator.
        var batteryLevel: Float?
        var askSheetOpen: Bool
        var onDeviceAskRunning: Bool
        /// Seconds spent continuously catching up on battery without a cooldown.
        var sustainedCatchUpSeconds: Double
        /// Observed `msPerSpan / baselineMsPerSpan` (> 2.0 indicates ANE contention).
        var slowdownFactor: Double
        /// True for 60 s after a thermal rise so look-ahead lets the chassis cool.
        var inThermalHysteresis: Bool

        init(
            thermalState: ProcessInfo.ThermalState = .nominal,
            isLowPowerMode: Bool = false,
            isCharging: Bool = false,
            batteryLevel: Float? = nil,
            askSheetOpen: Bool = false,
            onDeviceAskRunning: Bool = false,
            sustainedCatchUpSeconds: Double = 0,
            slowdownFactor: Double = 1.0,
            inThermalHysteresis: Bool = false,
        ) {
            self.thermalState = thermalState
            self.isLowPowerMode = isLowPowerMode
            self.isCharging = isCharging
            self.batteryLevel = batteryLevel
            self.askSheetOpen = askSheetOpen
            self.onDeviceAskRunning = onDeviceAskRunning
            self.sustainedCatchUpSeconds = sustainedCatchUpSeconds
            self.slowdownFactor = slowdownFactor
            self.inThermalHysteresis = inThermalHysteresis
        }

        var isLowBatteryUnplugged: Bool {
            guard !isCharging, let level = batteryLevel, level >= 0 else { return false }
            return level < 0.20
        }
    }

    struct Pace: Sendable, Equatable {
        var batchSize: Int
        var cooldown: Duration
        var priority: TaskPriority
    }

    /// Sustained full-blast battery catch-up duration before stepping down to
    /// ~50% duty cycle so long mid-book catch-ups stay cool before `thermalState`
    /// even climbs to `.fair`.
    static let sustainedBurstLimitSeconds: Double = 10.0

    /// Idle delay after embedding/Ask finishes before unloading `embed_512`
    /// (~170 MB) from RAM while keeping the compact tokeniser cached.
    static let idleUnloadDelay: Duration = .seconds(60)

    /// Delay before showing the subtle Ask indexing spinner so quick 1-chapter
    /// catch-ups (<0.5 s) never flash.
    static let spinnerDebounceDelay: Duration = .milliseconds(450)

    /// Look-ahead hold window after a thermal state rise.
    static let thermalHysteresisSeconds: Double = 60.0

    /// Returns the batch size, cooldown between bursts, and QoS priority for
    /// `tier` under `conditions`, or `nil` when embedding should pause.
    static func pace(tier: Tier, conditions: DeviceConditions) -> Pace? {
        // Yield the Neural Engine immediately to a live on-device/Apple-cloud
        // Ask query (OpenAI / Anthropic questions do not contend with ANE).
        if conditions.onDeviceAskRunning { return nil }

        switch conditions.thermalState {
        case .critical:
            return nil
        case .serious:
            // Only allow cautious catch-up when the reader explicitly opened Ask.
            guard tier == .catchUp, conditions.askSheetOpen else { return nil }
            return Pace(batchSize: 4, cooldown: .milliseconds(500), priority: .userInitiated)
        case .fair:
            guard tier == .catchUp else { return nil }
            if conditions.askSheetOpen {
                return Pace(batchSize: 4, cooldown: .milliseconds(400), priority: .userInitiated)
            }
            if conditions.isLowPowerMode { return nil }
            if conditions.isLowBatteryUnplugged { return nil }
            let cooldown: Duration = conditions.isCharging ? .milliseconds(800) : .milliseconds(1_500)
            return Pace(batchSize: 4, cooldown: cooldown, priority: .utility)
        case .nominal:
            break
        @unknown default:
            return nil
        }

        // Thermal state is `.nominal` below.
        if conditions.isLowPowerMode {
            guard tier == .catchUp else { return nil }
            if conditions.askSheetOpen {
                return Pace(batchSize: 4, cooldown: .milliseconds(200), priority: .userInitiated)
            }
            if conditions.isCharging {
                return Pace(batchSize: 4, cooldown: .milliseconds(500), priority: .utility)
            }
            return nil
        }

        if conditions.isLowBatteryUnplugged {
            guard tier == .catchUp else { return nil }
            if conditions.askSheetOpen {
                return Pace(batchSize: 4, cooldown: .milliseconds(200), priority: .userInitiated)
            }
            return Pace(batchSize: 4, cooldown: .seconds(1), priority: .utility)
        }

        switch tier {
        case .catchUp:
            if conditions.askSheetOpen {
                return Pace(batchSize: 8, cooldown: .zero, priority: .userInitiated)
            }
            if conditions.isCharging {
                return Pace(batchSize: 8, cooldown: .zero, priority: .utility)
            }
            if conditions.sustainedCatchUpSeconds >= sustainedBurstLimitSeconds {
                return Pace(batchSize: 4, cooldown: .milliseconds(200), priority: .utility)
            }
            return Pace(batchSize: 8, cooldown: .zero, priority: .utility)

        case .lookAhead:
            if conditions.inThermalHysteresis { return nil }
            var baseCooldown: Duration
            let batchSize: Int
            let priority: TaskPriority
            if conditions.isCharging {
                batchSize = 8
                baseCooldown = .milliseconds(400)
                priority = .utility
            } else {
                batchSize = 4
                baseCooldown = .milliseconds(2_500)
                priority = .background
            }
            if conditions.slowdownFactor > 2.0 {
                baseCooldown = min(.seconds(15), baseCooldown * 2)
            }
            return Pace(batchSize: batchSize, cooldown: baseCooldown, priority: priority)
        }
    }
}

/// Single-loop, three-tier foreground scheduler for on-device book embeddings.
///
/// - **Tier 1 (Catch-up):** Runs hard up to `currentSpine` with a debounced
///   spinner beside Ask, stepping down gently after 10 s on battery so long
///   mid-book catch-ups stay cool, and boosting to `.userInitiated` if the Ask
///   sheet opens.
/// - **Tier 2 (Look-ahead):** Quietly finishes unread chapters (`spine > current`)
///   at `.background` QoS with micro-bursts + timer-coalesced cooldowns (~7%
///   duty cycle on battery) and no spinner.
/// - **Tier 3 (Plugged-in boost):** Finishes unread chapters in ~1–2 min while
///   charging and thermally nominal.
/// - **Memory lifecycle:** Automatically unloads `embed_512` (~170 MB) 60 s after
///   embedding/Ask goes idle, prewarms on Ask sheet open (~1.7 s warm reload
///   while typing), and tracks a per-OS-build compile marker so the one-time
///   20–63 s ANE compile runs proactively once instead of freezing the first Ask.
@MainActor
final class EmbeddingScheduler {
    private struct ActiveBook {
        var source: BookSource
        var currentSpine: Int
        var preparation: Task<Void, Never>?
    }

    private let store: AskIndexStore
    private let preparer: AskEngine
    private let defaults: UserDefaults
    private let coreMLEmbedder: CoreMLEmbeddingModel?
    private let activeEmbedderProvider: @MainActor () -> (any EmbeddingModel)?
    private let onIndexingBooksChanged: @MainActor (Set<String>) -> Void

    private var activeBook: ActiveBook?
    private var openAskSheets: Set<String> = []
    private var isAppActive = true
    private var isOnDeviceAskRunning = false

    private var driverTask: Task<Void, Never>?
    private var driverID: UUID?
    private var sleepTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var spinnerDebounceTask: Task<Void, Never>?
    #if os(iOS)
    private var didEnableBatteryMonitoring = false
    #endif

    private var indexingBooks: Set<String> = [] {
        didSet {
            if indexingBooks != oldValue {
                onIndexingBooksChanged(indexingBooks)
            }
        }
    }

    private var lastThermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private var thermalHysteresisUntil: ContinuousClock.Instant?
    private var baselineMsPerSpan: Double?
    private var lastSlowdownFactor: Double = 1.0
    private var sustainedCatchUpStart: ContinuousClock.Instant?
    private var clock = ContinuousClock()

    #if os(iOS)
    private let batteryStateObserver = ObserverHandle()
    private let batteryLevelObserver = ObserverHandle()
    #endif

    private final class ObserverHandle: @unchecked Sendable {
        weak var centre: NotificationCenter?
        var token: (any NSObjectProtocol)?
        deinit {
            if let token { (centre ?? .default).removeObserver(token) }
        }
    }

    init(
        store: AskIndexStore,
        preparer: AskEngine,
        defaults: UserDefaults,
        coreMLEmbedder: CoreMLEmbeddingModel?,
        activeEmbedder: @escaping @MainActor () -> (any EmbeddingModel)?,
        onIndexingBooksChanged: @escaping @MainActor (Set<String>) -> Void,
        centre: NotificationCenter = .default,
    ) {
        self.store = store
        self.preparer = preparer
        self.defaults = defaults
        self.coreMLEmbedder = coreMLEmbedder
        self.activeEmbedderProvider = activeEmbedder
        self.onIndexingBooksChanged = onIndexingBooksChanged

        #if os(iOS)
        batteryStateObserver.centre = centre
        batteryStateObserver.token = centre.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnvironmentChange() }
        }
        batteryLevelObserver.centre = centre
        batteryLevelObserver.token = centre.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnvironmentChange() }
        }
        #endif
    }

    // MARK: - Lifecycle Events

    func activateBook(
        source: BookSource,
        chapterIndex: Int,
        preparation: Task<Void, Never>? = nil,
    ) {
        let bookChanged = activeBook?.source.bookUUID != source.bookUUID
        activeBook = ActiveBook(source: source, currentSpine: chapterIndex, preparation: preparation)
        if bookChanged {
            sustainedCatchUpStart = nil
            clearSpinner()
        }
        ensureDriverRunningOrWake()
    }

    func deactivateBook(_ bookUUID: String) {
        if activeBook?.source.bookUUID == bookUUID {
            activeBook = nil
            sustainedCatchUpStart = nil
            stopDriver()
            clearSpinner()
            scheduleIdleUnloadIfIdle()
        }
        openAskSheets.remove(bookUUID)
    }

    func askSheetOpened(bookUUID: String) {
        openAskSheets.insert(bookUUID)
        cancelIdleUnload()
        prewarmModel(priority: .userInitiated)
        ensureDriverRunningOrWake()
    }

    func askSheetClosed(bookUUID: String) {
        openAskSheets.remove(bookUUID)
        if driverTask != nil {
            wakeSleep()
        } else {
            scheduleIdleUnloadIfIdle()
        }
    }

    func updateAskJobState(onDeviceRunning: Bool, anyJobRunning: Bool) {
        isOnDeviceAskRunning = onDeviceRunning
        if onDeviceRunning {
            cancelIdleUnload()
            wakeSleep()
            clearSpinner()
        } else if !isAppActive {
            if !anyJobRunning {
                // The last live Ask finished after the app moved to the background:
                // immediately reclaim CoreML RAM so the suspended app stays lean.
                unloadModelsNow(includeTokenizer: false)
            }
        } else {
            ensureDriverRunningOrWake()
            scheduleIdleUnloadIfIdle()
        }
    }

    func appDidBecomeActive() {
        isAppActive = true
        ensureDriverRunningOrWake()
    }

    func appDidEnterBackground(hasWorkingJob: Bool) {
        isAppActive = false
        stopDriver()
        cancelPrewarm()
        cancelIdleUnload()
        clearSpinner()
        if !hasWorkingJob {
            unloadModelsNow(includeTokenizer: false)
        }
    }

    func handleEnvironmentChange() {
        let currentThermal = ProcessInfo.processInfo.thermalState
        if currentThermal.rawValue > lastThermalState.rawValue {
            thermalHysteresisUntil = clock.now.advanced(
                by: .seconds(EmbeddingPolicy.thermalHysteresisSeconds),
            )
        }
        lastThermalState = currentThermal
        ensureDriverRunningOrWake()
    }

    func handleMemoryWarning(hasWorkingJob: Bool) {
        stopDriver()
        cancelPrewarm()
        cancelIdleUnload()
        clearSpinner()
        if !hasWorkingJob {
            unloadModelsNow(includeTokenizer: true)
        } else {
            // Even with an active job, drop cached span vectors in SQLite store.
            Task { [store] in await store.clearAllSpanCaches() }
        }
    }

    func modelBecameReady() {
        if let embedder = coreMLEmbedder, !hasCompileMarker(for: embedder.modelID) {
            let cond = currentConditions()
            if cond.thermalState == .nominal, !cond.isLowPowerMode, !cond.isLowBatteryUnplugged {
                prewarmModel(priority: .utility)
            }
        }
        ensureDriverRunningOrWake()
    }

    func modelRemoved() {
        stopDriver()
        cancelPrewarm()
        cancelIdleUnload()
        clearSpinner()
    }

    func purgeBooks(keeping kept: Set<String>) {
        openAskSheets = openAskSheets.filter { kept.contains($0) }
        indexingBooks = indexingBooks.filter { kept.contains($0) }
        if let active = activeBook, !kept.contains(active.source.bookUUID) {
            activeBook = nil
            stopDriver()
            clearSpinner()
            scheduleIdleUnloadIfIdle()
        }
    }

    // MARK: - Driver Loop

    /// True while a background driver loop is currently active (exposed for
    /// stop-then-restart race tests).
    var isDriverRunning: Bool { driverTask != nil }

    private func ensureDriverRunningOrWake() {
        guard isAppActive, activeBook != nil, activeEmbedderProvider() != nil else { return }
        #if os(iOS)
        if !didEnableBatteryMonitoring {
            UIDevice.current.isBatteryMonitoringEnabled = true
            didEnableBatteryMonitoring = true
        }
        #endif
        if driverTask != nil {
            wakeSleep()
            return
        }
        let id = UUID()
        driverID = id
        driverTask = Task { [weak self] in
            await self?.runLoop(driverID: id)
        }
    }

    private func stopDriver() {
        sleepTask?.cancel()
        sleepTask = nil
        driverTask?.cancel()
        driverTask = nil
        driverID = nil
    }

    private func wakeSleep() {
        sleepTask?.cancel()
        sleepTask = nil
    }

    private func runLoop(driverID id: UUID) async {
        defer {
            if driverID == id {
                driverTask = nil
                driverID = nil
                clearSpinner()
                scheduleIdleUnloadIfIdle()
            }
        }

        var sessionWritten = 0
        var sessionStart: ContinuousClock.Instant?
        var sessionBookUUID: String?

        while !Task.isCancelled {
            guard isAppActive,
                  let book = activeBook,
                  let embedder = activeEmbedderProvider()
            else { break }

            let uuid = book.source.bookUUID
            if sessionBookUUID != uuid {
                flushTimingLog(bookUUID: sessionBookUUID, written: sessionWritten, start: sessionStart)
                sessionBookUUID = uuid
                sessionWritten = 0
                sessionStart = nil
                sustainedCatchUpStart = nil
            }

            if let prep = book.preparation {
                await prep.value
                guard !Task.isCancelled else { break }
            }

            do {
                _ = try await preparer.prepareIndex(source: book.source)
                guard !Task.isCancelled else { break }
            } catch is CancellationError {
                break
            } catch {
                IssaLog.info("ask background embedding paused", [
                    "kind": String(describing: type(of: error)),
                ])
                break
            }

            // Re-read current chapter in case the reader turned a page during index prep.
            guard let current = activeBook, current.source.bookUUID == uuid else { continue }
            let targetSpine = current.currentSpine

            let readProgress: (embedded: Int, total: Int)
            let bookProgress: (embedded: Int, total: Int)
            do {
                readProgress = try await store.embeddingProgress(
                    in: uuid, modelID: embedder.modelID, upToSpine: targetSpine, ensureSpans: true,
                )
                bookProgress = try await store.embeddingProgress(
                    in: uuid, modelID: embedder.modelID, upToSpine: nil, ensureSpans: false,
                )
            } catch is CancellationError {
                break
            } catch {
                break
            }

            let readMissing = max(0, readProgress.total - readProgress.embedded)
            let bookMissing = max(0, bookProgress.total - bookProgress.embedded)

            if readMissing == 0, bookMissing == 0 {
                clearSpinner()
                sustainedCatchUpStart = nil
                flushTimingLog(bookUUID: uuid, written: sessionWritten, start: sessionStart)
                sessionWritten = 0
                sessionStart = nil
                // Book is 100% embedded. Only run the one-time cold compile
                // warm-up if this OS build has never compiled `embed_512` yet.
                maybeRunOneTimeCompileWarmup(for: embedder)
                break
            }

            let tier: EmbeddingPolicy.Tier = readMissing > 0 ? .catchUp : .lookAhead
            if tier == .lookAhead {
                clearSpinner()
                sustainedCatchUpStart = nil
            } else if sustainedCatchUpStart == nil {
                sustainedCatchUpStart = clock.now
            }

            let conditions = currentConditions()
            guard let pace = EmbeddingPolicy.pace(tier: tier, conditions: conditions) else {
                clearSpinner()
                sustainedCatchUpStart = nil
                if conditions.onDeviceAskRunning {
                    // Wait until live Ask ends (setOnDeviceAskRunning wakes us).
                    await interruptibleSleep(.seconds(30))
                    continue
                }
                if conditions.inThermalHysteresis, let until = thermalHysteresisUntil {
                    let remaining = clock.now.duration(to: until)
                    if remaining > .zero {
                        await interruptibleSleep(remaining)
                        continue
                    }
                }
                // Paused for thermal / LPM / low battery; environment observers
                // will restart us when conditions improve. Arm idle unload now.
                break
            }

            cancelIdleUnload()
            if tier == .catchUp {
                scheduleSpinnerIfNeeded(for: uuid, readMissing: readMissing)
            }

            let scope: AskIndexStore.EmbeddingScope = tier == .catchUp
                ? .upToSpine(targetSpine)
                : .afterSpine(targetSpine)

            let burstStart = clock.now
            let written: Int
            do {
                // Execute each burst in a bounded child task at the tier's exact
                // QoS so look-ahead runs on Efficiency cores without inheriting
                // any earlier `.userInitiated` elevation.
                let store = self.store
                written = try await Task(priority: pace.priority) {
                    try await store.embedNextBatch(
                        in: uuid,
                        embedder: embedder,
                        scope: scope,
                        maxSpans: pace.batchSize,
                    )
                }.value
            } catch is CancellationError {
                break
            } catch {
                IssaLog.info("ask background embedding paused", [
                    "kind": String(describing: type(of: error)),
                ])
                break
            }

            if written > 0 {
                if sessionStart == nil { sessionStart = burstStart }
                sessionWritten += written
                recordCompileMarker(for: embedder.modelID)
                updateThroughputBaseline(written: written, elapsed: burstStart.duration(to: clock.now))
            } else {
                break
            }

            if pace.cooldown > .zero {
                await interruptibleSleep(pace.cooldown)
            }
        }

        flushTimingLog(bookUUID: sessionBookUUID, written: sessionWritten, start: sessionStart)
    }

    private func interruptibleSleep(_ duration: Duration) async {
        let tolerance = duration / 4
        let task = Task<Void, Never> {
            _ = try? await Task.sleep(for: duration, tolerance: tolerance)
        }
        sleepTask = task
        await task.value
        if sleepTask == task {
            sleepTask = nil
        }
    }

    // MARK: - Conditions & Metrics

    private func currentConditions() -> EmbeddingPolicy.DeviceConditions {
        let info = ProcessInfo.processInfo
        let isCharging: Bool
        let batteryLevel: Float?
        #if os(iOS)
        let state = UIDevice.current.batteryState
        isCharging = (state == .charging || state == .full)
        let rawLevel = UIDevice.current.batteryLevel
        batteryLevel = rawLevel >= 0 ? rawLevel : nil
        #else
        isCharging = true
        batteryLevel = nil
        #endif

        let sustainedSeconds: Double
        if let start = sustainedCatchUpStart {
            let d = start.duration(to: clock.now)
            sustainedSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        } else {
            sustainedSeconds = 0
        }

        let inHysteresis: Bool
        if let until = thermalHysteresisUntil {
            if clock.now < until {
                inHysteresis = true
            } else {
                thermalHysteresisUntil = nil
                inHysteresis = false
            }
        } else {
            inHysteresis = false
        }

        let sheetOpen = activeBook.map { openAskSheets.contains($0.source.bookUUID) } ?? !openAskSheets.isEmpty

        return EmbeddingPolicy.DeviceConditions(
            thermalState: info.thermalState,
            isLowPowerMode: info.isLowPowerModeEnabled,
            isCharging: isCharging,
            batteryLevel: batteryLevel,
            askSheetOpen: sheetOpen,
            onDeviceAskRunning: isOnDeviceAskRunning,
            sustainedCatchUpSeconds: sustainedSeconds,
            slowdownFactor: lastSlowdownFactor,
            inThermalHysteresis: inHysteresis,
        )
    }

    private func updateThroughputBaseline(written: Int, elapsed: Duration) {
        guard written > 0 else { return }
        let ms = Double(elapsed.components.seconds) * 1_000.0
            + Double(elapsed.components.attoseconds) / 1e15
        let msPerSpan = ms / Double(written)
        // Ignore cold compile outlier (> 1 s/span) when establishing steady baseline.
        guard msPerSpan > 1.0, msPerSpan < 1_000.0 else { return }
        if let baseline = baselineMsPerSpan {
            lastSlowdownFactor = msPerSpan / max(baseline, 1.0)
            // Slowly track lower baselines without drifting up during contention.
            if msPerSpan < baseline {
                baselineMsPerSpan = baseline * 0.8 + msPerSpan * 0.2
            }
        } else {
            baselineMsPerSpan = msPerSpan
            lastSlowdownFactor = 1.0
        }
    }

    private func flushTimingLog(
        bookUUID: String?, written: Int, start: ContinuousClock.Instant?,
    ) {
        guard let bookUUID, written > 0, let start else { return }
        let ms = EmbeddingMath.milliseconds(since: start, on: clock)
        let msPerSpan = ms / max(1, written)
        IssaLog.info("ask background embeddings finished", [
            "book": bookUUID,
            "written": String(written),
            "ms": String(ms),
            "msPerSpan": String(msPerSpan),
        ])
    }

    // MARK: - Spinner Debounce

    private func scheduleSpinnerIfNeeded(for bookUUID: String, readMissing: Int) {
        guard readMissing > 0 else { clearSpinner(); return }
        if indexingBooks.contains(bookUUID) { return }
        guard spinnerDebounceTask == nil else { return }
        spinnerDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: EmbeddingPolicy.spinnerDebounceDelay)
            guard let self, !Task.isCancelled else { return }
            self.spinnerDebounceTask = nil
            if self.driverTask != nil, self.activeBook?.source.bookUUID == bookUUID, !self.isOnDeviceAskRunning {
                self.indexingBooks.insert(bookUUID)
            }
        }
    }

    private func clearSpinner() {
        spinnerDebounceTask?.cancel()
        spinnerDebounceTask = nil
        if !indexingBooks.isEmpty {
            indexingBooks.removeAll()
        }
    }

    // MARK: - Prewarm, One-Time Compile Marker & Idle Unload

    private func compileMarkerKey(for modelID: String) -> String {
        "ask.embeddingCompiled.\(modelID).\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    private func hasCompileMarker(for modelID: String) -> Bool {
        defaults.bool(forKey: compileMarkerKey(for: modelID))
    }

    private func recordCompileMarker(for modelID: String) {
        let key = compileMarkerKey(for: modelID)
        if !defaults.bool(forKey: key) {
            defaults.set(true, forKey: key)
        }
    }

    private func maybeRunOneTimeCompileWarmup(for embedder: any EmbeddingModel) {
        guard coreMLEmbedder != nil, !hasCompileMarker(for: embedder.modelID) else { return }
        let cond = currentConditions()
        guard cond.thermalState == .nominal, !cond.isLowPowerMode, !cond.isLowBatteryUnplugged else { return }
        prewarmModel(priority: .utility, scheduleIdleUnloadAfter: true)
    }

    private func prewarmModel(priority: TaskPriority, scheduleIdleUnloadAfter: Bool = false) {
        guard isAppActive, let client = coreMLEmbedder, activeEmbedderProvider() != nil else { return }
        guard prewarmTask == nil else { return }
        cancelIdleUnload()
        let modelID = client.modelID
        prewarmTask = Task(priority: priority) { [weak self] in
            let ok = await client.prewarm()
            await MainActor.run {
                guard let self else { return }
                self.prewarmTask = nil
                if ok {
                    self.recordCompileMarker(for: modelID)
                }
                if !self.isAppActive, !self.isOnDeviceAskRunning {
                    self.unloadModelsNow(includeTokenizer: false)
                } else if scheduleIdleUnloadAfter {
                    self.scheduleIdleUnloadIfIdle()
                }
            }
        }
    }

    private func cancelPrewarm() {
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    private func scheduleIdleUnloadIfIdle() {
        guard driverTask == nil, openAskSheets.isEmpty, !isOnDeviceAskRunning, prewarmTask == nil else {
            return
        }
        guard coreMLEmbedder != nil else { return }
        cancelIdleUnload()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: EmbeddingPolicy.idleUnloadDelay, tolerance: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            self.idleUnloadTask = nil
            guard self.driverTask == nil, self.openAskSheets.isEmpty, !self.isOnDeviceAskRunning,
                  self.prewarmTask == nil
            else { return }
            self.unloadModelsNow(includeTokenizer: false)
        }
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func unloadModelsNow(includeTokenizer: Bool) {
        cancelPrewarm()
        cancelIdleUnload()
        if let client = coreMLEmbedder {
            Task {
                if includeTokenizer {
                    await client.unloadAll()
                } else {
                    await client.unloadModels()
                }
            }
        }
        if includeTokenizer {
            Task { [store] in await store.clearAllSpanCaches() }
        }
    }
}
#endif
