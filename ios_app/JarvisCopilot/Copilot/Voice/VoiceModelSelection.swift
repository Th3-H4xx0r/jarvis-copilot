import Foundation
import Observation

/// Which SERVER LLM the voice turns run on, and the small protocols the Voice
/// screen uses to reach optional parts of ``VoiceStore``.
///
/// Flutter keeps this in `services/model_selection.dart` + `_voiceModelFields()`
/// in `voice/voice_controller.dart`: the voice surface has its OWN model choice
/// (`sel_voice_model` / `sel_voice_provider`), independent of chat, and every
/// turn body carries `model` / `model_provider` when one is set. A nil choice
/// means "Auto" — the server's configured fast lane decides.
///
/// This file is owned by the Voice **UI**; the store itself is not edited here.
/// The two helpers the TRANSPORT needs — ``voiceTurnModelFields(_:)`` and
/// ``voiceModelShortLabel(_:)`` — live next door in `VoiceModelFields.swift`,
/// which is why the Mac voice client can build the turn machine without
/// building this picker.

// MARK: - Catalogue + selection

/// The voice surface's model picker state: the `/api/models` catalogue plus the
/// persisted choice. Mirrors `ChatStore`'s model half, scoped to `.voice`.
@Observable @MainActor
final class VoiceModelStore {
    /// The app-wide instance the Voice tab uses. A picker opened twice must not
    /// re-fetch the catalogue or disagree with itself about the selection.
    static let shared = VoiceModelStore()

    private(set) var catalog: ModelCatalog?
    private(set) var loading = false
    private(set) var loadError: String?

    private(set) var selectedModelID: String?
    private(set) var selectedProviderID: String?

    @ObservationIgnored private let models: ModelsAPI
    @ObservationIgnored private let selection: ModelSelection

    /// Dependencies are `nil`-defaulted and built in the body: a default argument
    /// is evaluated in a nonisolated context, which `@MainActor` values can't be.
    init(api: JarvisAPI = .shared, selection: ModelSelection? = nil) {
        let selection = selection ?? .shared
        self.models = ModelsAPI(api: api)
        self.selection = selection
        self.selectedModelID = selection.model(for: .voice)
        self.selectedProviderID = selection.provider(for: .voice)
    }

    /// The catalogue entry behind the current choice, when the catalogue is loaded.
    var selectedModel: ChatModel? { catalog?.models.first { $0.id == selectedModelID } }

    /// What the toolbar chip shows: the model's human label if we have the
    /// catalogue, else a readable tail of the id, else "Auto".
    var chipLabel: String {
        if let selectedModel { return selectedModel.label }
        return voiceModelShortLabel(selectedModelID)
    }

    func load(force: Bool = false) async {
        guard force || (catalog == nil && !loading) else { return }
        loading = true
        loadError = nil
        do {
            catalog = try await models.list()
        } catch {
            loadError = apiErrorMessage(error)
        }
        loading = false
    }

    /// Persist a pick. `nil` clears the override ("Auto"), so the server's fast
    /// lane decides — exactly what `_pickAuto` does in Flutter.
    ///
    /// What is stored (and so what ``voiceTurnModelFields(_:)`` sends as
    /// `model_provider`) is the CANONICAL `providerID`, not the display name the
    /// picker's section heading shows: the server routes on the id, and the name
    /// made every turn fall back to the server's own default model.
    func select(_ model: ChatModel?) {
        selectedModelID = model?.id
        selectedProviderID = model.flatMap { $0.providerID.isEmpty ? nil : $0.providerID }
        selection.set(.voice, model: selectedModelID, provider: selectedProviderID)
    }
}

// MARK: - Optional store capabilities
