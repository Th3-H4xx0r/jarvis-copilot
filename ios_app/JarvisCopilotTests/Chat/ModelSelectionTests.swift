import XCTest
@testable import JarvisCopilot

/// Port of `test/model_selection_test.dart`. The Flutter version drives
/// flutter_secure_storage over a mocked MethodChannel; here the boundary is
/// `KeyValueStore`, so an in-memory store stands in and "reload" is just a
/// second `ModelSelection` over the same store.
final class ModelSelectionTests: XCTestCase {

    private var store: MemoryKeyValueStore!
    private var sel: ModelSelection!

    override func setUp() {
        super.setUp()
        store = MemoryKeyValueStore()
        sel = ModelSelection(store: store)
    }

    func testSetForAndModelForRoundTripPerSurface() {
        sel.set(.chat, model: "anthropic/claude-opus-4.7", provider: "anthropic")

        XCTAssertEqual(sel.model(for: .chat), "anthropic/claude-opus-4.7")
        XCTAssertEqual(sel.provider(for: .chat), "anthropic")

        // Survives a fresh instance (i.e. it actually persisted to the store).
        let reloaded = ModelSelection(store: store)
        XCTAssertEqual(reloaded.model(for: .chat), "anthropic/claude-opus-4.7")
        XCTAssertEqual(reloaded.provider(for: .chat), "anthropic")
    }

    func testChatAndVoiceSelectionsAreIndependent() {
        sel.set(.chat, model: "anthropic/claude-opus-4.7", provider: "anthropic")
        sel.set(.voice, model: "openai/gpt-5.4-mini", provider: "openai")

        XCTAssertEqual(sel.model(for: .chat), "anthropic/claude-opus-4.7")
        XCTAssertEqual(sel.provider(for: .chat), "anthropic")
        XCTAssertEqual(sel.model(for: .voice), "openai/gpt-5.4-mini")
        XCTAssertEqual(sel.provider(for: .voice), "openai")

        // Reassigning one surface must not touch the other.
        sel.set(.voice, model: "google/gemini-2.5-flash", provider: "google")
        XCTAssertEqual(sel.model(for: .chat), "anthropic/claude-opus-4.7")
        XCTAssertEqual(sel.model(for: .voice), "google/gemini-2.5-flash")
    }

    func testGettersAreNilWhenNothingWasEverSetAndAfterClear() {
        XCTAssertNil(sel.model(for: .chat))
        XCTAssertNil(sel.provider(for: .chat))
        XCTAssertNil(sel.model(for: .voice))
        XCTAssertNil(sel.provider(for: .voice))

        sel.set(.chat, model: "anthropic/claude-opus-4.7", provider: "anthropic")
        sel.clear()
        XCTAssertNil(ModelSelection(store: store).model(for: .chat))
        XCTAssertNil(ModelSelection(store: store).provider(for: .chat))
    }

    func testPassingNilClearsAPreviouslySetField() {
        sel.set(.chat, model: "anthropic/claude-opus-4.7", provider: "anthropic")
        XCTAssertNotNil(sel.model(for: .chat))

        sel.set(.chat, model: nil, provider: nil)
        XCTAssertNil(sel.model(for: .chat))
        XCTAssertNil(sel.provider(for: .chat))

        // And it really cleared the persisted value.
        XCTAssertNil(ModelSelection(store: store).model(for: .chat))
    }

    func testAnEmptyStringIsTreatedAsNoSelection() {
        sel.set(.chat, model: "", provider: "")
        XCTAssertNil(sel.model(for: .chat))
        XCTAssertNil(sel.provider(for: .chat))
    }

    func testKeysMatchTheFlutterAppSoAPairedInstallKeepsItsChoice() {
        sel.set(.chat, model: "m1", provider: "p1")
        sel.set(.voice, model: "m2", provider: "p2")
        XCTAssertEqual(store.string("sel_chat_model"), "m1")
        XCTAssertEqual(store.string("sel_chat_provider"), "p1")
        XCTAssertEqual(store.string("sel_voice_model"), "m2")
        XCTAssertEqual(store.string("sel_voice_provider"), "p2")
    }
}

final class ModelsAPITests: XCTestCase {

    func testListParsesTheGroupedCatalogue() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: [
            "default_model": "anthropic/opus",
            "active_model": "openai/gpt",
            "active_provider": "openai",
            "groups": [
                ["provider": "anthropic", "models": [["id": "anthropic/opus", "label": "Opus"]]],
                ["provider": "openai", "models": [["id": "openai/gpt", "label": "GPT"], ["id": ""]]],
            ],
        ])
        let catalog = try await ModelsAPI(api: api).list()
        XCTAssertEqual(catalog.defaultModel, "anthropic/opus")
        XCTAssertEqual(catalog.activeModel, "openai/gpt")
        XCTAssertEqual(catalog.activeProvider, "openai")
        XCTAssertEqual(catalog.models.map(\.id), ["anthropic/opus", "openai/gpt"], "a model with no id is dropped")
        XCTAssertEqual(catalog.models.first?.label, "Opus")
        XCTAssertEqual(catalog.models.first?.provider, "anthropic")
        XCTAssertEqual(catalog.providers, ["anthropic", "openai"])
    }

    /// `provider` is the human-facing NAME the picker groups under ("Anthropic");
    /// `provider_id` is the canonical routing id the server wants back
    /// ("anthropic", "custom:foo"). Sending the display name as `model_provider`
    /// is how a pick silently ran on the server's default instead — see
    /// `_ModelOption.providerForSave` in `model_picker_sheet.dart`.
    func testListKeepsTheCanonicalProviderIDApartFromTheDisplayName() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["groups": [
            ["provider": "Anthropic", "provider_id": "anthropic",
             "models": [["id": "anthropic/opus", "label": "Opus"]]],
            ["provider": "My Box", "provider_id": "custom:box",
             "models": [["id": "box/llama", "label": "Llama"]]],
        ]])
        let catalog = try await ModelsAPI(api: api).list()

        XCTAssertEqual(catalog.models.map(\.provider), ["Anthropic", "My Box"],
                       "the picker still groups under the readable name")
        XCTAssertEqual(catalog.models.map(\.providerID), ["anthropic", "custom:box"])
        XCTAssertEqual(catalog.providers, ["Anthropic", "My Box"])
    }

    /// Older servers send no `provider_id` at all, and the display name is then
    /// the only routing id there is (Flutter's `providerForSave` fallback).
    func testAProviderIDFallsBackToTheDisplayNameWhenTheServerSendsNone() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["groups": [
            ["provider": "openai", "models": [["id": "openai/gpt"]]],
            ["provider": "spaced", "provider_id": "", "models": [["id": "s/1"]]],
        ]])
        let catalog = try await ModelsAPI(api: api).list()
        XCTAssertEqual(catalog.models.map(\.providerID), ["openai", "spaced"])
    }

    /// The flat list carries the pair per MODEL rather than per group.
    func testTheFlatListAlsoCarriesAProviderID() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["models": [
            ["id": "a/b", "provider": "Anthropic", "provider_id": "anthropic"],
            ["id": "c/d", "provider": "OpenAI"],
            "e/f",
        ]])
        let catalog = try await ModelsAPI(api: api).list()
        XCTAssertEqual(catalog.models.map(\.providerID), ["anthropic", "OpenAI", ""])
    }

    func testListAcceptsAFlatModelsArrayAndLabelsDefaultToTheID() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["models": [["id": "a/b"], "c/d"]])
        let catalog = try await ModelsAPI(api: api).list()
        XCTAssertEqual(catalog.models.map(\.id), ["a/b", "c/d"])
        XCTAssertEqual(catalog.models.first?.label, "a/b")
    }

    func testSetActivePostsOnlyTheFieldsGiven() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: [:])
        try await ModelsAPI(api: api).setActive(model: "a/b", provider: nil)
        XCTAssertEqual(t.lastRequest?.url?.path, "/api/model/active")
        XCTAssertEqual(t.lastBody() as? [String: String], ["model": "a/b"])
    }
}
