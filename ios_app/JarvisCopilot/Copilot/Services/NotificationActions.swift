import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// What the user tapped on a notification, decoded from the raw
/// `UNNotificationResponse` before any I/O happens.
///
/// Port of `services/notification_actions.dart` plus the half of
/// `AppDelegate.userNotificationCenter(_:didReceive:…)` that built its payload.
enum NotificationVerdict: String, Equatable, Sendable {
    case allow
    case deny
    /// Deny, carrying a steering message for Claude ("do it this way instead").
    case reply
    /// The banner body itself — no verdict; the app foregrounds and the in-app
    /// approval card takes over.
    case open
}

/// One decoded notification tap.
struct NotificationAction: Equatable, Sendable {
    var verdict: NotificationVerdict
    var requestID: String = ""
    var sessionID: String = ""
    /// The typed text on a `reply`; empty otherwise.
    var text: String = ""
    /// The deferred-skill payload written by `notificationActionPayload`, when
    /// this was a "tap to run" banner rather than a permission prompt.
    var deferredPayload: String? = nil

    /// Action identifiers, matching what the server sets on its APNs payload and
    /// what `NotificationCategories` registers.
    enum Identifier {
        static let approve = "APPROVE_PERMISSION"
        static let deny = "DENY_PERMISSION"
        static let reply = "REPLY_PERMISSION"
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
        case Identifier.deny:    verdict = .deny
        case Identifier.reply:   verdict = .reply
        default:                 verdict = .open
        }
        return NotificationAction(
            verdict: verdict,
            requestID: (envelope["request_id"] as? String) ?? "",
            sessionID: (envelope["session_id"] as? String) ?? "",
            text: verdict == .reply ? userText : "",
            deferredPayload: userInfo[DefaultNotifier.payloadKey] as? String)
    }
}

/// The notification categories the app registers at launch.
///
/// The server sends permission prompts with `category: "PERMISSION_APPROVAL"`;
/// without a registered category with the same identifier iOS shows a plain
/// banner and the Approve/Deny/Reply buttons never appear.
enum NotificationCategories {
    static let permissionApproval = "PERMISSION_APPROVAL"

    #if canImport(UserNotifications)
    static func all() -> Set<UNNotificationCategory> {
        let approve = UNNotificationAction(
            identifier: NotificationAction.Identifier.approve, title: "Approve", options: [])
        let deny = UNNotificationAction(
            identifier: NotificationAction.Identifier.deny, title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(
            identifier: NotificationAction.Identifier.reply, title: "Reply", options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Tell Claude what to do instead…")
        return [UNNotificationCategory(
            identifier: permissionApproval,
            actions: [approve, deny, reply],
            intentIdentifiers: [], options: [])]
    }
    #endif
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
            if !action.sessionID.isEmpty {
                router.open(.coding(session: action.sessionID))
            }
        case .allow, .deny, .reply:
            guard !action.requestID.isEmpty else { break }
            let decision = action.verdict == .allow ? "allow" : "deny"
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
        do {
            _ = try await notifier.post(LocalNotificationRequest(
                title: "Couldn't send your decision",
                body: "\"\(decision.capitalized)\" didn't reach the server. "
                    + "Open JARVIS to answer the request.",
                identifier: Self.verdictFailureIdentifier))
        } catch {
            JcLog.dropped(JcLog.services, "verdict failure banner", error)
        }
    }
}
