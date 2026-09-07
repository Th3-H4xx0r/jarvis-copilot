import Foundation

/// Failure modes the watch surfaces, each mapped to a user-facing message
/// in `WatchViewModel`.
enum AskError: Error, Equatable {
    case notConfigured   // phone reachable but not logged in / no creds
    case network(String) // backend/connection error (detail for logging)
    case unreachable     // phone not reachable over WCSession
}

/// Decoded reply from the phone relay: the assistant text plus an optional
/// JARVIS-voice clip (base64 MP3, present only for short replies that fit under
/// the WCSession size cap; otherwise the watch speaks the text itself).
struct AskResult: Equatable {
    let replyText: String
    let audioBase64: String
    var voiceDbg: String = ""    // phone-side note: was a clip synthesized / sent / too big
    var expectsClip: Bool = false // a JARVIS clip is arriving out-of-band via transferFile

    static func from(_ reply: [String: Any]) -> Result<AskResult, AskError> {
        if (reply["ok"] as? Bool) == true {
            return .success(AskResult(
                replyText: reply["replyText"] as? String ?? "",
                audioBase64: reply["audioBase64"] as? String ?? "",
                voiceDbg: reply["voiceDbg"] as? String ?? "",
                expectsClip: (reply["expectsClip"] as? Bool) ?? false))
        }
        switch reply["error"] as? String {
        case "not_configured": return .failure(.notConfigured)
        default: return .failure(.network(reply["detail"] as? String ?? "error"))
        }
    }
}
