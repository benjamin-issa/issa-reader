#if !os(tvOS)
import Foundation
import IssaAsk
import Testing

@testable import IssaReader_iOS

@Suite("AskEmbeddingCoordinatorTests")
@MainActor
struct AskEmbeddingCoordinatorTests {
    @Test("Settings row hides Download when Ask cannot run, but keeps Remove visible if installed")
    func settingsRowVisibility() {
        // Ask enabled & device ready -> offered.
        #expect(AskSettingsSection.offersEmbeddingModelRow(
            availability: .available, providers: [], askEnabled: true, modelState: .notInstalled,
        ))
        // Ask turned off while not installed -> hidden.
        #expect(!AskSettingsSection.offersEmbeddingModelRow(
            availability: .available, providers: [], askEnabled: false, modelState: .notInstalled,
        ))
        // Ask turned off while already installed -> stays visible so ~307 MB is never stranded.
        #expect(AskSettingsSection.offersEmbeddingModelRow(
            availability: .available, providers: [], askEnabled: false, modelState: .ready,
        ))
        // Apple Intelligence off with no provider keys -> hidden when not installed.
        #expect(!AskSettingsSection.offersEmbeddingModelRow(
            availability: .appleIntelligenceOff, providers: [], askEnabled: true, modelState: .notInstalled,
        ))
        // Provider key registered on eligible hardware without Apple Intelligence -> offered.
        #expect(AskSettingsSection.offersEmbeddingModelRow(
            availability: .unsupportedDevice, providers: [.openAI], askEnabled: true, modelState: .notInstalled,
            hardwareSupported: true,
        ))
        // Unsupported older hardware (< 6 GB RAM or < 16-core ANE) -> hidden when not installed,
        // so the app falls back cleanly to upstream.
        #expect(!AskSettingsSection.offersEmbeddingModelRow(
            availability: .unsupportedDevice, providers: [.openAI], askEnabled: true, modelState: .notInstalled,
            hardwareSupported: false,
        ))
        // If a model was already on disk (e.g. installed before the gate existed or migrated
        // device) on unsupported hardware, keep the row visible so the reader can remove it.
        #expect(AskSettingsSection.offersEmbeddingModelRow(
            availability: .unsupportedDevice, providers: [.openAI], askEnabled: true, modelState: .ready,
            hardwareSupported: false,
        ))
    }

    @Test("Settings footer discloses the one-time GitHub download when offered")
    func settingsNoteDisclosure() {
        let withoutRow = AskSettingsSection.note(
            for: .available, askEnabled: true, cloudOffered: false, providers: [], searchModelOffered: false,
        )
        #expect(!withoutRow.contains("GitHub"))

        let withRow = AskSettingsSection.note(
            for: .available, askEnabled: true, cloudOffered: false, providers: [], searchModelOffered: true,
        )
        #expect(withRow.contains("GitHub"))
        #expect(withRow.contains(AskDevice.noun))
    }

    @Test("Download errors translate to plain reader prose without internal paths")
    func errorMessagesStayPlain() {
        let checksum = AskCoordinator.downloadErrorMessage(for: CoreMLEmbeddingModel.ModelError.checksumMismatch)
        #expect(!checksum.contains("weights"))
        #expect(!checksum.contains(".bin"))

        let offline = AskCoordinator.downloadErrorMessage(for: URLError(.notConnectedToInternet))
        #expect(offline.contains("internet"))
    }

    @Test("EmbeddingPolicy catches up hard when behind, self-governs after 10s, and cruises cool in look-ahead")
    func embeddingPolicyPacingMatrix() {
        // 1. Live on-device Ask yields ANE immediately for both tiers.
        let liveAsk = EmbeddingPolicy.DeviceConditions(onDeviceAskRunning: true)
        #expect(EmbeddingPolicy.pace(tier: .catchUp, conditions: liveAsk) == nil)
        #expect(EmbeddingPolicy.pace(tier: .lookAhead, conditions: liveAsk) == nil)

        // 2. Nominal on battery: catch-up runs full blast for first 10s, then steps down to 50% duty.
        let nomBattery = EmbeddingPolicy.DeviceConditions(thermalState: .nominal, isCharging: false, batteryLevel: 0.75)
        let burst = EmbeddingPolicy.pace(tier: .catchUp, conditions: nomBattery)
        #expect(burst?.batchSize == 8)
        #expect(burst?.cooldown == .zero)
        #expect(burst?.priority == .utility)

        var sustained = nomBattery
        sustained.sustainedCatchUpSeconds = 12
        let governed = EmbeddingPolicy.pace(tier: .catchUp, conditions: sustained)
        #expect(governed?.batchSize == 4)
        #expect(governed?.cooldown == .milliseconds(200))

        // 3. Look-ahead on battery runs cool micro-bursts at `.background` QoS.
        let lookAhead = EmbeddingPolicy.pace(tier: .lookAhead, conditions: nomBattery)
        #expect(lookAhead?.batchSize == 4)
        #expect(lookAhead?.cooldown == .milliseconds(2_500))
        #expect(lookAhead?.priority == .background)

        // 4. Slowdown > 2x doubles look-ahead cooldown.
        var contended = nomBattery
        contended.slowdownFactor = 2.5
        #expect(EmbeddingPolicy.pace(tier: .lookAhead, conditions: contended)?.cooldown == .seconds(5))

        // 5. Charging boost accelerates look-ahead; thermal hysteresis holds look-ahead.
        let charging = EmbeddingPolicy.DeviceConditions(thermalState: .nominal, isCharging: true, batteryLevel: 0.80)
        #expect(EmbeddingPolicy.pace(tier: .lookAhead, conditions: charging)?.batchSize == 8)
        #expect(EmbeddingPolicy.pace(tier: .lookAhead, conditions: charging)?.cooldown == .milliseconds(400))

        var hysteresis = charging
        hysteresis.inThermalHysteresis = true
        #expect(EmbeddingPolicy.pace(tier: .lookAhead, conditions: hysteresis) == nil)

        // 6. Fair thermal pauses look-ahead, throttles catch-up; serious/LPM allow catch-up only when Ask sheet open.
        let fair = EmbeddingPolicy.DeviceConditions(thermalState: .fair, isCharging: false, batteryLevel: 0.80)
        #expect(EmbeddingPolicy.pace(tier: .lookAhead, conditions: fair) == nil)
        #expect(EmbeddingPolicy.pace(tier: .catchUp, conditions: fair)?.cooldown == .milliseconds(1_500))

        let lpmClosed = EmbeddingPolicy.DeviceConditions(thermalState: .nominal, isLowPowerMode: true, askSheetOpen: false)
        let lpmOpen = EmbeddingPolicy.DeviceConditions(thermalState: .nominal, isLowPowerMode: true, askSheetOpen: true)
        #expect(EmbeddingPolicy.pace(tier: .catchUp, conditions: lpmClosed) == nil)
        #expect(EmbeddingPolicy.pace(tier: .catchUp, conditions: lpmOpen)?.priority == .userInitiated)
        #expect(EmbeddingPolicy.pace(tier: .lookAhead, conditions: lpmOpen) == nil)

        // 7. Low battery (<20% unplugged) holds look-ahead, throttles catch-up.
        let lowBatt = EmbeddingPolicy.DeviceConditions(thermalState: .nominal, isCharging: false, batteryLevel: 0.15)
        #expect(EmbeddingPolicy.pace(tier: .lookAhead, conditions: lowBatt) == nil)
        #expect(EmbeddingPolicy.pace(tier: .catchUp, conditions: lowBatt)?.cooldown == .seconds(1))

        // 8. Critical always pauses both tiers, even with Ask sheet open.
        let critical = EmbeddingPolicy.DeviceConditions(thermalState: .critical, askSheetOpen: true)
        #expect(EmbeddingPolicy.pace(tier: .catchUp, conditions: critical) == nil)
        #expect(EmbeddingPolicy.pace(tier: .lookAhead, conditions: critical) == nil)
    }

    @Test("EmbeddingScheduler stop-then-restart keeps the replacement driver intact")
    func schedulerStopRestartDoesNotClearNewDriver() async throws {
        actor SlowMockEmbedder: EmbeddingModel {
            nonisolated let modelID = "slow-mock"
            private var inFlight = 0
            private(set) var maxConcurrent = 0
            private(set) var calls = 0

            func embed(_ texts: [String], mode: EmbeddingMode) async throws -> [[Float]] {
                calls += 1
                inFlight += 1
                maxConcurrent = max(maxConcurrent, inFlight)
                defer { inFlight -= 1 }
                try? await Task.sleep(for: .milliseconds(120))
                return texts.map { _ in [1, 0, 0, 0] }
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appending(path: "issa-sched-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "issa.sched.race.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AskIndexStore(directory: dir)
        let embedder = SlowMockEmbedder()
        let preparer = AskEngine(
            model: ScriptedAnswerModel(), store: store, tools: [], turnstile: AskTurnstile(),
        )
        let scheduler = EmbeddingScheduler(
            store: store,
            preparer: preparer,
            defaults: defaults,
            coreMLEmbedder: nil,
            activeEmbedder: { embedder },
            onIndexingBooksChanged: { _ in },
            centre: NotificationCenter(),
        )

        let bookA = try AskCoordinatorTests.source(uuid: "race-a-\(UUID().uuidString)")
        let bookB = try AskCoordinatorTests.source(uuid: "race-b-\(UUID().uuidString)")

        // Start indexing book A, wait briefly so its batch is mid-flight, then
        // immediately deactivate A and activate B before A's uncancellable batch ends.
        scheduler.activateBook(source: bookA, chapterIndex: 2)
        try await Task.sleep(for: .milliseconds(40))
        scheduler.deactivateBook(bookA.bookUUID)
        scheduler.activateBook(source: bookB, chapterIndex: 2)

        // Wait past A's 120 ms batch unwind; B's driver must still be intact.
        try await Task.sleep(for: .milliseconds(160))
        let totalCalls = await embedder.calls
        #expect(scheduler.isDriverRunning || totalCalls >= 2)
        scheduler.deactivateBook(bookB.bookUUID)
    }
}
#endif
