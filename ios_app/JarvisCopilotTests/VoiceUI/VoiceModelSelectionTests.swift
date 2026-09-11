import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The voice surface's own LLM choice — the half of `model_picker_sheet.dart` +
/// `_voiceModelFields()` the Swift port was missing (the picker only offered the
/// TTS engine, so the model could never be changed from the phone).
@MainActor
final class VoiceModelSelectionTests: XCTestCase {

    // MARK: - Short label (ModelChip._label)

    func testShortLabelFallsBackToAutoWhenNothingIsChosen() {
        XCTAssertEqual(voiceModelShortLabel(nil), "Auto")
        XCTAssertEqual(voiceModelShortLabel(""), "Auto")
    }

    func testShortLabelKeepsOnlyTheReadableTailOfAnID() {
        XCTAssertEqual(voiceModelShortLabel("claude-opus-4.7"), "claude-opus-4.7")
        XCTAssertEqual(voiceModelShortLabel("anthropic/claude-opus-4.7"), "claude-opus-4.7")
        XCTAssertEqual(voiceModelShortLabel("ollama/library/llama3:8b"), "8b")
        // A trailing separator has no tail to take — keep what we have.
        XCTAssertEqual(voiceModelShortLabel("anthropic/"), "anthropic/")
    }

    // MARK: - Turn fields (_voiceModelFields)

    func testNoSelectionSendsNoModelFieldsAtAll() {
        let selection = ModelSelection(store: MemoryKeyValueStore())
        XCTAssertTrue(voiceTurnModelFields(selection).isEmpty,
                      "an empty pick must leave the server's fast lane alone")
    }

    func testASelectionTravelsAsModelAndModelProvider() {
        let selection = ModelSelection(store: MemoryKeyValueStore())
        selection.set(.voice, model: "openai/gpt-5.2", provider: "openai")
        let fields = voiceTurnModelFields(selection)
        XCTAssertEqual(fields["model"] as? String, "openai/gpt-5.2")
        XCTAssertEqual(fields["model_provider"] as? String, "openai")
    }

    /// Voice and chat keep separate picks — that is the whole point of the
    /// per-surface keys.
    func testTheChatPickNeverLeaksIntoAVoiceTurn() {
        let selection = ModelSelection(store: MemoryKeyValueStore())
        selection.set(.chat, model: "anthropic/claude-opus-4.7", provider: "anthropic")
        XCTAssertTrue(voiceTurnModelFields(selection).isEmpty)
    }

    // MARK: - The store

    func testSelectingAModelPersistsUnderTheFlutterKeys() {
        let store = MemoryKeyValueStore()
        let models = makeStore(keyValueStore: store)
        models.select(ChatModel(id: "openai/gpt-5.2", label: "GPT-5.2", provider: "OpenAI"))

        XCTAssertEqual(models.selectedModelID, "openai/gpt-5.2")
        XCTAssertEqual(store.string("sel_voice_model"), "openai/gpt-5.2")
        XCTAssertEqual(store.string("sel_voice_provider"), "OpenAI")
        XCTAssertEqual(store.string("sel_chat_model"), nil, "chat must not move")
    }

    /// The Voice half of the same bug: `model_provider` on every turn has to be
    /// the canonical routing id, not the section heading the picker draws.
    func testSelectingAModelPersistsTheCanonicalProviderIDForTheTurnBody() {
        let store = MemoryKeyValueStore()
        let models = makeStore(keyValueStore: store)
        models.select(ChatModel(id: "box/llama", label: "Llama",
                                provider: "My Box", providerID: "custom:box"))

        XCTAssertEqual(models.selectedProviderID, "custom:box")
        XCTAssertEqual(store.string("sel_voice_provider"), "custom:box")

        let fields = voiceTurnModelFields(ModelSelection(store: store))
        XCTAssertEqual(fields["model"] as? String, "box/llama")
        XCTAssertEqual(fields["model_provider"] as? String, "custom:box",
                       "the display name would not route")
    }

    /// End to end through the real catalogue: load `/api/models`, pick the entry
    /// the picker would show, and read the turn body back.
    func testACatalogueModelSendsItsProviderIDInTheTurnFields() async {
        let store = MemoryKeyValueStore()
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/models", json: ["groups": [
            ["provider": "Anthropic", "provider_id": "anthropic",
             "models": [["id": "anthropic/claude-opus-4.7", "label": "Claude Opus 4.7"]]],
        ]])
        let models = VoiceModelStore(api: api, selection: ModelSelection(store: store))
        await models.load()

        let opus = models.catalog?.models.first
        XCTAssertEqual(opus?.provider, "Anthropic", "the section heading stays human")
        models.select(opus)

        let fields = voiceTurnModelFields(ModelSelection(store: store))
        XCTAssertEqual(fields["model_provider"] as? String, "anthropic")
    }

    func testAutoClearsTheOverride() {
        let store = MemoryKeyValueStore()
        let models = makeStore(keyValueStore: store)
        models.select(ChatModel(id: "openai/gpt-5.2", provider: "OpenAI"))
        models.select(nil)

        XCTAssertNil(models.selectedModelID)
        XCTAssertNil(store.string("sel_voice_model"))
        XCTAssertNil(store.string("sel_voice_provider"))
        XCTAssertTrue(voiceTurnModelFields(ModelSelection(store: store)).isEmpty)
    }

    func testAPersistedPickIsReadBackOnLaunch() {
        let store = MemoryKeyValueStore(["sel_voice_model": "anthropic/claude-opus-4.7",
                                         "sel_voice_provider": "anthropic"])
        let models = makeStore(keyValueStore: store)
        XCTAssertEqual(models.selectedModelID, "anthropic/claude-opus-4.7")
        XCTAssertEqual(models.selectedProviderID, "anthropic")
        // With no catalogue yet the chip still has to say something useful.
        XCTAssertEqual(models.chipLabel, "claude-opus-4.7")
    }

    func testTheChipShowsAutoUntilSomethingIsPicked() {
        XCTAssertEqual(makeStore().chipLabel, "Auto")
    }

    func testLoadingTheCatalogueUpgradesTheChipToTheHumanLabel() async {
        let store = MemoryKeyValueStore(["sel_voice_model": "openai/gpt-5.2"])
        let models = makeStore(keyValueStore: store)
        XCTAssertEqual(models.chipLabel, "gpt-5.2")

        await models.load()
        XCTAssertEqual(models.catalog?.models.count, 3)
        XCTAssertEqual(models.chipLabel, "GPT-5.2")
    }

    func testAFailedCatalogueLoadSurfacesAMessageAndCanBeRetried() async {
        let (api, transport) = JarvisAPI.mocked()
        // FIFO, not `route`: the same path has to answer differently twice.
        transport.enqueue(json: ["error": "boom"], status: 500)
        let models = VoiceModelStore(api: api, selection: ModelSelection(store: MemoryKeyValueStore()))

        await models.load()
        XCTAssertNil(models.catalog)
        let failure = models.loadError
        XCTAssertNotNil(failure)
        XCTAssertFalse(failure?.isEmpty ?? true)

        // The retry re-runs even though a previous attempt already finished.
        transport.enqueue(json: ["groups": [
            ["provider": "Anthropic", "models": [["id": "a/b", "label": "B"]]],
        ]])
        await models.load(force: true)
        XCTAssertEqual(models.catalog?.models.count, 1)
        XCTAssertNil(models.loadError)
    }

    // MARK: - Helpers

    private func makeStore(keyValueStore: MemoryKeyValueStore = MemoryKeyValueStore())
        -> VoiceModelStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/models", json: [
            "default_model": "anthropic/claude-haiku-4.5",
            "groups": [
                ["provider": "Anthropic", "models": [
                    ["id": "anthropic/claude-opus-4.7", "label": "Claude Opus 4.7"],
                    ["id": "anthropic/claude-haiku-4.5", "label": "Claude Haiku 4.5"],
                ]],
                ["provider": "OpenAI", "models": [["id": "openai/gpt-5.2", "label": "GPT-5.2"]]],
            ],
        ])
        return VoiceModelStore(api: api, selection: ModelSelection(store: keyValueStore))
    }
}
