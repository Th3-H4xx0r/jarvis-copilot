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
/// See ``voiceTurnModelFields(_:)`` for what the transport must merge into the
/// realtime hello and the quality-turn body.

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

/// The `model` / `model_provider` fields every voice turn carries. Port of
/// `_voiceModelFields()` — omitted entirely when nothing is selected, so the
/// server keeps using its own fast lane.
///
/// `model_provider` is the catalogue's canonical `provider_id` (see
/// ``VoiceModelStore/select(_:)``); the display name the picker groups under
/// does not route.
///
/// The transport should merge this into the realtime hello and the
/// `/api/voice/quality-turn` body.
func voiceTurnModelFields(_ selection: ModelSelection = .shared) -> [String: Any] {
    var fields: [String: Any] = [:]
    if let model = selection.model(for: .voice), !model.isEmpty { fields["model"] = model }
    if let provider = selection.provider(for: .voice), !provider.isEmpty {
        fields["model_provider"] = provider
    }
    return fields
}

/// A readable short name for a model id ("anthropic/claude-opus-4.7" →
/// "claude-opus-4.7"). Port of `_ModelChipState._label()`.
func voiceModelShortLabel(_ model: String?) -> String {
    guard let model, !model.isEmpty else { return "Auto" }
    var out = model
    if let slash = out.lastIndex(of: "/"), out.index(after: slash) < out.endIndex {
        out = String(out[out.index(after: slash)...])
    }
    if let colon = out.lastIndex(of: ":"), out.index(after: colon) < out.endIndex {
        out = String(out[out.index(after: colon)...])
    }
    return out
}

// MARK: - Optional store capabilities

/// The rolling debug log the Voice screen shows behind a long-press. Named here
/// rather than reached for directly so the screen states what it needs from the
/// store; ``VoiceStore`` adopts it in `VoiceDiagnostics.swift`.
@MainActor
protocol VoiceDiagnosticsProviding: AnyObject {
    var diagnostics: [String] { get }
}

/// "Try on server" — offered after an ON-DEVICE voice answer, to re-run that turn
/// against the server (which can give a better one). Port of `canRetryOnServer` /
/// `retryLastOnServer` in `voice_controller.dart`.
@MainActor
protocol VoiceServerRetrying: AnyObject {
    var canRetryOnServer: Bool { get }
    func retryLastOnServer()
}
