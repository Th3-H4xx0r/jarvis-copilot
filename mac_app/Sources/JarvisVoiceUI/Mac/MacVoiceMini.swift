import AppKit
import SwiftUI

/// The small voice island for push to talk (Jarvis.app holds a key): the orb
/// and a line or two — what you're saying while the key is down, then what
/// Jarvis answers. Same `VoiceStore.shared` as the stage, so a click that
/// opens the stage carries on the same conversation.
struct MacVoiceMini: View {
    @State private var store: VoiceStore
    @State private var onScreen = false
    private static let orbRender: CGFloat = 124
    private static let orbSide: CGFloat = 36

    init() {
        _store = State(initialValue: MainActor.assumeIsolated { VoiceStore.shared })
    }

    var body: some View {
        HStack(spacing: 12) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(status)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.state == .error ? JcTheme.danger : JcTheme.muted)
                Text(line)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(2)
                    .truncationMode(.head)        // the latest words, as they come
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.black)
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

    private var status: String {
        if store.muted && store.isActive { return "Microphone off" }
        switch store.state {
        case .idle: return store.reply.isEmpty ? "Jarvis" : "Jarvis said"
        case .connecting: return store.captureReady ? "Listening" : "Connecting"
        case .listening: return store.captureReady ? "Listening" : "Starting microphone…"
        case .thinking: return store.toolStatus ?? "Thinking"
        case .speaking: return "Jarvis"
        case .error: return "Let's try again"
        }
    }

    private var line: String {
        if let failure = store.error, !failure.isEmpty { return failure }
        switch store.state {
        case .connecting, .listening:
            let heard = store.livePartial.isEmpty ? store.userTranscript : store.livePartial
            return heard.isEmpty ? "Say what you need, then let go." : heard
        case .thinking:
            return store.userTranscript
        case .speaking, .idle, .error:
            return store.reply.isEmpty ? store.userTranscript : store.reply.text
        }
    }
}

/// One push-to-talk turn: listening starts when the key goes down, what was
/// said is sent when it comes up, and once Jarvis has answered the session
/// ends (a realtime session would otherwise listen on) and Jarvis.app is told,
/// so the small island can fold. Holding the key again while Jarvis talks cuts
/// in and starts the next turn.
@MainActor
final class MacPushToTalk {
    static let shared = MacPushToTalk()
    static let doneNotification = Notification.Name("JarvisVoicePanelTalkDone")

    private var held = false
    private var watch: Task<Void, Never>?

    func began() {
        held = true
        let store = VoiceStore.shared
        if store.state == .speaking || store.state == .thinking { store.interrupt() }
        if !store.isActive {
            Task { @MainActor in
                guard await store.ensureMic() else { return }
                await store.primaryAction()
            }
        }
        follow()
    }

    func ended() {
        held = false
        let store = VoiceStore.shared
        if store.state == .listening { store.finishSpeaking() }
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
                    store.finishSpeaking()
                    sent = true
                    continue
                }
                if !self.held && answered && (state == .listening || state == .idle || state == .error) {
                    if state == .listening { await store.stopAll() }
                    NotificationCenter.default.post(name: Self.doneNotification, object: nil)
                    return
                }
                // It never got going (no mic, nothing said, an error).
                if !self.held && !answered && !store.isActive && Date().timeIntervalSince(started) > 2 {
                    NotificationCenter.default.post(name: Self.doneNotification, object: nil)
                    return
                }
            }
        }
    }
}
