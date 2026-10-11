import XCTest
@testable import JarvisCopilot

/// Settings → Web & browser on the phone: the same `/api/web/config` the web's
/// block edits — extraction model (a model or a harness), browser engine, stealth.
@MainActor
final class WebBrowserSettingsTests: XCTestCase {
    private let server: [String: Any] = [
        "config": ["extract_model": "harness:extract", "engine": "lightpanda", "stealth_fallback": true],
        "engines": ["lightpanda", "chrome"], "lightpanda_installed": true,
    ]

    func testParsesTheServer() {
        let s = WebBrowserSettings.from(server)
        XCTAssertEqual(s.extractModel, "harness:extract")
        XCTAssertEqual(s.engine, "lightpanda")
        XCTAssertTrue(s.stealthFallback)
        XCTAssertTrue(s.lightpandaInstalled)
        XCTAssertEqual(WebBrowserSettings.from([:]).engine, "chrome")
    }

    func testHarnessesWithProblemsAreNotOffered() {
        let harnesses: [String: Any] = ["harnesses": [
            ["id": "extract", "name": "Extract fast", "problems": []],
            ["id": "broken", "name": "Broken", "problems": [["message": "A Route needs one default wire."]]],
        ]]
        XCTAssertEqual(WebBrowserStore.harnessChoices(harnesses),
                       [ExtractChoice(value: "harness:extract", label: "Extract fast")])
    }

    func testAPickedModelIsStoredWithItsProvider() {
        let custom = ChatModel(id: "qwen3:32b", label: "Qwen3 32B", provider: "Lab", providerID: "custom:lab")
        XCTAssertEqual(WebBrowserStore.ref(for: custom), "@custom:lab:qwen3:32b")
        let deduped = ChatModel(id: "@anthropic-api:claude-haiku-5-5", label: "Claude Haiku 5.5",
                                provider: "Anthropic API", providerID: "anthropic-api")
        XCTAssertEqual(WebBrowserStore.ref(for: deduped), "@anthropic-api:claude-haiku-5-5")
        XCTAssertEqual(WebBrowserStore.ref(for: nil), "")
    }

    func testSaveSendsOnlyTheChange() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/web/config", json: server)
        let store = WebBrowserStore(api: WebBrowserAPI(api: api))
        await store.load()
        await store.setEngine("chrome")
        XCTAssertEqual(transport.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(transport.lastBody() as NSDictionary, ["engine": "chrome"] as NSDictionary)
    }

    func testAFailedSaveRollsBack() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: server)
        transport.enqueue(json: [:])
        transport.enqueue(json: [:])
        transport.enqueue(json: ["error": "extract_model must be empty, @provider:model or harness:<id>"], status: 400)
        let store = WebBrowserStore(api: WebBrowserAPI(api: api))
        await store.load()
        await store.setExtractModel("bad ref")
        XCTAssertEqual(store.settings.extractModel, "harness:extract")
        XCTAssertFalse(store.error.isEmpty)
    }
}
