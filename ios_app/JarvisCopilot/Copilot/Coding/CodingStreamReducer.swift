import Foundation

/// The pure half of the coding chat: folding a `/messages` page into the
/// transcript we already show, and classifying the terminal SSE frames.
///
/// All of this lived inside `_CodingChatViewState._fetch` in Flutter. It's the
/// most edge-case-dense code in the tab (the server can rewind, skip indices, or
/// rewrite a message in place), so it's extracted here with no state, no clock
/// and no networking — `CodingSessionStore` is a thin shell over it.

// MARK: - Transcript state

/// A user message delivered to the PTY but not yet visible in the transcript —
/// rendered as a "queued" bubble while Claude is mid-turn.
struct PendingSend: Identifiable, Equatable {
    let id: UUID
    let text: String
    let ts: Date

    init(id: UUID = UUID(), text: String, ts: Date) {
        self.id = id
        self.text = text
        self.ts = ts
    }

    /// Slash commands are swallowed by the transcript parser, so their echo can
    /// never confirm delivery — expire them quickly instead of leaving a ghost.
    var lifetime: TimeInterval { text.hasPrefix("/") ? 25 : 90 }
}

/// Everything the chat renders about one session's conversation.
struct CodingTranscript: Equatable {
    var messages: [CodingChatMessage] = []
    /// working | waiting | idle | nil
    var activityState: String?
    var status = ""
    var statusLine: String?
    var context: ChatContext?
    /// First fetch still in flight.
    var loading = true
    /// The server replied 409 — this session has no transcript yet.
    var noTranscript = false

    var isWaiting: Bool { activityState == "waiting" }

    /// Live = input can be typed. Prefer this freshest signal; nil means the
    /// `/messages` page hasn't reported a status yet and the caller should fall
    /// back to the polled session detail.
    var isLive: Bool? {
        guard !status.isEmpty else { return nil }
        return status == "running" || status == "starting" || status == "idle"
    }
}

// MARK: - Reducer

enum CodingStreamReducer {

    /// Adaptive poll: snappy while a turn is live, relaxed when idle.
    static let activePollInterval: TimeInterval = 2.5
    static let idlePollInterval: TimeInterval = 4
    /// Every Nth incremental poll does a full reconcile.
    static let fullReconcileEvery = 12
    /// How long the optimistic "Claude is working" flag lasts after we send.
    static let localWorkingWindow: TimeInterval = 12

    enum Merge: Equatable {
        /// Folded in. `hadNew` drives auto-scroll; `hadNewAssistant` retires the
        /// optimistic working flag.
        case applied(hadNew: Bool, hadNewAssistant: Bool)
        /// This page can't be folded in incrementally — refetch with `after=0`.
        case needsFullReload
    }

    /// `after=` for the next request: 0 for a reconcile, else the tail we hold.
    static func cursor(_ t: CodingTranscript, full: Bool) -> Int {
        full ? 0 : t.messages.count
    }

    /// A periodic full reconcile heals divergence the incremental cursor can't
    /// see — e.g. an EXISTING message whose content changed server-side (empty
    /// tool turn → text) at an index below our `after` cursor.
    static func shouldFullReconcile(tick: Int) -> Bool {
        tick % fullReconcileEvery == 0
    }

    static func apply(_ page: CodingChatPage, full: Bool, to t: inout CodingTranscript) -> Merge {
        if !full {
            // History shrank/reset server-side (restart, re-parse) — reload fully.
            if page.total < t.messages.count { return .needsFullReload }
            // The server jumped past our tail (we missed an index) — heal fully so
            // a message can never silently vanish into a gap.
            if page.messages.contains(where: { $0.i > t.messages.count }) { return .needsFullReload }
        }
        // Both flags are measured against the PRE-merge tail.
        let hadNew = full
            ? !page.messages.isEmpty
            : page.messages.contains { $0.i >= t.messages.count }
        let hadNewAssistant = !full
            && page.messages.contains { $0.i >= t.messages.count && !$0.isUser }

        t.noTranscript = false
        t.loading = false
        if full {
            t.messages = page.messages
        } else {
            for m in page.messages {
                if m.i >= 0 && m.i < t.messages.count {
                    t.messages[m.i] = m // updated in place (e.g. tool output landed)
                } else if m.i == t.messages.count {
                    t.messages.append(m)
                }
            }
        }
        t.activityState = page.activityState
        t.status = page.status
        t.statusLine = page.statusLine
        // A page with no usage yet must not blank an existing gauge.
        if let c = page.context { t.context = c }
        return .applied(hadNew: hadNew, hadNewAssistant: hadNewAssistant)
    }

    /// A 409 means "no transcript yet" — anything else is a transient blip and
    /// must keep the messages we already show.
    static func applyFetchFailure(_ error: Error, to t: inout CodingTranscript) {
        t.loading = false
        if case APIError.http(let status, _) = error, status == 409 {
            t.noTranscript = true
            t.messages = []
        }
    }

    static func pollInterval(activityState: String?, showThinking: Bool) -> TimeInterval {
        (activityState == "working" || activityState == "waiting" || showThinking)
            ? activePollInterval : idlePollInterval
    }

    /// The thinking bubble: the real state when we have it, plus a short
    /// optimistic window right after WE send something (the server's pane scan
    /// takes ~5s to flip the stored state, and without this there's no feedback
    /// exactly when it matters most).
    static func showThinking(activityState: String?, messageCount: Int,
                             localWorkingUntil: Date?, now: Date) -> Bool {
        if activityState == "waiting" || messageCount == 0 { return false }
        if activityState == "working" { return true }
        guard let until = localWorkingUntil else { return false }
        return now < until
    }

    /// True when the real state has arrived and the optimistic flag has done its
    /// job. A fresh ASSISTANT message also retires it: with a fast reply the
    /// stored state can go straight back to idle without ever reading "working",
    /// and the bubble would otherwise linger under the answer.
    static func retireLocalWorking(activityState: String?, hadNewAssistant: Bool) -> Bool {
        activityState == "working" || activityState == "waiting" || hadNewAssistant
    }

    /// A queued send is delivered once its text shows up in the transcript as a
    /// user message; stale ones expire so they can't linger forever.
    static func expirePendingSends(_ pending: [PendingSend], page: CodingChatPage,
                                   messages: [CodingChatMessage], now: Date) -> [PendingSend] {
        pending.filter { p in
            // Dart compared whole seconds (`Duration.inSeconds`); keep that so a
            // boundary tick behaves identically.
            if Int(now.timeIntervalSince(p.ts)) > Int(p.lifetime) { return false }
            let want = trim(p.text)
            if page.messages.contains(where: { $0.isUser && trim($0.text) == want }) { return false }
            if messages.contains(where: { $0.isUser && trim($0.text) == want }) { return false }
            return true
        }
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Terminal frames

/// One decoded `/api/terminal/output` frame.
enum CodingTerminalEvent: Equatable {
    case output(String)
    case closed(reason: String)
    case failed(message: String)
    /// Keep-alives and anything else the server invents later.
    case other(String)

    init(_ o: [String: Any]) {
        switch CodingJSON.text(o["event"], "message") {
        case "output": self = .output(CodingJSON.text(o["text"]))
        case "terminal_closed": self = .closed(reason: CodingJSON.text(o["reason"]))
        case "terminal_error": self = .failed(message: CodingJSON.text(o["error"]))
        case let name: self = .other(name)
        }
    }

    init(_ event: SSEEvent) { self.init(event.object) }

    /// The grey bracketed note the Flutter app wrote into xterm when the PTY
    /// closed. The escapes are stripped by `TerminalBuffer`, but they're kept so
    /// the bytes stay identical to the Flutter build (and to a future renderer
    /// that does understand colour).
    static func notice(closedBecause reason: String) -> String {
        let msg: String
        switch reason {
        case "ended":
            msg = "[session ended — claude is no longer running; reopen to relaunch]"
        case "reconnecting":
            msg = "[reconnecting — your Mac dropped briefly, retrying…]"
        case "disconnected":
            msg = "[disconnected — your Mac dropped its connection; reopen when it’s back]"
        default:
            msg = "[detached — reopen this session to resume the live terminal]"
        }
        return "\r\n\u{1b}[90m\(msg)\u{1b}[0m\r\n"
    }

    static func notice(error message: String) -> String {
        "\r\n\u{1b}[91m[terminal error: \(message)]\u{1b}[0m\r\n"
    }

    /// Only a soft 'reconnecting' close heals itself; the others need the user.
    static func shouldReattach(afterCloseReason reason: String) -> Bool {
        reason == "reconnecting"
    }

    static let maxReattachAttempts = 4

    /// Backoff for attempt 1…4, then nil so a truly offline Mac doesn't loop
    /// forever (the user can still reopen manually).
    static func reattachDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxReattachAttempts else { return nil }
        return 1.5 * Double(attempt)
    }
}
