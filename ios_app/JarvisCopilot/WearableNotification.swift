import Foundation

struct WearableNotification: Equatable {
    let channel: String
    let title: String
    let body: String
    let app: String?

    /// APNs wraps the custom fields; older/direct callers used a flat dictionary.
    static func decode(_ info: [AnyHashable: Any]) -> Self? {
        let payload = info["jarviscopilot"] as? [AnyHashable: Any] ?? info
        let channel: String
        let title: String
        let body: String
        switch payload["type"] as? String {
        case "device_notify":
            guard let value = payload["channel"] as? String, !value.isEmpty else { return nil }
            channel = value
            title = payload["notify_title"] as? String ?? ""
            body = payload["notify_body"] as? String ?? ""
        case "glasses_notify":
            channel = "glasses"
            title = payload["glasses_title"] as? String ?? ""
            body = payload["glasses_body"] as? String ?? ""
        default:
            // Another push (Code Master's Allow / Deny or Finished banner)
            // carrying a card for a wearable as well.
            guard let value = payload["notify_channel"] as? String, !value.isEmpty else { return nil }
            channel = value
            title = payload["notify_title"] as? String ?? ""
            body = payload["notify_body"] as? String ?? ""
        }
        guard !title.isEmpty || !body.isEmpty else { return nil }
        let app = payload["notify_app"] as? String
        return Self(channel: channel, title: title, body: body, app: app?.isEmpty == false ? app : nil)
    }

    /// The board truncates both strings to fit a BLE frame, on UTF-8 boundaries.
    static func matchesRelay(title: String, body: String, relayTitle: String, relayBody: String) -> Bool {
        guard !relayTitle.isEmpty || !relayBody.isEmpty else { return false }
        return title.hasPrefix(relayTitle) && body.hasPrefix(relayBody)
    }
}
