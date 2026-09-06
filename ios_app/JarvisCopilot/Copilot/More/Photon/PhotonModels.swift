import Foundation

/// Health/connection status of the local Photon sidecar, as reported in the
/// `sidecar` object on both GET and POST. Absent fields default to false / "".
struct PhotonSidecar: Equatable, Sendable {
    var reachable = false
    var ok = false
    var mock = false
    var connected = false
    var error = ""

    init() {}

    init(json: JSONObject) {
        reachable = MoreJSON.isTrue(json["reachable"])
        ok = MoreJSON.isTrue(json["ok"])
        mock = MoreJSON.isTrue(json["mock"])
        connected = MoreJSON.isTrue(json["connected"])
        error = MoreJSON.text(json["error"])
    }
}

/// One entry in the server-described form (`fields[]`). `kind` is the newer
/// per-field type hint ("text" | "password" | "bool"); `secret` is kept for
/// back-compat and is true whenever `kind == "password"`.
struct PhotonField: Identifiable, Equatable, Sendable {
    var key: String
    var label: String
    var secret: Bool
    var required: Bool
    var kind: String

    var id: String { key }

    init(json: JSONObject) {
        let kind = MoreJSON.text(json["kind"])
        self.kind = kind.isEmpty ? "text" : kind
        key = MoreJSON.text(json["key"])
        label = MoreJSON.text(json["label"])
        secret = MoreJSON.isTrue(json["secret"]) || kind == "password"
        required = MoreJSON.isTrue(json["required"])
    }
}

/// The current Photon config as returned by the GET. Secret VALUES are never
/// present — only the `*Set` flags saying whether one is stored.
struct PhotonConfig: Equatable, Sendable {
    var fields: [PhotonField] = []
    var configured = false
    var projectID = ""
    var projectSecretSet = false
    var notifyTarget = ""
    var sidecarURL = ""
    var sidecarTokenSet = false
    var allowedUsers = ""
    var allowAll = false
    var sidecar = PhotonSidecar()

    init() {}

    init(json: JSONObject) {
        fields = MoreJSON.mapList(json["fields"]).map(PhotonField.init(json:))
        configured = MoreJSON.isTrue(json["configured"])
        projectID = MoreJSON.text(json["project_id"])
        projectSecretSet = MoreJSON.isTrue(json["project_secret_set"])
        notifyTarget = MoreJSON.text(json["notify_target"])
        sidecarURL = MoreJSON.text(json["sidecar_url"])
        sidecarTokenSet = MoreJSON.isTrue(json["sidecar_token_set"])
        allowedUsers = MoreJSON.text(json["allowed_users"])
        allowAll = MoreJSON.isTrue(json["allow_all"])
        sidecar = PhotonSidecar(json: MoreJSON.map(json["sidecar"]))
    }
}

/// Resolved status-pill content: a palette slot, a label and an SF Symbol.
struct PhotonStatus: Equatable, Sendable {
    var tone: MoreTone
    var label: String
    var iconName: String

    /// Ordering matters: an unconfigured install reads "Not configured" even if
    /// the sidecar happens to be up.
    static func resolve(configured: Bool, sidecar: PhotonSidecar) -> PhotonStatus {
        if !configured {
            return .init(tone: .muted, label: "Not configured", iconName: "minus.circle")
        }
        if !sidecar.reachable {
            return .init(tone: .amber, label: "Sidecar not reachable — is it running?",
                         iconName: "exclamationmark.circle")
        }
        if sidecar.ok && sidecar.mock {
            return .init(tone: .amber, label: "Sidecar in mock mode — tap Save to reload",
                         iconName: "flask")
        }
        if sidecar.ok {
            return .init(tone: .success, label: "Connected — iMessage live",
                         iconName: "checkmark.circle")
        }
        // Reachable but not ok — surface the sidecar error when we have one.
        return .init(tone: .danger,
                     label: sidecar.error.isEmpty ? "Sidecar error" : "Sidecar error: \(sidecar.error)",
                     iconName: "exclamationmark.circle")
    }
}
