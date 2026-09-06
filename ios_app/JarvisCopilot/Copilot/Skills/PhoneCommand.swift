import Foundation

/// The Shortcut a `phone_control` verb runs, plus the raw text handed to it.
struct PhoneShortcut: Equatable, Sendable {
    let name: String
    let input: String
}

/// Pure helpers for the `phone_control` per-verb Shortcut protocol. Kept free of
/// platform dependencies so they can be unit-tested without a device.
///
/// Architecture (see jarvis-copilot `docs/mobile/jarviscopilot-runner-shortcut.md`):
/// each iOS-locked setting maps to its OWN tiny "JC <Verb>" Shortcut that takes
/// the value as PLAIN TEXT input and runs one action. We deliberately do NOT use
/// a single JSON dispatcher: iOS `Get Dictionary from Input` won't reliably parse
/// a multi-key payload, and the `If` action won't reliably branch on a verb —
/// both were proven flaky on-device. Per-verb shortcuts use only bulletproof
/// primitives (text input → `Get Numbers from Input` → the action).
///
/// Port of `mobile_client/lib/skills/phone_command.dart`.
enum PhoneCommand {

    /// The verbs phone_control drives, each to a same-named "JC <Verb>"
    /// Shortcut. `verbOrder` keeps the user-facing listing stable (Swift
    /// dictionaries are unordered, Dart maps are insertion-ordered).
    static let verbOrder = ["brightness", "volume", "wifi", "bluetooth", "focus",
                            "open_url", "send_message"]

    static let verbShortcutNames: [String: String] = [
        "brightness": "JC Brightness",
        "volume": "JC Volume",
        "wifi": "JC WiFi",
        "bluetooth": "JC Bluetooth",
        "focus": "JC Focus",
        "open_url": "JC Open URL",
        // `send_message` deliberately has NO Shortcut. The "JC Send Message"
        // Shortcut sent an iMessage/SMS outright, with no composer and no
        // confirmation anywhere in the app — a server (or a mis-routed
        // on-device model) could text anyone in the address book silently.
        // `IOSSkills.phoneControl` now routes the verb through the same iOS
        // Messages composer `send_sms` uses, so the user still taps Send.
    ]

    /// Delimiter between recipient and body in the JC Send Message shortcut
    /// input. A pipe (URL-safe) — a newline inside the x-callback URL gets the
    /// whole `text` param dropped by iOS, so the shortcut received no input.
    /// Kept because `rawValue(for: "send_message", …)` still normalises the pair
    /// the same way; nothing hands it to a Shortcut any more.
    static let sendMessageDelimiter = "|"

    /// Skill args consumed by the Swift layer that must NOT be forwarded.
    private static let internalKeys: Set<String> = ["timeout_seconds"]

    /// Build the command map from skill args: `action` (required) plus any
    /// provided params, dropping nulls, empty strings, and internal-only keys.
    static func build(_ args: [String: Any]) throws -> [String: Any] {
        let action = SkillArgs.string(args, "action")
        if action.isEmpty { throw SkillError.badArgument("action required") }
        var out: [String: Any] = ["action": action]
        for (k, v) in args {
            if k == "action" || internalKeys.contains(k) { continue }
            if v is NSNull { continue }
            if let s = v as? String, s.isEmpty { continue }
            out[k] = v
        }
        return out
    }

    private static let truthyWords: Set<String> = ["1", "on", "true", "yes", "enable", "enabled"]
    private static let falsyWords: Set<String> = ["0", "off", "false", "no", "disable", "disabled"]

    /// Normalize a verb's value into the RAW TEXT the matching Shortcut expects.
    ///
    /// - wifi/bluetooth/focus → "1" / "0" (accepts on/off/true/false/yes/no).
    /// - brightness/volume    → an integer percent 0–100. iOS Shortcuts'
    ///   "Set Brightness"/"Set Volume" take a PERCENTAGE, so a 0.0–1.0 decimal
    ///   was read as ~0% (the "always 0" bug).
    /// - open_url             → the URL, passed through unchanged.
    static func rawValue(for action: String, command: [String: Any]) -> String {
        if action == "open_url" { return SkillArgs.string(command, "url") }
        if action == "send_message" {
            // Strip the delimiter from each field — the JC Send Message shortcut
            // splits the input on "|", so a "|" inside the recipient or body
            // would corrupt the split.
            let to = SkillArgs.text(command["to"] ?? command["recipient"])
                .replacingOccurrences(of: sendMessageDelimiter, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = SkillArgs.text(command["message"] ?? command["body"] ?? command["value"])
                .replacingOccurrences(of: sendMessageDelimiter, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(to)\(sendMessageDelimiter)\(msg)"
        }
        let value = command["value"]
        if action == "wifi" || action == "bluetooth" || action == "focus" {
            let s = SkillArgs.text(value).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if truthyWords.contains(s) { return "1" }
            if falsyWords.contains(s) { return "0" }
            return s
        }
        let raw = SkillArgs.text(value).trimmingCharacters(in: .whitespacesAndNewlines)
        let isPct = raw.hasSuffix("%")
        let stripped = raw.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Double(stripped) else { return raw }
        var pct = (isPct || n > 1) ? n : n * 100.0
        if pct < 0 { pct = 0 }
        if pct > 100 { pct = 100 }
        return String(Int(pct.rounded()))
    }

    /// Resolve a phone_control command to the per-verb Shortcut name + its raw
    /// text input. Returns nil if the verb has no Shortcut (caller errors /
    /// redirects).
    static func shortcut(for command: [String: Any]) -> PhoneShortcut? {
        let action = SkillArgs.string(command, "action")
        guard let name = verbShortcutNames[action] else { return nil }
        return PhoneShortcut(name: name, input: rawValue(for: action, command: command))
    }

    /// Dart's `Uri.encodeComponent` unreserved set. Notably NOT
    /// `.urlQueryAllowed`: we must percent-encode `:` and `/` too, and above all
    /// emit `%20` for a space — the iOS Shortcuts app treats `+` as a LITERAL
    /// plus, so a name like "JC Brightness" would arrive as "JC+Brightness" and
    /// the Shortcut would not be found.
    private static let componentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    static func encodeQueryWithPercent20(_ params: [(String, String)]) -> String {
        params.map { "\(encodeComponent($0.0))=\(encodeComponent($0.1))" }.joined(separator: "&")
    }

    /// Convenience for single-entry maps; multi-key callers should pass ordered
    /// pairs so the query string is deterministic.
    static func encodeQueryWithPercent20(_ params: [String: String]) -> String {
        encodeQueryWithPercent20(params.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    static func encodeComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? s
    }

    /// If `command` targets something the app already does NATIVELY, return the
    /// name of the native skill to use instead — so phone_control refuses and
    /// redirects rather than bounce a Shortcut for it. Returns nil for genuine
    /// Shortcut verbs.
    static func nativeRedirectSkill(_ command: [String: Any]) -> String? {
        switch SkillArgs.string(command, "action") {
        case "flashlight":
            return "flashlight_on / flashlight_off"
        case "open_app":
            return "open_app"
        case "alarm":
            return "set_alarm"
        case "get":
            switch SkillArgs.string(command, "what") {
            case "battery":   return "battery_level"
            case "location":  return "get_location"
            case "clipboard": return "clipboard_read"
            default:          return nil
            }
        default:
            return nil
        }
    }

    /// Parse a Shortcut's textual output. A JSON object is returned as-is; any
    /// other text (or nil/empty) is wrapped as `{ok:true, result:<raw>}`.
    static func parseOutput(_ raw: String?) -> [String: Any] {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return ["ok": true, "result": ""] }
        if let data = text.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let dict = decoded as? [String: Any] {
            return dict
        }
        return ["ok": true, "result": text]
    }

    /// Description baked into the phone_control tool. Scoped to the iOS settings
    /// apps can't change directly; everything else redirects to dedicated native
    /// skills.
    static let controlDescription = """
        Control iOS-locked settings via the per-verb "JC …" Shortcuts. Set `action` \
        to the verb and pass its value:
        • brightness / volume → value: 0.0–1.0 (a percent like 30 is fine)   e.g. {"action":"brightness","value":0.3}
        • wifi / bluetooth / focus → value: 1 (on) or 0 (off)
        • open_url → url: a URL (to open an app, pass its URL scheme, e.g. "spotify://")
        • send_message → to: recipient, message: the exact text. This opens the iOS \
        Messages composer pre-filled — the user still taps Send, never a silent send — so \
        ALWAYS confirm the recipient AND the wording in chat before invoking it.
        For battery, location, clipboard, flashlight, vibrate, notify, calls, \
        opening an app by name, and alarms, use the dedicated NATIVE skills instead \
        (they need no Shortcut). Each verb runs a tiny "JC <Verb>" Shortcut (one-time \
        install); an error means that Shortcut is not installed. Each run briefly \
        flashes through the Shortcuts app and changes the setting immediately.
        """
}
