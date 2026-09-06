import Foundation

/// One foreground-required action deferred while the app was backgrounded.
struct PendingAction {
    let skill: String
    /// Kept as-is so the skill sees exactly what the server sent.
    let args: [String: Any]
    let at: Date
}

/// Queue of foreground-required actions deferred while the app was backgrounded.
/// When the app returns to the foreground (notification tap or manual open) the
/// resume drain runs each one — `openURL` works again by then.
///
/// In-memory is sufficient because the app stays alive in the background (audio
/// / bluetooth-central modes), so the action survives until the user taps. If
/// the app is fully killed before the tap the deferred action is lost — an
/// acceptable degradation for a rare case.
///
/// Port of `mobile_client/lib/services/pending_actions.dart`.
@MainActor
final class PendingActions {
    static let shared = PendingActions()

    /// Deferred actions older than this are dropped on drain (matches the
    /// bridge's own expiry) so a long-ignored action doesn't fire on a
    /// much-later resume.
    static let ttl: TimeInterval = 60 * 60

    private var queue: [PendingAction] = []

    /// Set by the app to a foreground drain. Called after each `add` so an
    /// action enqueued by a notification TAP — which may land just after the
    /// resume drain already ran — still executes promptly. The callback no-ops
    /// while backgrounded, so the defer-while-backgrounded path is unaffected.
    var onChanged: (() -> Void)?

    init() {}

    func add(_ skill: String, _ args: [String: Any], at: Date? = nil) {
        queue.append(PendingAction(skill: skill, args: args, at: at ?? Date()))
        onChanged?()
    }

    var isEmpty: Bool { queue.isEmpty }
    var count: Int { queue.count }

    /// Remove and return all non-expired actions (expired ones are dropped).
    func drainFresh(now: Date? = nil) -> [PendingAction] {
        let cutoff = (now ?? Date()).addingTimeInterval(-Self.ttl)
        let fresh = queue.filter { $0.at > cutoff }
        queue.removeAll()
        return fresh
    }

    /// Decode a notification payload written by `notificationActionPayload` and
    /// enqueue the action it carries. Returns the skill name when one was
    /// enqueued — the cold-launch path uses this to report what it recovered.
    @discardableResult
    func enqueue(payload: String?) -> String? {
        guard let payload, !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let decoded = parsed as? [String: Any],
              decoded["__jcIslandAction"] as? Bool == true,
              let action = decoded["action"] as? [String: Any] else { return nil }
        let skill = SkillArgs.string(action, "skill")
        guard !skill.isEmpty else { return nil }
        add(skill, action["args"] as? [String: Any] ?? [:])
        return skill
    }
}

/// The payload a deferred-action notification carries, so a tap can re-run it.
/// Same envelope key the Flutter client used (`__jcIslandAction`) — the two
/// clients share the server's notification format.
func notificationActionPayload(skill: String, args: [String: Any]) -> String? {
    let envelope: [String: Any] = [
        "__jcIslandAction": true,
        "action": ["skill": skill, "args": args],
    ]
    guard JSONSerialization.isValidJSONObject(envelope),
          let data = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
    return String(data: data, encoding: .utf8)
}
