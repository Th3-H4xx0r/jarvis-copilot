import Foundation

/// Human title for the LOCAL notification posted when a foreground-required
/// action is deferred (app backgrounded). Mirrors the server's
/// `format_action_banner` so the banner reads the same whoever posts it.
///
/// Port of `mobile_client/lib/skills/action_banner.dart`.
func actionBannerTitle(_ skill: String, _ args: [String: Any]) -> String {
    func s(_ key: String) -> String { SkillArgs.string(args, key) }

    func pct(_ value: Any?) -> String {
        guard let n = SkillArgs.number(["v": value ?? NSNull()], "v")
                ?? Double(SkillArgs.text(value)) else { return "" }
        let d = n <= 1 ? n * 100 : n
        return "\(Int(d.rounded()))%"
    }

    func truthy(_ value: Any?) -> Bool {
        ["1", "on", "true", "yes"].contains(
            SkillArgs.text(value).lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A banner is the ONLY thing the user sees before tapping runs the action,
    /// so an outward-facing one has to name who it reaches and roughly what it
    /// says. Kept short — the whole title is capped at 100 characters.
    func snippet(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    func hostOrURL(_ url: String) -> String {
        if let parsed = URL(string: url), let h = parsed.host, !h.isEmpty { return h }
        return url
    }

    /// "Text Mom: on my way" / "Text Mom" when there is no body yet.
    func textTitle(_ to: String, _ body: String) -> String {
        let who = to.isEmpty ? "someone" : snippet(to, 30)
        let what = snippet(body, 48)
        return what.isEmpty ? "Text \(who)" : "Text \(who): \(what)"
    }

    var title: String
    switch skill {
    case "open_url":
        title = "Open \(hostOrURL(s("url")))"
    case "open_app":
        let name = !s("app").isEmpty ? s("app") : (!s("name").isEmpty ? s("name") : "app")
        title = "Open \(name)"
    case "run_shortcut":
        title = "Run \(s("name").isEmpty ? "shortcut" : s("name"))"
    case "create_shortcut":
        title = "Add a Shortcut"
    case "send_sms":
        title = textTitle(s("number"), s("message"))
    case "make_call":
        let number = s("number")
        title = number.isEmpty ? "Place a call" : "Call \(snippet(number, 40))"
    case "share_text":
        let body = s("subject").isEmpty ? s("text") : s("subject")
        title = body.isEmpty ? "Share text" : "Share: \(snippet(body, 60))"
    case "share_image":
        let caption = s("caption")
        title = caption.isEmpty ? "Share an image" : "Share image: \(snippet(caption, 50))"
    case "take_photo":
        title = "Take a photo"
    case "pick_photo":
        title = "Pick a photo"
    case "phone_control":
        let action = s("action")
        let value = args["value"]
        if action == "brightness" || action == "volume" {
            let p = pct(value)
            title = p.isEmpty ? "Set \(action)" : "Set \(action) \(p)"
        } else if action == "wifi" || action == "bluetooth" || action == "focus" {
            let names = ["wifi": "Wi-Fi", "bluetooth": "Bluetooth", "focus": "Focus"]
            title = "Turn \(truthy(value) ? "on" : "off") \(names[action] ?? action)"
        } else if action == "send_message" {
            title = textTitle(SkillArgs.text(args["to"] ?? args["recipient"]),
                              SkillArgs.text(args["message"] ?? args["body"] ?? args["value"]))
        } else if action == "open_url" {
            title = "Open \(hostOrURL(s("url")))"
        } else {
            title = "Phone control"
        }
    default:
        title = "JARVIS action ready"
    }
    return title.count > 100 ? String(title.prefix(100)) : title
}
