import Foundation

/// REST wrapper for the Photon (hosted iMessage) integration config
/// (`/api/integrations/photon`).
///
/// Two SECRET fields — `project_secret` and `sidecar_token` — are write-only:
/// the GET never returns their values, only `*_set` booleans. On save we OMIT a
/// secret key entirely when the user left the field blank, so a blank field
/// preserves the stored secret server-side (sending "" would wipe it).
struct PhotonAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func config() async throws -> PhotonConfig {
        PhotonConfig(json: try await api.get("/api/integrations/photon").object())
    }

    /// Pass a secret only when the user typed one; nil keeps the stored value.
    ///
    /// `allowAll` is a non-secret bool with no "omit to preserve" semantics, so
    /// it is always sent. The POST also reloads the gateway, so the full
    /// response is parsed back — the page refreshes its status pill from the
    /// post-reload `sidecar` without leaving.
    func save(projectID: String? = nil,
              projectSecret: String? = nil,
              notifyTarget: String? = nil,
              sidecarURL: String? = nil,
              sidecarToken: String? = nil,
              allowedUsers: String? = nil,
              allowAll: Bool) async throws -> PhotonConfig {
        var body: JSONObject = ["allow_all": allowAll]
        if let projectID { body["project_id"] = projectID }
        if let projectSecret { body["project_secret"] = projectSecret }
        if let notifyTarget { body["notify_target"] = notifyTarget }
        if let sidecarURL { body["sidecar_url"] = sidecarURL }
        if let sidecarToken { body["sidecar_token"] = sidecarToken }
        if let allowedUsers { body["allowed_users"] = allowedUsers }
        let response = try await api.post("/api/integrations/photon", json: body)
        return PhotonConfig(json: try response.object())
    }
}
