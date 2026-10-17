import Foundation

/// The pure half of a session's chat: folding a `/agents/messages` page into the
/// transcript we already show.
///
/// Lifted from the old Coding tab (it lived inside `_CodingChatViewState._fetch`
/// in Flutter). It's the most edge-case-dense code in the screen (the server can
/// rewind, skip indices, or rewrite a message in place), so it has no state, no
/// clock and no networking — `AgentSessionModel` is a thin shell over it.

// MARK: - Transcript state

/// Everything the chat renders about one session's conversation.
struct CodingTranscript: Equatable {
    /// A window of the chat: `messages[0]` is message `start`. A long chat
    /// opens on its last page and grows upward as you scroll.
    var messages: [CodingChatMessage] = []
    var start = 0
    var end: Int { start + messages.count }
    var hasOlder: Bool { start > 0 }
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

    /// Live = input can be typed. Nil means the page hasn't reported a status.
    var isLive: Bool? {
        guard !status.isEmpty else { return nil }
        return status == "running" || status == "starting" || status == "idle"
    }
}

// MARK: - Reducer

enum CodingStreamReducer {

    enum Merge: Equatable {
        /// Folded in. `hadNew` drives auto-scroll; `hadNewAssistant` says the
        /// agent answered.
        case applied(hadNew: Bool, hadNewAssistant: Bool)
        /// This page can't be folded in incrementally — refetch with `after=0`.
        case needsFullReload
    }

    /// A page of a long chat (the first one, and each one above it).
    static let pageSize = 40

    /// `after=` for the next request: a reconcile re-reads the window we hold;
    /// a refresh re-reads the last message we hold — the server folds a whole
    /// turn into one message that grows in place — and anything past it.
    static func cursor(_ t: CodingTranscript, full: Bool) -> Int {
        full ? t.start : max(t.start, t.end - 1)
    }

    /// `limit=`: a paged chat opens on its last page; after that it reads its
    /// whole window.
    static func limit(_ t: CodingTranscript, paged: Bool) -> Int? {
        paged && t.messages.isEmpty ? pageSize : nil
    }

    /// `before=` for the page above what we hold.
    static func before(_ t: CodingTranscript) -> Int { t.start }

    /// The page above what we hold (the user scrolled to the top). Stitched in
    /// only when it ends right where the window starts; anything else waits for
    /// the next reconcile.
    static func applyOlder(_ page: CodingChatPage, to t: inout CodingTranscript) -> Bool {
        let older = page.messages.filter { $0.i < t.start }
        guard let last = older.last, last.i == t.start - 1, older.first?.i == page.start,
              older.count == t.start - page.start else { return false }
        t.messages = older + t.messages
        t.start = page.start
        return true
    }

    static func apply(_ page: CodingChatPage, full: Bool, to t: inout CodingTranscript) -> Merge {
        if !full {
            // History shrank/reset server-side (restart, re-parse) — reload fully.
            if page.total < t.end { return .needsFullReload }
            // The server jumped past our tail (we missed an index) — heal fully so
            // a message can never silently vanish into a gap.
            if page.messages.contains(where: { $0.i > t.end }) { return .needsFullReload }
        }
        // Both flags are measured against the PRE-merge tail.
        let hadNew = full
            ? !page.messages.isEmpty
            : page.messages.contains { $0.i >= t.end }
        let hadNewAssistant = !full
            && page.messages.contains { $0.i >= t.end && !$0.isUser }

        t.noTranscript = false
        t.loading = false
        if full {
            t.messages = page.messages
            t.start = page.start
        } else {
            for m in page.messages {
                if m.i >= t.start && m.i < t.end {
                    t.messages[m.i - t.start] = m // updated in place (e.g. tool output landed)
                } else if m.i == t.end {
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
        if case APIError.http(let status, _) = error, status == 409 || status == 404 {
            t.noTranscript = true
            t.messages = []
            t.start = 0
        }
    }
}
