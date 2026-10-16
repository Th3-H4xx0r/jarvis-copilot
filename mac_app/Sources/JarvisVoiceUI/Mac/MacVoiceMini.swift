import AppKit
import Observation
import SwiftUI

/// The small voice island for push to talk (Jarvis.app holds a key). On the
/// left the orb with its state under it; on the right what you're saying, big
/// and white — and once Jarvis answers, your words slide up into a small grey
/// line and the answer takes their place. While the key is down a "Release to
/// send" chip says it's listening to you. Same `VoiceStore.shared` as the
/// stage, so a click that opens the stage carries on the same conversation.
struct MacVoiceMini: View {
    @State private var store: VoiceStore
    @State private var talk: MacPushToTalk
    @State private var onScreen = false
    private static let orbRender: CGFloat = 124
    private static let orbSide: CGFloat = 32

    init() {
        _store = State(initialValue: MainActor.assumeIsolated { VoiceStore.shared })
        _talk = State(initialValue: MainActor.assumeIsolated { MacPushToTalk.shared })
    }

    /// Jarvis's words have started: yours become the subtitle.
    private var answering: Bool { !store.reply.isEmpty && store.error == nil }

    var body: some View {
        HStack(spacing: 12) {
            orbColumn
            words
            if talk.held { holdChip.transition(.opacity.combined(with: .scale(scale: 0.9))) }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.black)
        .animation(.easeOut(duration: 0.18), value: talk.held)
        .onAppear {
            onScreen = true
            store.prewarmsMic = false
        }
        .onDisappear {
            onScreen = false
            store.voiceSurfaceHidden()
        }
        .preferredColorScheme(.dark)
    }

    /// The orb, and right under it what it's doing.
    private var orbColumn: some View {
        VStack(spacing: 3) {
            VoiceOrb(state: store.state,
                     amplitude: store.state == .listening && store.muted ? 0 : store.amplitude,
                     size: Self.orbRender,
                     animating: onScreen)
                .scaleEffect(Self.orbSide / Self.orbRender)
                .frame(width: Self.orbSide, height: Self.orbSide)
                .allowsHitTesting(false)
                // The notch's orb flies here and hands off (MacIslandOrbLink).
                .opacity(MacIslandOrbLink.shared.hidden ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    MacIslandOrbLink.shared.report($0)
                }
            Text(status)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(store.state == .error ? JcTheme.danger : JcTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 64)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: status)
        }
        .frame(width: 64)
    }

    /// Your words big, then — once Jarvis answers — small and grey above the answer.
    private var words: some View {
        GeometryReader { g in
            let subtitleScale: CGFloat = 0.7
            VStack(alignment: .leading, spacing: answering ? 2 : 0) {
                Text(heard)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(answering ? JcTheme.muted : JcTheme.text)
                    .lineLimit(answering ? 1 : 2)
                    .truncationMode(answering ? .tail : .head)
                    // Scaled, not re-fonted: a scale animates, a font size jumps.
                    .frame(width: answering ? g.size.width / subtitleScale : g.size.width, alignment: .leading)
                    .scaleEffect(answering ? subtitleScale : 1, anchor: .topLeading)
                    .frame(width: g.size.width, height: answering ? 14 : nil, alignment: .topLeading)
                if answering {
                    Text(store.reply.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(2)
                        .truncationMode(.head)        // the latest words, as they come
                        .frame(width: g.size.width, alignment: .leading)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: answering)
        }
    }

    /// "Release to send", with a dot that breathes, while the key is down.
    private var holdChip: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                Circle()
                    .fill(JcAccent.color)
                    .frame(width: 6, height: 6)
                    .opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi * 1.2)))
                Text("Release to send")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(JcAccent.color)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(JcAccent.color.opacity(0.14)))
        }
    }

    private var status: String {
        switch store.state {
        case .idle: return store.reply.isEmpty ? "Jarvis" : "Done"
        case .connecting: return store.captureReady || talk.held ? "Listening" : "Connecting"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .error: return "Try again"
        }
    }

    /// What you said (or are saying).
    private var heard: String {
        if let failure = store.error, !failure.isEmpty { return failure }
        let live = store.livePartial.isEmpty ? store.userTranscript : store.livePartial
        if !live.isEmpty { return live }
        switch store.state {
        case .connecting, .listening: return talk.held ? "Listening…" : "Say what you need, then let go."
        case .thinking: return "…"
        default: return ""
        }
    }
}

/// One push-to-talk turn: listening starts when the key goes down, what was
/// said is sent when it comes up, and once Jarvis has answered the session
/// ends (a realtime session would otherwise listen on) and Jarvis.app is told,
/// so the small island can fold. Holding the key again while Jarvis talks cuts
/// in and starts the next turn.
///
/// The mic starts without voice processing (`VoiceAudioEngine.skipVoiceProcessing`):
/// building the echo-cancelling unit took ~1 s on the main thread — the island
/// froze opening and the first words were lost. Nothing needs cancelling: you
/// talk while Jarvis is quiet, and once you let go the mic is muted, so the
/// answer can't be heard as you talking over it.
@MainActor
@Observable
final class MacPushToTalk {
    static let shared = MacPushToTalk()
    static let doneNotification = Notification.Name("JarvisVoicePanelTalkDone")
    /// The mic is up (or gave up): Jarvis.app opens the small island now, so
    /// its animation never shares the main thread with the mic starting.
    static let readyNotification = Notification.Name("JarvisVoicePanelTalkReady")

    /// The key is down (the small island shows "Release to send").
    private(set) var held = false
    @ObservationIgnored private var watch: Task<Void, Never>?

    func began() {
        held = true
        let store = VoiceStore.shared
        if store.state == .speaking || store.state == .thinking { store.interrupt() }
        store.muted = false
        store.note("push to talk: down (active=\(store.isActive) engineRunning=\(VoiceAudioEngine.shared.isRunning) echoCancel=\(VoiceAudioEngine.shared.voiceProcessing))")
        if !store.isActive {
            VoiceAudioEngine.shared.skipVoiceProcessing = true
            Task { @MainActor in
                guard await store.ensureMic() else { return Self.ready() }
                await store.primaryAction()
                // Say so once audio flows (or the start failed, or it's slow).
                for _ in 0..<60 {
                    if store.captureReady || store.state == .listening || !store.isActive { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                Self.ready()
            }
        } else {
            Self.ready()
        }
        follow()
    }

    private static func ready() {
        NotificationCenter.default.post(name: readyNotification, object: nil)
    }

    func ended() {
        held = false
        let store = VoiceStore.shared
        if store.state == .listening { send(store) }
    }

    /// What was said goes; the mic goes quiet until the answer is done.
    private func send(_ store: VoiceStore) {
        store.finishSpeaking()
        store.muted = true
    }

    /// Watch this turn through to its answer (polled: a turn is seconds long).
    private func follow() {
        watch?.cancel()
        watch = Task { @MainActor [weak self] in
            let store = VoiceStore.shared
            let started = Date()
            var answered = false
            var sent = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                let state = store.state
                if state == .thinking || state == .speaking {
                    answered = true
                    sent = true
                }
                // Let go before the mic was up: send as soon as it listens.
                if !self.held && state == .listening && !sent {
                    self.send(store)
                    sent = true
                    continue
                }
                if !self.held && answered && (state == .listening || state == .idle || state == .error) {
                    if state == .listening { await store.stopAll() }
                    self.finish(store)
                    return
                }
                // It never got going (no mic, nothing said, an error).
                if !self.held && !answered && !store.isActive && Date().timeIntervalSince(started) > 2 {
                    self.finish(store)
                    return
                }
            }
        }
    }

    private func finish(_ store: VoiceStore) {
        store.muted = false
        VoiceAudioEngine.shared.skipVoiceProcessing = false
        NotificationCenter.default.post(name: Self.doneNotification, object: nil)
    }
}
