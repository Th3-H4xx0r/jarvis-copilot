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
}

/// Throttles + dedupes Live Activity pushes. iOS gives an app a limited update
/// budget: flooding it made the island flicker and get stuck on a stale state
/// (e.g. showing "Listening" after Stop, because the final "idle" update was
/// dropped). Terminal states bypass the throttle so that can't happen.
@MainActor
final class VoiceLiveActivityThrottle {

    /// Minimum gap between non-terminal pushes.
    static let windowMs = 450

    /// Bound the transcript — a long monologue could blow the ~4 KB ContentState
    /// budget and make iOS silently reject the update.
    static let lineLimit = 120

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
        if terminal || sinceMs >= Self.windowMs {
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

    func cancel() {
        pendingTimer?.cancel()
        pendingTimer = nil
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

/// JARVIS's side of the line for the island.
func voiceOutputLine(error: String?, toolStatus: String?,
                     state: VoiceState, assistantText: String) -> String {
    if let error, !error.isEmpty { return error }
    if let toolStatus, !toolStatus.isEmpty { return toolStatus }
    if state == .speaking, !assistantText.isEmpty { return voiceFirstLine(assistantText) }
    return ""
}
