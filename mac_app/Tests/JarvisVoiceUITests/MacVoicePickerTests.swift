import XCTest
@testable import JarvisVoiceUI

/// The Mac's voice picker offers harnesses as well as models — a pick for THIS
/// Mac only, kept in the same keys the shared voice transport reads.
///
/// Pranav (2026-10-12): "for the macbook, I need a option to choose a harness
/// as the default, since right now, I can only choose a single model".
@MainActor
final class MacVoicePickerTests: XCTestCase {
    private let suiteName = "MacVoicePickerTests"
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let snapshot: [String: Any] = [
        "harnesses": [
            ["id": "single", "name": "Single model", "nodes": [], "edges": [], "problems": []],
            ["id": "fast-claude", "name": "Fast + Claude", "icon": "⚡", "nodes": [], "edges": [], "problems": []],
            ["id": "mine", "name": "Mine", "nodes": [], "edges": [], "problems": []],
            ["id": "broken", "name": "Broken", "nodes": [], "edges": [],
             "problems": [["message": "A Route needs one default wire."]]],
        ],
        "assignments": ["default": "mine", "voice": "fast-claude", "chat": "mine"],
        "overrides": ["voice": "fast-claude", "chat": ""],
    ]

    private let catalog: [String: Any] = [
        "default_model": "claude-sonnet-5-5",
        "groups": [["provider": "Anthropic API", "provider_id": "anthropic-api", "models": [
            ["id": "claude-sonnet-5-5", "label": "Claude Sonnet 5.5"],
            ["id": "claude-haiku-5-5", "label": "Claude Haiku 5.5"]]]],
    ]

    private func makePicker() async -> MacModelPicker {
        let api = JarvisAPI(credentials: StubCredentials(),
                            transport: StubTransport(["/api/harnesses": snapshot, "/api/models": catalog]))
        let models = VoiceModelStore(api: api, selection: ModelSelection(store: suite))
        let picker = MacModelPicker(api: api, models: models, defaults: suite)
        await models.load()
        await picker.loadHarnesses()
        return picker
    }

    private func items(_ rows: [PickerRow]) -> [PickerRow] { rows.filter { $0.kind == .item } }

    func testParsesTheHarnessesAndWhatVoiceRuns() {
        let list = MacHarnessList(json: snapshot)
        XCTAssertEqual(list.voiceDefaultID, "fast-claude")
        XCTAssertEqual(list.title(for: "fast-claude"), "⚡ Fast + Claude")
        XCTAssertEqual(list.title(for: "gone"), "gone")
        XCTAssertEqual(list.harnesses.first { $0.id == "broken" }?.ok, false)
    }

    /// "Voice default (Name)" first, then the harnesses that can run (not
    /// Single — that is what a model row picks), then the models.
    func testOffersVoiceDefaultThenHarnessesThenModels() async {
        let picker = await makePicker()
        let rows = picker.harnessRows()
        XCTAssertEqual(rows.first?.kind, .header)
        XCTAssertEqual(rows.first?.title, "Harness")
        XCTAssertEqual(items(rows).map(\.title),
                       ["Voice default (⚡ Fast + Claude)", "⚡ Fast + Claude", "Mine",
                        "Claude Sonnet 5.5", "Claude Haiku 5.5"])
        XCTAssertEqual(items(rows).filter(\.checked).map(\.title), ["Voice default (⚡ Fast + Claude)"])
        XCTAssertFalse(rows.contains { $0.title == "Auto" }, "Auto is what Voice default means now")
        XCTAssertEqual(picker.chipLabel, "Voice default")
    }

    func testPickingAHarnessWritesThisMacsKeys() async {
        let picker = await makePicker()
        ModelSelection(store: suite).set(.voice, model: "claude-haiku-5-5", provider: "anthropic-api")
        items(picker.harnessRows()).first { $0.title == "Mine" }?.action()
        XCTAssertEqual(suite.string(forKey: voiceHarnessDefaultsKey), "mine")
        XCTAssertNil(ModelSelection(store: suite).model(for: .voice), "a harness picks its own models")
        XCTAssertEqual(items(picker.harnessRows()).filter(\.checked).map(\.title), ["Mine"])
        XCTAssertEqual(picker.chipLabel, "Mine")
    }

    func testPickingAModelRunsSingleWithIt() async {
        let picker = await makePicker()
        items(picker.harnessRows()).first { $0.title == "Claude Haiku 5.5" }?.action()
        XCTAssertEqual(suite.string(forKey: voiceHarnessDefaultsKey), "single")
        XCTAssertEqual(ModelSelection(store: suite).model(for: .voice), "claude-haiku-5-5")
        XCTAssertEqual(ModelSelection(store: suite).provider(for: .voice), "anthropic-api")
        XCTAssertEqual(items(picker.harnessRows()).filter(\.checked).map(\.title), ["Claude Haiku 5.5"])
        XCTAssertEqual(picker.chipLabel, "Claude Haiku 5.5")
    }

    func testVoiceDefaultClearsBothKeys() async {
        let picker = await makePicker()
        items(picker.harnessRows()).first { $0.title == "Claude Haiku 5.5" }?.action()
        items(picker.harnessRows()).first { $0.title.hasPrefix("Voice default") }?.action()
        XCTAssertNil(suite.string(forKey: voiceHarnessDefaultsKey))
        XCTAssertNil(ModelSelection(store: suite).model(for: .voice))
        XCTAssertEqual(picker.chipLabel, "Voice default")
    }

    /// A model picked before harnesses (no harness key) still runs as an
    /// explicit pick, i.e. Single with that model — so that is what is ticked.
    func testAModelPickedBeforeHarnessesReadsAsSingle() async {
        ModelSelection(store: suite).set(.voice, model: "claude-sonnet-5-5", provider: "anthropic-api")
        let picker = await makePicker()
        XCTAssertEqual(items(picker.harnessRows()).filter(\.checked).map(\.title), ["Claude Sonnet 5.5"])
        XCTAssertEqual(picker.chipLabel, "Claude Sonnet 5.5")
    }

    func testAPickSurvivesANewPicker() async {
        let first = await makePicker()
        items(first.harnessRows()).first { $0.title == "Mine" }?.action()
        let second = await makePicker()
        XCTAssertEqual(items(second.harnessRows()).filter(\.checked).map(\.title), ["Mine"])
    }
}

private struct StubCredentials: APICredentials {
    var baseURL: URL? = URL(string: "http://127.0.0.1:9")
    var headers: [String: String] = [:]
}

/// Answers each path with its JSON; anything else is an empty object.
private final class StubTransport: APITransport, @unchecked Sendable {
    private let routes: [String: Any]

    init(_ routes: [String: Any]) { self.routes = routes }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = routes[request.url?.path ?? ""] ?? [String: Any]()
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        return (try JSONSerialization.data(withJSONObject: body), http)
    }

    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}
