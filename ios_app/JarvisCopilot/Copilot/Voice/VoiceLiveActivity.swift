import Foundation

/// What the Dynamic Island shows for a voice turn. Port of the pure half of
/// `voice_controller.dart`'s `_pushLiveActivity`.
struct VoiceLiveActivitySnapshot: Equatable, Sendable {
    /// `connecting` is reported as `thinking` — the island has no distinct art
    /// for it and flipping between the two reads as a glitch.
    let state: String
    /// The user's spoken line.
    let transcript: String
    /// JARVIS's side of the line — a reply snippet or tool status. Empty when
    /// there's nothing to show (the state label covers Listening/Thinking).
    let activity: String
    let connected: Bool
    /// Icon kinds for the online-devices strip, e.g. ["laptop", "phone"].
    let devices: [String]
    /// A one-shot (CarPlay Talk) reply holding the card after its turn ended.
    var holdsCard = false
}

/// Throttles + dedupes Live Activity pushes. iOS gives an app a limited update
/// budget, and an Apple engineer says the island is "purposely nerfed" against
/// frequent updates: flooding it made the island lag and stick on a stale state
/// (e.g. "Listening" after Stop, the final "idle" dropped). So a new STATE goes out
/// at once — it's what the island is for — and only words changing within a state
/// wait out the window.
@MainActor
final class VoiceLiveActivityThrottle {

    /// Minimum gap between pushes that only change the words.
    static let windowMs = 1_200

    /// Bound the transcript — a long monologue could blow the ~4 KB ContentState
    /// budget and make iOS silently reject the update.
    static let lineLimit = 120

    /// A page of the reply on the island: two lines of its 17 pt text, with room
    /// to spare for wide letters.
    static let pageChars = 72

    /// The strip plus the 4 KB cap.
    static let maxDevices = 6

    private let clock: VoiceClock
    /// Called with the content that should be on the island now.
    var onPush: ((VoiceLiveActivitySnapshot) -> Void)?

    private var sent: VoiceLiveActivitySnapshot?
    private var lastPush = Date(timeIntervalSince1970: 0)
    private var pendingTimer: VoiceTimerToken?
    private var desired: VoiceLiveActivitySnapshot?

    init(clock: VoiceClock) { self.clock = clock }

    /// Offer new content. `terminal` (idle/error) pushes immediately.
    func offer(_ snapshot: VoiceLiveActivitySnapshot, terminal: Bool) {
        desired = snapshot
        // Nothing new on screen → don't churn the activity.
        if sent == snapshot {
            pendingTimer?.cancel()
            pendingTimer = nil
            return
        }
        let sinceMs = Int(clock.now.timeIntervalSince(lastPush) * 1000)
        let newState = sent?.state != snapshot.state || sent?.connected != snapshot.connected
        if terminal || newState || sinceMs >= Self.windowMs {
            pendingTimer?.cancel()
            pendingTimer = nil
            push(snapshot)
        } else if pendingTimer == nil {
            // Trailing edge: re-run after the window so the LATEST state is sent.
            pendingTimer = clock.schedule(after: Self.windowMs - sinceMs) { [weak self] in
                guard let self else { return }
                self.pendingTimer = nil
                if let latest = self.desired, latest != self.sent { self.push(latest) }
            }
        }
    }

    private func push(_ snapshot: VoiceLiveActivitySnapshot) {
        sent = snapshot
        lastPush = clock.now
        onPush?(snapshot)
    }
}

/// First non-empty line of `s`, capped so it can't blow the island's budget.
func voiceFirstLine(_ s: String, limit: Int = VoiceLiveActivityThrottle.lineLimit) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    let line = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? t
    guard line.count > limit else { return line }
    return String(line.prefix(limit)) + "…"
}

/// JARVIS's side of the line for the island: while he speaks, the page he's on
/// (`voiceReplyPage`), so the island reads along like the Voice screen's
/// teleprompter.
/// `spokenWords`: how many of the reply's words have been said (nil: none yet).
/// `holdReply`: a finished one-shot turn's reply stays on the card while idle.
func voiceOutputLine(error: String?, toolStatus: String?,
                     state: VoiceState, assistantText: String, spokenWords: Int? = nil,
                     holdReply: Bool = false) -> String {
    if let error, !error.isEmpty { return error }
    if let toolStatus, !toolStatus.isEmpty { return toolStatus }
    if state == .speaking || (holdReply && state == .idle), !assistantText.isEmpty {
        return voiceReplyPage(assistantText, spokenWords: spokenWords ?? 0)
    }
    return ""
}

/// The reply in island-sized pages — whole words, at most `pageChars` each, about
/// two lines of the island — and the one holding the word being said now (the last
/// once it's all said).
///
/// Pages, not a scroll: a Live Activity can't scroll, and every frame is an update
/// out of iOS's budget; a page of speech lasts a few seconds, so turning pages costs
/// one update each. While the island is open a page turn redraws it in place
/// (`LiveActivityCoordinator.islandOpenFor`).
func voiceReplyPage(_ text: String, spokenWords: Int,
                    pageChars: Int = VoiceLiveActivityThrottle.pageChars) -> String {
    let words = voiceWordTokens(text)
    guard !words.isEmpty else { return "" }
    var pages: [(text: String, end: Int)] = []   // `end`: one past the page's last word
    var page = ""
    for (i, word) in words.enumerated() {
        let w = word.count > pageChars ? String(word.prefix(pageChars)) + "…" : word
        if page.isEmpty {
            page = w
        } else if page.count + 1 + w.count <= pageChars {
            page += " " + w
        } else {
            pages.append((page, i))
            page = w
        }
    }
    pages.append((page, words.count))
    let now = min(max(spokenWords, 0), words.count - 1)
    return pages.first { now < $0.end }?.text ?? pages[pages.count - 1].text
}
