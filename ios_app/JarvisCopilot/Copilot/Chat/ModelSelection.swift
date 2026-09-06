import Foundation

/// Per-surface choice of the SERVER model/provider. Chat and voice each keep their
/// own selection, so you can run a fast model for voice and a stronger one for
/// chat. Ported from `services/model_selection.dart`.
///
/// `VoiceSurface` (chat | voice) is the shared enum from `Copilot/Skills` — the
/// same name Flutter uses, and what the voice surface already keys off.
///
/// A nil value for either field means "no explicit override" — the caller then
/// falls back to the server's active/default model.
///
/// Keys (unchanged from the Flutter app, so a migrated install keeps its choice):
///   - `sel_chat_model`  / `sel_chat_provider`
///   - `sel_voice_model` / `sel_voice_provider`
struct ModelSelection: Sendable {
    /// Preferences, not credentials: the model id is not a secret, and reading it
    /// synchronously means the composer never renders a stale "Default".
    let store: KeyValueStore

    static let shared = ModelSelection(store: UserDefaults.standard)

    init(store: KeyValueStore = UserDefaults.standard) { self.store = store }

    func model(for surface: VoiceSurface) -> String? { read(Self.modelKey(surface)) }
    func provider(for surface: VoiceSurface) -> String? { read(Self.providerKey(surface)) }

    /// Persist a new selection for `surface`. A nil (or empty) argument clears that
    /// field. Model and provider always travel as a pair from the picker.
    func set(_ surface: VoiceSurface, model: String?, provider: String?) {
        write(Self.modelKey(surface), model)
        write(Self.providerKey(surface), provider)
    }

    /// Clear every persisted selection (e.g. on un-pair).
    func clear() {
        set(.chat, model: nil, provider: nil)
        set(.voice, model: nil, provider: nil)
    }

    private func read(_ key: String) -> String? {
        guard let value = store.string(key), !value.isEmpty else { return nil }
        return value
    }

    private func write(_ key: String, _ value: String?) {
        store.set((value?.isEmpty == false) ? value : nil, forKey: key)
    }

    private static func modelKey(_ surface: VoiceSurface) -> String { "sel_\(surface.rawValue)_model" }
    private static func providerKey(_ surface: VoiceSurface) -> String { "sel_\(surface.rawValue)_provider" }
}
