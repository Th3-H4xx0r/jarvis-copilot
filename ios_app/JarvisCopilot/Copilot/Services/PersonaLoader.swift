import Foundation

/// The server's active personality, applied to the on-device model at startup.
///
/// Behind a protocol so `AppServicesTests` can assert that startup asks for it
/// without a network.
@MainActor
protocol PersonaLoading: AnyObject {
    func loadPersona() async
}

/// `GET /api/personality/active` → `OnDeviceAI.setPersona`.
///
/// Port of the `on_device_ai.setPersona(...)` call `main.dart` made after
/// bootstrapping: the local model has no idea who JARVIS is, so without this a
/// locally answered turn sounds like a different assistant mid-conversation.
///
/// Best-effort by design — an unpaired app, an older server or being offline all
/// just leave the built-in persona in place, and the next launch tries again.
@MainActor
final class DefaultPersonaLoader: PersonaLoading {

    private let profiles: ProfilesAPI
    private let apply: @MainActor (String) -> Void

    /// `apply` is `nil`-defaulted rather than defaulted to `OnDeviceAI.shared`:
    /// a default argument expression is evaluated in a NONISOLATED context.
    init(profiles: ProfilesAPI = ProfilesAPI(), apply: (@MainActor (String) -> Void)? = nil) {
        self.profiles = profiles
        self.apply = apply ?? { OnDeviceAI.shared.setPersona($0) }
    }

    func loadPersona() async {
        guard let prompt = try? await profiles.activePersonality() else { return }
        // An empty prompt means "no personality configured" — overwriting the
        // built-in one with "" would make local replies voiceless.
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        apply(prompt)
    }
}
