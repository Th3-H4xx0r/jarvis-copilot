import Foundation
import UserNotifications

/// What the user tapped on a notification, decoded from the raw
/// `UNNotificationResponse` before any I/O happens.
///
/// Port of `services/notification_actions.dart` plus the half of
/// `AppDelegate.userNotificationCenter(_:didReceive:…)` that built its payload.
enum NotificationVerdict: String, Equatable, Sendable {
    case allow
    /// Allow, and keep allowing this kind of call (Claude's own suggested rule).
    case always
    case deny
    /// Deny, carrying a steering message for Claude ("do it this way instead").
    case reply
    /// The banner body itself — no verdict; the app foregrounds and the in-app
    /// approval card takes over.
    case open
    /// "Continue all on server" on the Mac-asleep push (`AgentsPushActions`).
    case continueAll
}

/// One decoded notification tap.
struct NotificationAction: Equatable, Sendable {
    var verdict: NotificationVerdict
    var requestID: String = ""
    var sessionID: String = ""
    /// The hook-tracked agent session (engine key) an agent push is about.
    var agentKey: String = ""
    /// The push's `type` (e.g. `agents_recap` for Monday's weekly recap).
    var kind: String = ""
    /// The typed text on a `reply`; empty otherwise.
    var text: String = ""
    /// The deferred-skill payload written by `notificationActionPayload`, when
    /// this was a "tap to run" banner rather than a permission prompt.
    var deferredPayload: String? = nil
    /// The Mac a "went to sleep" push is about (`mac_paused`'s `device_id`).
    var deviceID: String = ""

    /// Action identifiers, matching what the server sets on its APNs payload and
    /// what `NotificationCategories` registers.
    enum Identifier {
        static let approve = "APPROVE_PERMISSION"
        static let always = "ALWAYS_PERMISSION"
        static let answer = "ANSWER_QUESTION"
        static let deny = "DENY_PERMISSION"
        static let reply = "REPLY_PERMISSION"
        static let continueAll = AgentsPushActions.continueAll
    }

    /// The envelope the server nests its fields under.
    static let envelopeKey = "jarviscopilot"

    /// Pure decode: everything the app knows about a tap, with no UN types in
    /// the signature so it can be exercised from a test.
    ///
    /// `actionIdentifier` is `UNNotificationDefaultActionIdentifier` for the
    /// banner body — anything unrecognised is treated the same way (open),
    /// because the in-app card is always a safe fallback.
    static func decode(actionIdentifier: String,
                       userInfo: [AnyHashable: Any],
                       userText: String = "") -> NotificationAction {
        let envelope = userInfo[envelopeKey] as? [String: Any] ?? [:]
        let verdict: NotificationVerdict
        switch actionIdentifier {
        case Identifier.approve: verdict = .allow
        case Identifier.always:  verdict = .always
        case Identifier.deny:    verdict = .deny
        case Identifier.reply:   verdict = .reply
        case Identifier.continueAll: verdict = .continueAll
        default:                 verdict = .open
        }
        return NotificationAction(
            verdict: verdict,
            requestID: (envelope["request_id"] as? String) ?? "",
            sessionID: (envelope["session_id"] as? String) ?? "",
            agentKey: (envelope["agent_key"] as? String) ?? "",
            kind: (envelope["type"] as? String) ?? (envelope["kind"] as? String) ?? "",
            text: verdict == .reply ? userText : "",
            deferredPayload: userInfo[DefaultNotifier.payloadKey] as? String,
            deviceID: (envelope["device_id"] as? String) ?? "")
    }
}

/// The notification categories the app registers at launch.
///
/// The server sends permission prompts with `category: "PERMISSION_APPROVAL"`;
/// without a registered category with the same identifier iOS shows a plain
/// banner and the Approve/Deny/Reply buttons never appear.
enum NotificationCategories {
    static let permissionApproval = "PERMISSION_APPROVAL"
    /// An agent's AskUserQuestion: "Answer" opens the app on the question.
    static let agentQuestion = "AGENT_QUESTION"

    static func all() -> Set<UNNotificationCategory> {
        // Allowing runs something on a computer: iOS asks to unlock the phone first.
        let approve = UNNotificationAction(
            identifier: NotificationAction.Identifier.approve, title: "Approve",
            options: [.authenticationRequired])
        let always = UNNotificationAction(
            identifier: NotificationAction.Identifier.always, title: "Always allow",
            options: [.authenticationRequired])
        let answer = UNNotificationAction(
            identifier: NotificationAction.Identifier.answer, title: "Answer", options: [.foreground])
        let deny = UNNotificationAction(
            identifier: NotificationAction.Identifier.deny, title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(
            identifier: NotificationAction.Identifier.reply, title: "Reply", options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Tell Claude what to do instead…")
        let base: Set<UNNotificationCategory> = [
            UNNotificationCategory(
                identifier: permissionApproval,
                actions: [approve, always, deny, reply],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: agentQuestion, actions: [answer],
                intentIdentifiers: [], options: [])]
        // "MacBook went to sleep" — Continue all on server.
        return base.union(AgentsPushActions.categories())
    }
}

/// Posts the verdict a notification tap produced, and routes taps that are not
/// verdicts.
///
/// Best-effort by design: a failed POST leaves the request pending and the in-app
/// approval card lets the user retry, which is strictly better than blocking the
/// tap handler on a network call iOS is about to suspend.
@MainActor
final class NotificationActionHandler {
    /// The banner posted when a verdict could not be delivered.
    static let verdictFailureIdentifier = "jc.permission.undelivered"

    private let coding: CodingSessionsAPI
    private let router: AppDeepLinkRouter
    private let pending: PendingActions
    private let notifier: any Notifying

    /// The error from the last verdict POST, or nil when it landed. Read by the
    /// tests; the user hears about it through the banner below.
    private(set) var lastVerdictError: String?

    init(coding: CodingSessionsAPI = CodingSessionsAPI(),
         router: AppDeepLinkRouter? = nil,
         pending: PendingActions = .shared,
         notifier: (any Notifying)? = nil) {
        self.coding = coding
        self.router = router ?? AppDeepLinkRouter()
        self.pending = pending
        self.notifier = notifier ?? DefaultNotifier()
    }

    /// Handle one decoded tap. Returns the skill name when the tap recovered a
    /// deferred action (the caller drains the queue), else nil.
    @discardableResult
    func handle(_ action: NotificationAction) async -> String? {
        // A "tap to run" banner from `InvokeRunner`'s foreground-defer path.
        // Enqueue first: the drain is what actually runs it, and it must see the
        // action even when the permission branch below throws.
        let recovered = pending.enqueue(payload: action.deferredPayload)

        switch action.verdict {
        case .open:
            // Tapping the banner body of a permission prompt should land on the
            // session that asked. The in-app card takes it from there.
            if action.kind == "agents_recap" {
                router.open(.agentsRecap)
            } else if action.kind == AgentsPushActions.pushKind {
                // "MacBook went to sleep": the Agents tab, where the card waits.
                router.open(.agents(key: nil))
            } else if !action.agentKey.isEmpty {
                router.open(.agents(key: action.agentKey))
            } else if !action.sessionID.isEmpty {
                router.open(.coding(session: action.sessionID))
            }
        case .continueAll:
            if !(await AgentsPushActions.continueAllInBackground(deviceId: action.deviceID)) {
                await postFailure(title: "Couldn't continue on the server",
                                  body: "Open JARVIS to continue your Mac's sessions from the Agents tab.")
            }
        case .allow, .always, .deny, .reply:
            guard !action.requestID.isEmpty else { break }
            let decision = action.verdict == .allow ? "allow" : action.verdict == .always ? "always" : "deny"
            // Reply is a deny that carries the steering message — the server has
            // no separate "steer" verdict.
            let message = action.verdict == .reply ? action.text : nil
            do {
                try await coding.submitPermissionVerdict(
                    action.requestID, decision: decision, message: message)
                lastVerdictError = nil
            } catch {
                // The tap dismissed the prompt, so a swallowed failure looks
                // exactly like an approval that went through — and the session
                // silently sits waiting. Say so, and leave the request pending
                // so the in-app card can still answer it.
                lastVerdictError = JcLog.report(JcLog.services, "permission verdict", error)
                await postVerdictFailure(decision: decision)
            }
        }
        return recovered
    }

    private func postVerdictFailure(decision: String) async {
        await postFailure(title: "Couldn't send your decision",
                          body: "\"\(decision.capitalized)\" didn't reach the server. "
                            + "Open JARVIS to answer the request.")
    }

    private func postFailure(title: String, body: String) async {
        do {
            _ = try await notifier.post(LocalNotificationRequest(
                title: title, body: body, identifier: Self.verdictFailureIdentifier))
        } catch {
            JcLog.dropped(JcLog.services, "failure banner", error)
        }
    }
}
