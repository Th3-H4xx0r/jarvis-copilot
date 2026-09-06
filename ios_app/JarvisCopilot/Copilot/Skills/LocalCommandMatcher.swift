import Foundation

/// One command the deterministic matcher recognised.
struct MatchedCommand {
    let name: String
    let args: [String: Any]
    let confirmation: String
}

/// Deterministic matcher for a few simple, reliable, THIS-DEVICE commands the
/// on-device layer can fire instantly — WITHOUT the model (so it can't fabricate
/// args). Anything cross-device ("open X on my Mac"), or not recognised, returns
/// nil so the turn falls through to the pre-gate / local answer.
///
/// Port of `mobile_client/lib/services/local_command_matcher.dart`. Kept
/// alongside `LocalExecutor` rather than merged into it: the executor's grammar
/// is stricter (allow-list + guards), and this one keeps the older, looser
/// behaviours the router still relies on (brightness, send_message).
enum LocalCommandMatcher {
    private static let crossDevice = Rx(
        #"\bon (my|the) (mac|macbook|laptop|computer|desktop|pc|watch|tv|ipad|tablet|server)\b"#)

    private static let open = Rx(
        #"^(?:can you |could you |please |hey,? )?(?:open|launch|start)(?: up)?(?: the)? (.+?)(?: app)?[.?! ]*$"#)

    private static let flashOn = Rx(
        #"(\b(turn on|enable|switch on)\b.*\b(flashlight|torch|light)\b)|(^(flashlight|torch) on$)"#)
    private static let flashOff = Rx(
        #"(\b(turn off|disable|switch off)\b.*\b(flashlight|torch|light)\b)|(^(flashlight|torch) off$)"#)
    private static let vibrate = Rx(
        #"^vibrate( the phone)?[.! ]*$|\bvibrate the phone\b"#)
    private static let volume = Rx(
        #"\b(?:set |change |turn )?(?:the )?volume (?:to |at |up to )?(\d{1,3})\s*%?\b"#)
    private static let brightness = Rx(
        #"\b(?:set |change )?(?:the )?brightness (?:to |at )?(\d{1,3})\s*%?\b"#)
    /// "text <name> <message>" / "send <name> a text saying <message>" etc.
    private static let sendMsg = Rx(
        #"^(?:can you |please |hey,? )?"#
        + #"(?:text|message|imessage|(?:send|shoot)(?: an?)? (?:text|message|imessage|sms)?(?: to)?)\s+"#
        + #"(\w[\w .\-]*?)\s+"#
        + #"(?:saying |that |this:?\s*|:\s*|the message |a message saying )?"#
        + #"(.+)$"#)

    private static let notAnApp = Rx(
        #"\b(door|window|account|file|link|url|website|page|tab|settings?)\b"#)

    static func match(_ text: String) -> MatchedCommand? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.isEmpty { return nil }
        // Cross-device → not a simple local command (let the server target it).
        if crossDevice.hasMatch(lower) { return nil }

        if flashOn.hasMatch(lower) {
            return MatchedCommand(name: "flashlight_on", args: [:], confirmation: "Flashlight on, sir.")
        }
        if flashOff.hasMatch(lower) {
            return MatchedCommand(name: "flashlight_off", args: [:], confirmation: "Flashlight off, sir.")
        }
        if vibrate.hasMatch(lower) {
            return MatchedCommand(name: "vibrate", args: [:], confirmation: "Right away, sir.")
        }

        if let vol = volume.firstMatch(lower), let digits = vol.group(1) {
            let pct = min(max(Int(digits) ?? 50, 0), 100)
            return MatchedCommand(name: "phone_control",
                                  args: ["action": "volume", "value": "\(pct)"],
                                  confirmation: "Volume set to \(pct)%, sir.")
        }
        if let br = brightness.firstMatch(lower), let digits = br.group(1) {
            let pct = min(max(Int(digits) ?? 50, 0), 100)
            return MatchedCommand(name: "phone_control",
                                  args: ["action": "brightness", "value": "\(pct)"],
                                  confirmation: "Brightness set to \(pct)%, sir.")
        }

        // Text someone. `phone_control`'s send_message opens the iOS Messages
        // composer pre-filled, so the user still taps Send — the confirmation
        // line says "composing", not "sent", because nothing has gone out yet.
        if let sm = sendMsg.firstMatch(t),
           let toRaw = sm.group(1), let msgRaw = sm.group(2) {
            let to = toRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = msgRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !to.isEmpty, !msg.isEmpty,
               to.split(whereSeparator: { $0.isWhitespace }).count <= 4 {
                return MatchedCommand(name: "phone_control",
                                      args: ["action": "send_message", "to": to, "message": msg],
                                      confirmation: "Composing a text to \(to), sir.")
            }
        }

        if let m = open.firstMatch(t), let appRaw = m.group(1) {
            let app = appRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !app.isEmpty,
               app.split(whereSeparator: { $0.isWhitespace }).count <= 3,
               !lower.contains("open up to"),
               !notAnApp.hasMatch(app.lowercased()) {
                return MatchedCommand(name: "open_app",
                                      args: ["name": SkillArgs.titleCase(app)],
                                      confirmation: "Opening \(app), sir.")
            }
        }
        return nil
    }
}
