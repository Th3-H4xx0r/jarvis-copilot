import Foundation

/// Failure modes the watch surfaces, each mapped to a user-facing message
/// in `WatchViewModel`.
enum AskError: Error, Equatable {
    case notConfigured   // phone reachable but not logged in / no creds
    case network(String) // backend/connection error (detail for logging)
    case unreachable     // phone not reachable over WCSession
}

/// Decoded reply from the phone relay. Carries only the assistant text — the
/// spoken clip arrives separately via `WCSession.transferFile` (see
/// `WatchConnector.session(_:didReceive:)`).
struct AskResult: Equatable {
    let replyText: String

    static func from(_ reply: [String: Any]) -> Result<AskResult, AskError> {
        if (reply["ok"] as? Bool) == true {
            return .success(AskResult(replyText: reply["replyText"] as? String ?? ""))
        }
        switch reply["error"] as? String {
        case "not_configured": return .failure(.notConfigured)
        default: return .failure(.network(reply["detail"] as? String ?? "error"))
        }
    }
}
