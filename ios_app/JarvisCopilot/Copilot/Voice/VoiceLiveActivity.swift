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
    /// Bumped to send a frame again that the island may never have drawn (a Stop,
    /// the keep-fresh beat), so neither dedupe layer drops it as unchanged. App-side
    /// only — never part of the ContentState.
    var resend = 0
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

    /// How long a live voice frame (listening / thinking / speaking) is good for on
    /// the island: its `staleDate`. Past it iOS marks the activity stale and the
    /// widget draws it at rest (`jcVoiceShown`) — the app was suspended or killed,
    /// or iOS lost its updates, so "Listening" there would be a lie (2026-11-24: the
    /// island sat on "Listening 10:05 · It" with the app idle since 01:37).
    static let staleAfterSeconds: TimeInterval = 90

    /// While a talk is on, the frame on the island is sent again this often even if
    /// nothing changed, which moves its `staleDate` on: a real long "Listening"
    /// never goes stale, one whose app stopped sending does.
    static let keepFreshMs = 60_000

    private let clock: VoiceClock
    /// Called with the content that should be on the island now.
    var onPush: ((VoiceLiveActivitySnapshot) -> Void)?

    private var sent: VoiceLiveActivitySnapshot?
    private var lastPush = Date(timeIntervalSince1970: 0)
    private var pendingTimer: VoiceTimerToken?
    private var desired: VoiceLiveActivitySnapshot?
    /// Stamped on every offer; `force` and the keep-fresh beat bump it.
    private var resends = 0
    private var keepFresh: VoiceTimerToken?

    init(clock: VoiceClock) { self.clock = clock }

    /// Offer new content. `terminal` (idle/error) pushes immediately. `force` pushes
    /// it even when it is what was last sent: what was sent is not always what the
    /// island shows (iOS can drop or never apply an update), and a Stop has to put
    /// the true state back — the island's ✕ on a stuck "Listening" used to do
    /// nothing at all, because idle had already "been sent".
    func offer(_ snapshot: VoiceLiveActivitySnapshot, terminal: Bool, force: Bool = false) {
        if force { resends += 1 }
        var snapshot = snapshot
        snapshot.resend = resends
        desired = snapshot
        // Nothing new on screen → don't churn the activity.
        if sent == snapshot {
            pendingTimer?.cancel()
            pendingTimer = nil
            return
        }
        let sinceMs = Int(clock.now.timeIntervalSince(lastPush) * 1000)
        let newState = sent?.state != snapshot.state || sent?.connected != snapshot.connected
        if terminal || newState || force || sinceMs >= Self.windowMs {
            pendingTimer?.cancel()
            pendingTimer = nil
            push(snapshot, terminal: terminal)
        } else if pendingTimer == nil {
            // Trailing edge: re-run after the window so the LATEST state is sent.
            // Terminal frames never wait here, so what it sends is a live one.
            pendingTimer = clock.schedule(after: Self.windowMs - sinceMs) { [weak self] in
                guard let self else { return }
                self.pendingTimer = nil
                if let latest = self.desired, latest != self.sent { self.push(latest, terminal: false) }
            }
        }
    }

    private func push(_ snapshot: VoiceLiveActivitySnapshot, terminal: Bool) {
        sent = snapshot
        lastPush = clock.now
        armKeepFresh(live: !terminal)
        onPush?(snapshot)
    }

    /// A live frame goes again after `keepFreshMs` without a newer one; a terminal
    /// frame ends the beat. Nothing to keep fresh with no island attached (the Mac).
    private func armKeepFresh(live: Bool) {
        keepFresh?.cancel()
        keepFresh = nil
        guard live, onPush != nil else { return }
        keepFresh = clock.schedule(after: Self.keepFreshMs) { [weak self] in
            guard let self else { return }
            self.keepFresh = nil
            guard var again = self.desired ?? self.sent else { return }
            self.resends += 1
            again.resend = self.resends
            self.desired = again
            self.pendingTimer?.cancel()
            self.pendingTimer = nil
            self.push(again, terminal: false)
        }
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
