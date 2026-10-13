import XCTest
@testable import JarvisCopilot

/// One default (a model via Single, or a harness) that every surface follows
/// unless Voice/Chat (or a device) has its own pick.
///
/// Pranav (2026-10-12): "can you add support for a harness to be used as the
/// default instead of it being a single model only. Add this across all
/// platforms, for mac, ios, pod, etc."
@MainActor
final class HarnessDefaultTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "HarnessDefaultTests"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let harnesses: [[String: Any]] = [
        ["id": "single", "name": "Single model", "builtin": true, "nodes": [], "edges": [], "problems": []],
        ["id": "mine", "name": "Mine", "nodes": [], "edges": [], "problems": []],
        ["id": "router", "name": "Router", "icon": "🧭", "nodes": [], "edges": [], "problems": []],
        ["id": "broken", "name": "Broken", "nodes": [], "edges": [],
         "problems": [["node": NSNull(), "edge": NSNull(), "message": "A Route needs one default wire."]]],
    ]

    private func snapshot(assignments: [String: String], overrides: [String: String]?) -> [String: Any] {
        var out: [String: Any] = ["harnesses": harnesses, "assignments": assignments]
        if let overrides { out["overrides"] = overrides }
        return out
    }

    private func makeStore() -> (HarnessStore, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        let models = VoiceModelStore(api: api, selection: ModelSelection(store: suite))
        return (HarnessStore(api: HarnessAPI(api: api), defaults: suite, voiceModels: models), transport)
    }

    // MARK: Parsing

    func testReadsTheDefaultAndTheOverrides() async {
        let (store, transport) = makeStore()
        transport.route("/api/harnesses", json: snapshot(
            assignments: ["default": "mine", "voice": "router", "chat": "mine"],
            overrides: ["voice": "router", "chat": ""]))
        await store.refresh()
        XCTAssertEqual(store.defaultID, "mine")
        XCTAssertEqual(store.overrides, ["voice": "router", "chat": ""])
        XCTAssertEqual(store.effective("voice"), "router")
        XCTAssertEqual(store.effective("chat"), "mine", "an empty override follows the default")
        XCTAssertEqual(store.effective("messaging"), "mine", "surfaces with no override slot get the default")
        XCTAssertEqual(store.current(for: .chat, sessionHarnessID: nil), "mine")
    }

    /// A server from before the one default sends just the effective Voice/Chat.
    func testAnOlderServerReadsChatAsTheDefault() async {
        let (store, transport) = makeStore()
        transport.route("/api/harnesses", json: snapshot(
            assignments: ["voice": "router", "chat": "mine"], overrides: nil))
        await store.refresh()
        XCTAssertEqual(store.defaultID, "mine")
        XCTAssertEqual(store.overrides, ["voice": "router", "chat": ""])
        XCTAssertEqual(store.effective("voice"), "router")
        XCTAssertEqual(store.effective("chat"), "mine")
    }

    func testAnOverrideNamingAMissingHarnessFallsBackToTheDefault() async {
        let (store, transport) = makeStore()
        transport.route("/api/harnesses", json: snapshot(
            assignments: ["default": "mine", "voice": "mine", "chat": "mine"],
            overrides: ["voice": "gone", "chat": ""]))
        await store.refresh()
        XCTAssertEqual(store.effective("voice"), "mine")
    }

    // MARK: Assigning

    func testClearingTheVoiceOverrideSendsEmptyAndKeepsTheReply() async {
        let (store, transport) = makeStore()
        transport.route("/api/harnesses/assign", json: [
            "ok": true, "assignments": ["default": "mine", "voice": "mine", "chat": "mine"],
            "overrides": ["voice": "", "chat": ""]])
        await store.assign("", to: "voice")
        XCTAssertEqual(transport.lastPath, "/api/harnesses/assign")
        assertJSONEqual(transport.lastBody(), ["surface": "voice", "harness_id": ""])
        XCTAssertEqual(store.overrides["voice"], "")
        XCTAssertEqual(store.defaultID, "mine")
        XCTAssertEqual(store.effective("voice"), "mine")
        XCTAssertNil(store.errorMessage)
    }

    func testSettingTheDefaultToAHarness() async {
        let (store, transport) = makeStore()
        transport.route("/api/harnesses/assign", json: [
            "ok": true, "assignments": ["default": "router", "voice": "router", "chat": "router"],
            "overrides": ["voice": "", "chat": ""]])
        await store.assign("router", to: "default")
        assertJSONEqual(transport.lastBody(), ["surface": "default", "harness_id": "router"])
        XCTAssertEqual(store.defaultID, "router")
        XCTAssertEqual(store.effective("chat"), "router")
    }

    /// Picking a model as the default: the model first, and only once the server
    /// took it does the default switch to Single — never half a change.
    func testAModelDefaultSetsTheModelThenSingle() async {
        let (store, transport) = makeStore()
        transport.route("/api/default-model", json: ["ok": true, "model": "claude-haiku-5-5"])
        transport.route("/api/harnesses/assign", json: [
            "ok": true, "assignments": ["default": "single", "voice": "router", "chat": "single"],
            "overrides": ["voice": "router", "chat": ""]])
        let ok = await store.setDefaultModel("@anthropic-api:claude-haiku-5-5")
        XCTAssertTrue(ok)
        XCTAssertEqual(transport.paths, ["/api/default-model", "/api/harnesses/assign"])
        assertJSONEqual(transport.body(0), ["model": "@anthropic-api:claude-haiku-5-5"])
        assertJSONEqual(transport.body(1), ["surface": "default", "harness_id": "single"])
        XCTAssertEqual(store.defaultID, "single")
    }

    func testARefusedModelLeavesTheDefaultAlone() async {
        let (store, transport) = makeStore()
        transport.route("/api/harnesses", json: snapshot(
            assignments: ["default": "mine", "voice": "mine", "chat": "mine"],
            overrides: ["voice": "", "chat": ""]))
        await store.refresh()
        transport.route("/api/default-model", json: ["error": "model is required"], status: 400)
        let before = transport.requests.count
        let ok = await store.setDefaultModel("@nowhere:nothing")
        XCTAssertFalse(ok)
        XCTAssertEqual(Array(transport.paths.dropFirst(before)), ["/api/default-model"], "no assign after a refusal")
        XCTAssertEqual(store.defaultID, "mine")
        XCTAssertNotNil(store.errorMessage)
    }

    /// "Model for Single and fallbacks" changes the model only, never the default.
    func testTheSingleModelRowLeavesTheHarnessDefault() async {
        let (store, transport) = makeStore()
        transport.route("/api/default-model", json: ["ok": true, "model": "claude-haiku-5-5"])
        let ok = await store.setSingleModel("@anthropic-api:claude-haiku-5-5")
        XCTAssertTrue(ok)
        XCTAssertEqual(transport.paths, ["/api/default-model"])
    }

    // MARK: The voice transport's key

    /// The voice transport reads `sel_voice_harness`. It carries the Voice
    /// OVERRIDE only: with none, nothing is sent and the server resolves the
    /// default at turn time, so a default changed elsewhere is never stale here.
    func testTheVoiceKeyMirrorsTheOverride() async {
        let (store, transport) = makeStore()
        // Routes match by substring, first wins: the assign route goes first.
        transport.route("/api/harnesses/assign", json: [
            "ok": true, "assignments": ["default": "mine", "voice": "mine", "chat": "mine"],
            "overrides": ["voice": "", "chat": ""]])
        transport.route("/api/harnesses", json: snapshot(
            assignments: ["default": "mine", "voice": "router", "chat": "mine"],
            overrides: ["voice": "router", "chat": ""]))
        await store.refresh()
        XCTAssertEqual(suite.string(forKey: voiceHarnessDefaultsKey), "router")

        await store.assign("", to: "voice")
        XCTAssertNil(suite.string(forKey: voiceHarnessDefaultsKey))
    }

    /// A voice model with no harness is an explicit pick (the server runs Single
    /// with it), so following the default leaves no voice model behind.
    func testFollowingTheDefaultDropsALeftoverVoiceModel() async {
        let (store, transport) = makeStore()
        ModelSelection(store: suite).set(.voice, model: "gpt-5", provider: "openai")
        transport.route("/api/harnesses/assign", json: [
            "ok": true, "assignments": ["default": "mine", "voice": "mine", "chat": "mine"],
            "overrides": ["voice": "", "chat": ""]])
        transport.route("/api/harnesses", json: snapshot(
            assignments: ["default": "mine", "voice": "single", "chat": "mine"],
            overrides: ["voice": "single", "chat": ""]))
        await store.refresh()
        XCTAssertEqual(ModelSelection(store: suite).model(for: .voice), "gpt-5", "Single keeps its model")

        await store.assign("", to: "voice")
        XCTAssertNil(ModelSelection(store: suite).model(for: .voice))
        XCTAssertNil(voiceTurnHarnessID(suite))
    }

    // MARK: Labels

    func testTheVoiceChipNamesTheDefaultWhenVoiceFollowsIt() {
        let (store, _) = makeStore()
        store.harnesses = decoded()
        store.applyAssignments(["default": "router", "voice": "router", "chat": "router"],
                               overrides: ["voice": "", "chat": ""])
        XCTAssertEqual(store.label(for: .voice, sessionHarnessID: nil, singleModelLabel: "Sonnet"), "🧭 Router")
        XCTAssertEqual(store.sameAsDefaultTitle, "Same as default (🧭 Router)")
        store.applyAssignments(["default": "single", "voice": "single", "chat": "single"],
                               overrides: ["voice": "", "chat": ""])
        XCTAssertEqual(store.label(for: .voice, sessionHarnessID: nil, singleModelLabel: "Sonnet"), "Sonnet")
    }

    func testThePodsEmptyChoiceNamesTheVoiceHarness() {
        let names = ["fast-claude": "Fast + Claude", "single": "Single model"]
        XCTAssertEqual(PodVoiceChoice.harnessTitle("", names: names, voiceDefaultID: "fast-claude"),
                       "Voice default (Fast + Claude)")
        XCTAssertEqual(PodVoiceChoice.harnessTitle("", names: names, voiceDefaultID: nil), "Voice default",
                       "before the harnesses load")
        XCTAssertEqual(PodVoiceChoice.harnessTitle("single", names: names, voiceDefaultID: "fast-claude"),
                       "Single model")
    }

    // MARK: Settings → Default

    private func decoded() -> [AgentHarness] {
        let data = try! JSONSerialization.data(withJSONObject: snapshot(assignments: [:], overrides: nil))
        return try! JSONDecoder().decode(HarnessSnapshot.self, from: data).harnesses
    }

    private let catalog: [String: Any] = [
        "default_model": "claude-sonnet-5-5",
        "groups": [["provider": "Anthropic API", "provider_id": "anthropic-api", "models": [
            ["id": "claude-sonnet-5-5", "label": "Claude Sonnet 5.5"],
            ["id": "claude-haiku-5-5", "label": "Claude Haiku 5.5"]]]],
    ]

    private func makeDefaultChoice() -> (DefaultChoiceStore, HarnessStore, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        let models = VoiceModelStore(api: api, selection: ModelSelection(store: suite))
        let harnesses = HarnessStore(api: HarnessAPI(api: api), defaults: suite, voiceModels: models)
        return (DefaultChoiceStore(harnesses: harnesses, api: api), harnesses, transport)
    }

    func testTheDefaultScreenOffersWorkingHarnessesAndNamesTheChoice() async {
        let (choice, _, transport) = makeDefaultChoice()
        transport.route("/api/harnesses", json: snapshot(
            assignments: ["default": "single", "voice": "router", "chat": "single"],
            overrides: ["voice": "router", "chat": ""]))
        transport.route("/api/models", json: catalog)
        await choice.load()
        XCTAssertEqual(choice.harnessChoices.map(\.id), ["mine", "router"],
                       "Single is the model row; a harness with problems would quietly run as Single")
        XCTAssertFalse(choice.isHarnessDefault)
        XCTAssertEqual(choice.currentLabel, "Claude Sonnet 5.5")
        XCTAssertEqual(choice.modelLabel, "Claude Sonnet 5.5")
    }

    func testPickingOnTheDefaultScreen() async {
        let (choice, harnesses, transport) = makeDefaultChoice()
        transport.route("/api/harnesses/assign", json: [
            "ok": true, "assignments": ["default": "router", "voice": "router", "chat": "router"],
            "overrides": ["voice": "", "chat": ""]])
        transport.route("/api/default-model", json: ["ok": true, "model": "claude-haiku-5-5"])
        transport.route("/api/harnesses", json: snapshot(
            assignments: ["default": "single", "voice": "single", "chat": "single"],
            overrides: ["voice": "", "chat": ""]))
        transport.route("/api/models", json: catalog)
        await choice.load()
        let loaded = transport.requests.count

        await choice.chooseHarness("router")
        XCTAssertEqual(harnesses.defaultID, "router")
        XCTAssertTrue(choice.isHarnessDefault)
        XCTAssertEqual(choice.currentLabel, "🧭 Router")

        let haiku = ChatModel(id: "claude-haiku-5-5", label: "Claude Haiku 5.5",
                              provider: "Anthropic API", providerID: "anthropic-api")
        await choice.chooseSingleModel(haiku)
        XCTAssertEqual(Array(transport.paths.dropFirst(loaded)),
                       ["/api/harnesses/assign", "/api/default-model"],
                       "the fallback model never moves the default")
        assertJSONEqual(transport.lastBody(), ["model": "@anthropic-api:claude-haiku-5-5"])
        XCTAssertEqual(choice.modelLabel, "Claude Haiku 5.5")
        XCTAssertEqual(harnesses.defaultID, "router")
    }
}
