import XCTest
@testable import JarvisCopilot

/// The store behind the On-device AI settings screen. The Flutter page saved from
/// every `onChanged`, so the contract under test is "a toggle survives leaving
/// the screen", plus the availability/model rendering the screen reads.
@MainActor
final class OnDeviceAISettingsStoreTests: XCTestCase {

    private func store(kv: KeyValueStore,
                       availability: OnDeviceEngineAvailability = .available)
    -> (OnDeviceAISettingsStore, LocalAiSettings) {
        let settings = LocalAiSettings(store: kv)
        let ai = OnDeviceAI(engine: FakeOnDeviceEngine(availability: availability),
                            settings: settings,
                            persona: OnDevicePersona())
        return (OnDeviceAISettingsStore(ai: ai, settings: settings), settings)
    }

    // MARK: - Persistence

    func testEveryToggleWritesThroughImmediately() async {
        let kv = MemoryKeyValueStore()
        let (screen, _) = store(kv: kv)
        await screen.load()

        screen.setTier(.fullLocalFirst)
        screen.setChatEnabled(true)
        screen.setVoiceEnabled(true)
        screen.setConfirmLocalActions(false)
        screen.setCommandShortCircuit(false)
        screen.setShowBadge(false)

        // A completely fresh settings object over the same store — i.e. the next
        // launch — must see all of it.
        let reloaded = LocalAiSettings(store: kv)
        reloaded.load()
        XCTAssertEqual(reloaded.tier, .fullLocalFirst)
        XCTAssertTrue(reloaded.chatEnabled)
        XCTAssertTrue(reloaded.voiceEnabled)
        XCTAssertFalse(reloaded.confirmLocalActions)
        XCTAssertFalse(reloaded.commandShortCircuit)
        XCTAssertFalse(reloaded.showBadge)
    }

    func testLoadReadsPersistedPreferences() async {
        let kv = MemoryKeyValueStore()
        let saved = LocalAiSettings(store: kv)
        saved.tier = .routerCommands
        saved.voiceEnabled = true
        saved.save()

        let (screen, settings) = store(kv: kv)
        await screen.load()
        XCTAssertEqual(settings.tier, .routerCommands)
        XCTAssertTrue(settings.enabledForVoice)
    }

    // MARK: - Model selection

    func testSelectingAnInstalledModelPersists() async {
        let kv = MemoryKeyValueStore()
        let (screen, _) = store(kv: kv)
        await screen.load()
        guard let appleFM = screen.models.first(where: { $0.id == "apple-fm" }) else {
            return XCTFail("apple-fm missing from the catalogue")
        }
        screen.selectModel(appleFM)
        XCTAssertEqual(screen.activeModelID, "apple-fm")

        let reloaded = LocalAiSettings(store: kv)
        reloaded.load()
        XCTAssertEqual(reloaded.activeLocalModelID, "apple-fm")
    }

    /// Picking a model that isn't there would point the router at an engine that
    /// always fails, so the row is inert.
    func testSelectingAnUninstalledModelIsIgnored() async {
        let (screen, _) = store(kv: MemoryKeyValueStore())
        await screen.load()
        guard let mlx = screen.models.first(where: { $0.engine == .mlx }) else {
            return XCTFail("the MLX slot must stay listed")
        }
        screen.selectModel(mlx)
        XCTAssertEqual(screen.activeModelID, "apple-fm")
    }

    // MARK: - Availability card

    func testAvailabilitySummaryReadsReadyWhenTheEngineIs() async {
        let (screen, _) = store(kv: MemoryKeyValueStore(), availability: .available)
        XCTAssertEqual(screen.availabilitySummary, "Checking on-device engine…")
        await screen.load()
        XCTAssertTrue(screen.isReady)
        XCTAssertEqual(screen.availabilitySummary, "On-device engine ready (apple-fm)")
    }

    func testAvailabilitySummaryShowsTheReasonWhenItIsNot() async {
        let (screen, _) = store(kv: MemoryKeyValueStore(),
                                availability: .unavailable("appleIntelligenceNotEnabled"))
        await screen.load()
        XCTAssertFalse(screen.isReady)
        XCTAssertEqual(screen.availabilitySummary, "Unavailable: appleIntelligenceNotEnabled")
        XCTAssertFalse(screen.models.first?.installed ?? true)
    }

    // MARK: - Debug generate

    func testDebugGenerateStreamsTheEngineOutput() async {
        let settings = LocalAiSettings(store: MemoryKeyValueStore())
        let ai = OnDeviceAI(engine: FakeOnDeviceEngine(chunks: ["Hello", ", sir."]),
                            settings: settings, persona: OnDevicePersona())
        let screen = OnDeviceAISettingsStore(ai: ai, settings: settings)
        screen.prompt = "hi"
        screen.runDebugGenerate()
        let done = await onDeviceWaitUntil { !screen.running && !screen.output.isEmpty }
        XCTAssertTrue(done, "generate never finished")
        XCTAssertEqual(screen.output, "Hello, sir.")
    }

    func testDebugGenerateIgnoresAnEmptyPrompt() {
        let (screen, _) = store(kv: MemoryKeyValueStore())
        screen.prompt = "   "
        screen.runDebugGenerate()
        XCTAssertFalse(screen.running)
        XCTAssertEqual(screen.output, "")
    }
}

/// Settle until `condition` holds — prefixed so it can't collide with another
/// area's helper (`waitUntilVoice`, `chatWaitUntil`, …).
@discardableResult
@MainActor
func onDeviceWaitUntil(_ timeoutMs: Int = 3000, _ condition: () -> Bool) async -> Bool {
    var waited = 0
    while waited < timeoutMs {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
        waited += 1
    }
    return condition()
}
