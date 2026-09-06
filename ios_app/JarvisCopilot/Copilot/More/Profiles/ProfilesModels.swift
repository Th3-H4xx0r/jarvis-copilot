import Foundation

/// One profile from `GET /api/profiles`. There is no profile-EDIT endpoint on
/// the server, so this is read-only apart from switch / create / delete.
struct Profile: Identifiable, Equatable, Sendable {
    var name: String
    var path: String
    var model: String
    var provider: String
    var isDefaultFlag: Bool
    var gatewayRunning: Bool

    var id: String { name }

    init(name: String, path: String = "", model: String = "", provider: String = "",
         isDefaultFlag: Bool = false, gatewayRunning: Bool = false) {
        self.name = name
        self.path = path
        self.model = model
        self.provider = provider
        self.isDefaultFlag = isDefaultFlag
        self.gatewayRunning = gatewayRunning
    }

    init(json: JSONObject) {
        name = MoreJSON.text(json["name"])
        path = MoreJSON.text(json["path"])
        model = MoreJSON.text(json["model"] ?? json["default_model"])
        provider = MoreJSON.text(json["provider"] ?? json["model_provider"])
        isDefaultFlag = MoreJSON.isTrue(json["is_default"])
        gatewayRunning = MoreJSON.isTrue(json["gateway_running"])
    }

    /// The default profile is either flagged or literally named "default".
    var isDefault: Bool { isDefaultFlag || name == "default" }

    /// Only a non-default, non-active profile can be deleted.
    func canDelete(activeName: String) -> Bool { !isDefault && name != activeName }

    var gatewayLabel: String { gatewayRunning ? "GATEWAY RUNNING" : "GATEWAY IDLE" }
    var gatewayTone: MoreTone { gatewayRunning ? .primaryBlue : .muted }
}

/// Parse `{profiles: [...], active: …}` (or a bare list, defensively) into a
/// clean list. Nulls, a non-list `profiles` and non-object entries are all
/// tolerated.
func parseProfiles(_ data: Any?) -> [Profile] {
    let raw = (data as? JSONObject)?["profiles"] ?? data
    guard let list = raw as? [Any] else { return [] }
    return list.compactMap { $0 as? JSONObject }.map(Profile.init(json:))
}

/// The active profile name out of a `{active: …}` map — or the `{name: …}` shape
/// that `/api/profile/active` returns. "" when absent/blank, so the UI can treat
/// "no active profile" uniformly.
func activeProfileName(_ data: Any?) -> String {
    guard let object = data as? JSONObject else { return "" }
    guard let value = object["active"] ?? object["name"], !(value is NSNull) else { return "" }
    return MoreJSON.text(value)
}
