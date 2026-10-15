import AppKit
import Observation

/// The Mail tab: Apple Mail's inbox (read only while the tab is open) and a
/// compose box that sends through Resend (the server's key and From address)
/// or Apple Mail — only when you press Send.
@MainActor
@Observable
final class MailController {
    static let shared = MailController()

    enum Via: String, CaseIterable, Identifiable { case appleMail, resend
        var id: String { rawValue }
        var label: String { self == .appleMail ? "Apple Mail" : "Resend" }
    }

    private(set) var inbox = MailInbox(unread: 0, messages: [])
    private(set) var mailRunning = false
    private(set) var status: String?
    private(set) var sending = false
    var to = ""
    var subject = ""
    var body = ""
    var via: Via {
        didSet { UserDefaults.standard.set(via.rawValue, forKey: "mail.via") }
    }

    @ObservationIgnored private var timer: Timer?

    private init() {
        via = Via(rawValue: UserDefaults.standard.string(forKey: "mail.via") ?? "") ?? .appleMail
    }

    /// While the tab is shown: now and every minute.
    func setVisible(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        refresh()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        mailRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
        guard mailRunning else { inbox = MailInbox(unread: 0, messages: []); return }
        if let out = run(MailScript.inbox()) { inbox = MailInbox.parse(out) }
    }

    func markRead(_ m: MailInbox.Message) {
        _ = run(MailScript.markRead(m.id))
        if let i = inbox.messages.firstIndex(of: m) {
            inbox.messages[i].isRead = true
            inbox.unread = max(0, inbox.unread - 1)
        }
    }

    func reply(_ m: MailInbox.Message) { _ = run(MailScript.reply(m.id)) }
    func open(_ m: MailInbox.Message) { _ = run(MailScript.open(m.id)) }

    func send() {
        let recipients = MailScript.recipients(to)
        guard !recipients.isEmpty, !subject.trimmingCharacters(in: .whitespaces).isEmpty, !body.isEmpty, !sending else {
            status = "Fill in who to, a subject and the message."
            return
        }
        status = nil
        if via == .appleMail {
            if run(MailScript.compose(to: recipients, subject: subject, body: body, send: true)) != nil {
                sent()
            } else {
                status = "Mail couldn't send it (\(lastError ?? "no permission?"))."
            }
            return
        }
        guard let origin = AppModel.shared.apiOrigin, let url = URL(string: origin + "/api/services/mail/send") else {
            status = "Jarvis isn't connected on this Mac (jc-client)."
            return
        }
        sending = true
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["to": recipients, "subject": subject, "text": body])
        Task { [weak self] in
            defer { self?.sending = false }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if (resp as? HTTPURLResponse)?.statusCode == 200, J.b(json["ok"]) {
                    self?.sent()
                } else {
                    self?.status = J.s(json["error"], "Resend didn't take it.")
                }
            } catch {
                self?.status = error.localizedDescription
            }
        }
    }

    /// Open the draft in Mail instead of sending it.
    func openDraftInMail() {
        _ = run(MailScript.compose(to: MailScript.recipients(to), subject: subject, body: body, send: false))
    }

    private func sent() {
        status = "Sent."
        to = ""; subject = ""; body = ""
    }

    @ObservationIgnored private var lastError: String?

    private func run(_ src: String) -> String? {
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        lastError = err.map { J.s($0[NSAppleScript.errorMessage], "AppleScript error") }
        return err == nil ? (out?.stringValue ?? "") : nil
    }
}
