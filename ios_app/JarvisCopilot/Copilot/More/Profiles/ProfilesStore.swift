import Foundation
import Observation

/// Page state for the Profiles screen: list + active profile, switch (verified
/// against the server's answer), create, delete.
@Observable
@MainActor
final class ProfilesStore {
    private let api: ProfilesAPI
    private let task = TaskHandle()

    private(set) var profiles: [Profile] = []
    private(set) var active = ""
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var toast: String?

    init(api: ProfilesAPI = ProfilesAPI()) { self.api = api }

    deinit { task.cancel() }

    var isEmpty: Bool { hasLoaded && profiles.isEmpty }
    func isActive(_ profile: Profile) -> Bool { profile.name == active }
    func canDelete(_ profile: Profile) -> Bool { profile.canDelete(activeName: active) }
    /// Names offered by the create sheet's "Clone from" picker.
    var cloneCandidates: [String] { profiles.map(\.name).filter { !$0.isEmpty } }

    func load() {
        isLoading = true
        errorMessage = nil
        task.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        do {
            let result = try await api.list()
            profiles = result.profiles
            active = result.active
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    /// Switch profiles. The server reports the new active profile via `active`;
    /// if it does NOT confirm, say so honestly rather than faking success.
    func switchTo(_ name: String) async {
        do {
            let response = try await api.switchTo(name)
            let confirmed = activeProfileName(response) == name
            await refresh()
            toast = confirmed
                ? "Switched to \"\(name)\"."
                : "Switch to \"\(name)\" may not have applied."
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    func delete(_ name: String) async {
        do {
            try await api.delete(name)
            await refresh()
            toast = "Deleted \"\(name)\"."
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    /// Create a profile. Blank optional fields are omitted entirely so the
    /// server keeps its own defaults.
    @discardableResult
    func create(name: String, cloneFrom: String?, baseURL: String, apiKey: String,
                defaultModel: String, modelProvider: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast = "Name is required."
            return false
        }
        var body: JSONObject = ["name": trimmed]
        if let cloneFrom, !cloneFrom.isEmpty {
            body["clone_from"] = cloneFrom
            body["clone_config"] = true
        }
        for (key, value) in [("base_url", baseURL), ("api_key", apiKey),
                             ("default_model", defaultModel), ("model_provider", modelProvider)] {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { body[key] = v }
        }
        do {
            try await api.create(body)
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    /// The active personality prompt, for the on-device model. Best-effort.
    func activePersonality() async -> String {
        (try? await api.activePersonality()) ?? ""
    }
}
