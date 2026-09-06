import Foundation

/// Talks to the WebUI profile endpoints — the same set the web Profiles panel
/// uses. There is NO profile-edit endpoint, so this exposes only
/// list / active / switch / create / delete.
///
///     GET  /api/profiles       → {profiles: [{name, path, model, provider, …}], active}
///     GET  /api/profile/active → {name, path}
///     POST /api/profile/switch → {profiles, active, default_model, …}
///     POST /api/profile/create → {ok, profile}
///     POST /api/profile/delete → { … }
struct ProfilesAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// Every profile plus the active name, in one call.
    func list() async throws -> (profiles: [Profile], active: String) {
        let body = try await api.get("/api/profiles").object()
        return (parseProfiles(body), activeProfileName(body))
    }

    /// The raw list body, for callers that need the extra keys.
    func listRaw() async throws -> JSONObject {
        try await api.get("/api/profiles").object()
    }

    /// The currently active profile: `{name, path}`.
    func active() async throws -> JSONObject {
        try await api.get("/api/profile/active").object()
    }

    /// Switch the active profile. The server reports the new active profile via
    /// its `active` key — callers must VERIFY it matches rather than assuming
    /// success, which is why the raw body comes back.
    func switchTo(_ name: String) async throws -> JSONObject {
        try await api.post("/api/profile/switch", json: ["name": name]).object()
    }

    /// `body` may carry: name (required), clone_from, clone_config (bool),
    /// base_url, api_key, default_model, model_provider. Only non-empty keys
    /// should be passed.
    func create(_ body: JSONObject) async throws {
        _ = try await api.post("/api/profile/create", json: body)
    }

    func delete(_ name: String) async throws {
        _ = try await api.post("/api/profile/delete", json: ["name": name])
    }

    /// `GET /api/personality/active` → the active JARVIS system prompt, so
    /// on-device models can speak in the same voice. "" when none is configured.
    func activePersonality() async throws -> String {
        let body = try await api.get("/api/personality/active").object()
        return MoreJSON.text(body["prompt"])
    }
}
