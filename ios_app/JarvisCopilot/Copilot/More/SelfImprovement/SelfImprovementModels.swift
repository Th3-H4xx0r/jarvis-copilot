import Foundation

/// One self-improvement event parsed out of the server's
/// `~/.jarviscopilot/self_improvement.log`.
struct SelfImprovementEvent: Identifiable, Equatable, Sendable {
    var kind: String
    var origin: String
    var ts: String
    var text: String
    var id: String

    init(json: JSONObject, index: Int) {
        let k = MoreJSON.text(json["kind"])
        kind = k.isEmpty ? "change" : k
        origin = MoreJSON.text(json["origin"])
        ts = MoreJSON.text(json["ts"])
        text = MoreJSON.text(json["text"])
        id = ts.isEmpty ? "event_\(index)" : "\(ts)#\(index)"
    }

    /// Badge label: FAILED / REJECTED / REVIEWED / LEARNED.
    var label: String {
        switch kind {
        case "fail": return "FAILED"
        case "rejected": return "REJECTED"
        case "noop": return "REVIEWED"
        default: return "LEARNED"
        }
    }

    var tone: MoreTone {
        switch kind {
        case "fail": return .danger
        case "rejected": return .accent
        case "noop": return .muted
        default: return .success
        }
    }

    func tsLabel(now: Date = Date()) -> String { RelativeTime.format(ts, now: now) }
}
