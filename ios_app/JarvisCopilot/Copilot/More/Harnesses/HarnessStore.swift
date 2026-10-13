import Foundation
import Observation

/// The harnesses the server knows (built-ins + yours), the one default and the
/// Voice/Chat overrides, shared by the harness chips, the Harnesses page,
/// Settings → Default and the turn senders (chat/start and voice begin_turn
/// carry `harness_id`).
///
/// The default is a harness, or "single" (Single answers with `model.default`).
/// Voice and Chat follow it unless they have a pick of their own; "" means
/// "same as default". Everything else (Telegram/iMessage, schedules) always
/// runs the default.
@Observable
@MainActor
final class HarnessStore {
    static let shared = HarnessStore()

    /// A fresh server: chat on the default model, voice on the fast harness.
    static let defaultOverrides = ["voice": "fast-claude", "chat": ""]

    private let api: HarnessAPI
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let voiceModels: VoiceModelStore
    var harnesses: [AgentHarness] = []
    /// The one default harness ("single" = the default model).
    private(set) var defaultID = "single"
    /// Voice/Chat's own picks; "" = same as the default.
    private(set) var overrides: [String: String] = HarnessStore.defaultOverrides
    private(set) var isLoading = false
    var errorMessage: String?

    /// Dependencies are `nil`-defaulted and built in the body: a default argument
    /// is evaluated in a nonisolated context, which `@MainActor` values can't be.
    init(api: HarnessAPI = HarnessAPI(), defaults: UserDefaults = .standard,
         voiceModels: VoiceModelStore? = nil) {
        self.api = api
        self.defaults = defaults
        self.voiceModels = voiceModels ?? .shared
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            apply(try await api.snapshot())
            errorMessage = nil
        } catch {
            if !wasCancelled(error) { errorMessage = error.localizedDescription }
        }
    }

    func apply(_ snapshot: HarnessSnapshot) {
        harnesses = snapshot.harnesses
        applyAssignments(snapshot.assignments, overrides: snapshot.overrides)
    }

    /// Takes a snapshot's or an assign reply's assignments. A server from before
    /// the one default sends no `default`/`overrides`: its Chat harness is then
    /// the default and Voice its only override (exactly what it ran).
    func applyAssignments(_ assignments: [String: String], overrides: [String: String]?) {
        func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
        defaultID = nonEmpty(assignments["default"]) ?? nonEmpty(assignments["chat"]) ?? "single"
        if let overrides {
            self.overrides = ["voice": overrides["voice"] ?? "", "chat": overrides["chat"] ?? ""]
        } else {
            self.overrides = ["voice": assignments["voice"] ?? Self.defaultOverrides["voice"] ?? "", "chat": ""]
        }
        persistVoiceChoice()
    }

    func harness(_ id: String) -> AgentHarness? { harnesses.first { $0.id == id } }

    /// Before the list loads every id is taken at its word.
    private func exists(_ id: String) -> Bool { harnesses.isEmpty || harness(id) != nil }

    /// The harness a surface runs: its override (when it names a harness that
    /// exists), else the default (when it exists), else Single — the server's rule.
    func effective(_ surface: String) -> String {
        if let own = overrides[surface], !own.isEmpty, exists(own) { return own }
        return !defaultID.isEmpty && exists(defaultID) ? defaultID : "single"
    }

    /// Effective ids per surface.
    var assignments: [String: String] {
        ["default": effective("default"), "voice": effective("voice"), "chat": effective("chat")]
    }

    /// The harness a turn on this surface runs: the chat's own, else the surface's.
    func current(for surface: VoiceSurface, sessionHarnessID: String?) -> String {
        if surface == .chat, let id = sessionHarnessID, !id.isEmpty { return id }
        return effective(surface.rawValue)
    }

    func title(for id: String) -> String { harness(id)?.title ?? id }

    /// The row that clears a Voice/Chat override, naming what it follows.
    var sameAsDefaultTitle: String { "Same as default (\(title(for: effective("default"))))" }

    /// What a chip names: the model when the surface runs "Single model", else the harness.
    func label(for surface: VoiceSurface, sessionHarnessID: String?, singleModelLabel: String) -> String {
        let id = current(for: surface, sessionHarnessID: sessionHarnessID)
        return id == "single" ? singleModelLabel : title(for: id)
    }

    /// Chat: the chat's own harness. Voice: Voice's own pick ("" = the default).
    func select(_ id: String, surface: VoiceSurface, sessionID: String?) async {
        if surface == .chat, let sessionID {
            do {
                try await api.setSessionHarness(sessionID: sessionID, id: id)
                errorMessage = nil
            } catch {
                if !wasCancelled(error) { errorMessage = error.localizedDescription }
            }
        } else {
            await assign(id, to: surface.rawValue)
        }
    }

    func assign(_ id: String, to surface: VoiceSurface) async {
        await assign(id, to: surface.rawValue)
    }

    /// `surface` is "default", "voice" or "chat"; "" clears a Voice/Chat override.
    func assign(_ id: String, to surface: String) async {
        do {
            let reply = try await api.assign(surface: surface, id: id)
            applyAssignments(reply.assignments, overrides: reply.overrides)
            errorMessage = nil
        } catch {
            if !wasCancelled(error) { errorMessage = error.localizedDescription }
        }
    }

    /// A MODEL as the default: the model first, and Single becomes the default
    /// only once the server took it — a refusal changes nothing.
    func setDefaultModel(_ ref: String) async -> Bool {
        guard await setSingleModel(ref) else { return false }
        await assign("single", to: "default")
        return errorMessage == nil
    }

    /// The model Single answers with and every fallback runs; the default
    /// harness stays as it is.
    func setSingleModel(_ ref: String) async -> Bool {
        do {
            try await api.setDefaultModel(ref)
            errorMessage = nil
            return true
        } catch {
            if !wasCancelled(error) { errorMessage = apiErrorLine(error) }
            return false
        }
    }

    /// The voice transport (shared with the Mac client) reads the Voice harness
    /// from UserDefaults rather than this store. It carries Voice's OWN pick
    /// only: with none, the turn names no harness and the server resolves the
    /// default when it runs, so a default changed elsewhere is never stale here.
    ///
    /// A voice model with no harness is an explicit pick that the server runs as
    /// Single, so following the default leaves no voice model behind either.
    private func persistVoiceChoice() {
        let own = overrides["voice"] ?? ""
        if own.isEmpty {
            defaults.removeObject(forKey: voiceHarnessDefaultsKey)
            // Unconditionally: the store's in-memory pick is read once, at init.
            voiceModels.select(nil)
        } else {
            defaults.set(own, forKey: voiceHarnessDefaultsKey)
        }
    }

    /// Saves and refreshes; returns the server's problems when it rejects the design.
    func save(_ harness: AgentHarness) async -> [HarnessProblem] {
        do {
            switch try await api.save(harness) {
            case .success:
                await refresh()
                return []
            case .failure(let rejection):
                return rejection.problems
            }
        } catch {
            if !wasCancelled(error) { errorMessage = error.localizedDescription }
            return [HarnessProblem(node: nil, edge: nil, message: error.localizedDescription)]
        }
    }

    func delete(_ id: String) async {
        do {
            try await api.delete(id: id)
            await refresh()
        } catch {
            if !wasCancelled(error) { errorMessage = error.localizedDescription }
        }
    }
}
