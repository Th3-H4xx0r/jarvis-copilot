import AppKit
import SwiftUI

/// The Mac's voice surface: the phone's conversation, at popover size.
///
/// This is the ONLY Mac-specific view in the target. Everything it composes —
/// the orb, the karaoke reply, the controls, and the `VoiceStore` driving all
/// three — is the same code the phone builds. What differs is the frame: a
/// 400×560 menubar popover has no navigation bar, no tab bar and no sheets, so
/// the phone's `VoicePage` (which is built from all three) stays on the phone
/// and this composes the same pieces directly.
struct MacVoicePanel: View {
    @State private var store: VoiceStore
    /// Whether the panel is on screen, which is the orb's only ticker gate here
    /// (see `LiquidGlassOrb`: `scenePhase` is meaningless under AppKit). A closed
    /// popover takes its content view out of the hierarchy, so this goes false
    /// and the 60 fps loop stops — the conversation underneath keeps running.
    @State private var onScreen = false

    /// A view's `init` is not main-actor-isolated, so the store cannot be a
    /// default argument — the same reason `VoicePage` takes it this way.
    init(store: VoiceStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { VoiceStore.shared })
    }

    private static let orbSize: CGFloat = 168

    /// The size the panel is drawn for. The HOST sets the real one — the
    /// popover from its `contentSize`, the window from `setContentSize` — and
    /// these are the floor and the preference underneath that: an
    /// `NSHostingController` asked to size itself resolves to the MINIMUM, so
    /// without a floor the controls get squeezed off the bottom. Same numbers as
    /// `mac_popover._WIDTH` / `_HEIGHT`.
    static let idealWidth: CGFloat = 400
    static let idealHeight: CGFloat = 560
    static let minWidth: CGFloat = 340
    static let minHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            statusPill
                .padding(.top, 14)
                .opacity(store.state == .idle ? 0 : 1)
                .accessibilityHidden(store.state == .idle)

            Spacer(minLength: 8)

            VoiceOrb(state: store.state,
                     amplitude: store.state == .listening && store.muted ? 0 : store.amplitude,
                     size: Self.orbSize,
                     animating: onScreen)
                .frame(height: Self.orbSize + 12)

            Spacer(minLength: 8)

            dialogue
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 10)

            Text(controlHint)
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            VoiceControls(state: store.state,
                          isActive: store.isActive,
                          muted: store.muted,
                          onPrimary: { Task { await primary() } },
                          onMute: store.toggleMute,
                          onFinish: store.finishSpeaking,
                          onInterrupt: {
                              if store.mode == .quality { Task { await store.stopAll() } }
                              else { store.interrupt() }
                          })
        }
        .padding(.horizontal, 22)
        .frame(minWidth: Self.minWidth, idealWidth: Self.idealWidth, maxWidth: .infinity,
               minHeight: Self.minHeight, idealHeight: Self.idealHeight, maxHeight: .infinity)
        .background(backdrop)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        // A popover is dismissed by clicking away, which does not tear the
        // session down — the conversation keeps running in the tray process,
        // and re-opening the panel shows it mid-turn. Stopping is the End
        // button's job, explicitly.
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    /// The phone's aurora backdrop lives in its design system (`UI/Glass.swift`),
    /// which is built from navigation-bar modifiers that do not exist here. This
    /// is the same two-stop ground with one glow, which is all a 400 pt panel
    /// shows of it anyway.
    private var backdrop: some View {
        LinearGradient(colors: [Color(jcHex: 0x0A0C12), Color(jcHex: 0x050608)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(jcHex: 0x1EA89C, alpha: 0.10),
                                 Color(jcHex: 0x1EA89C, alpha: 0)],
                        center: .center, startRadius: 0, endRadius: 170))
                    .frame(width: 340, height: 340)
                    .offset(y: -60)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(store.muted || store.audioInterrupted ? JcTheme.muted : voiceStateColor(store.state))
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(JcTheme.text.opacity(0.85))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.white.opacity(0.045), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if store.audioInterrupted { return "Audio paused" }
        if store.muted && store.isActive { return "Microphone off" }
        if store.state == .listening && !store.captureReady { return "Starting microphone…" }
        switch store.state {
        case .idle: return ""
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .thinking: return store.toolStatus ?? "Thinking"
        case .speaking: return "Jarvis is speaking"
        case .error: return "Let's try again"
        }
    }

    private var controlHint: String {
        if store.audioInterrupted { return "Your conversation will resume when audio is available." }
        if store.muted && store.isActive { return "Unmute to keep talking." }
        switch store.state {
        case .listening:
            return store.mode == .quality ? "Tap Send when you're done." : "Pause when you're done, or tap Send."
        case .thinking, .speaking: return "You can interrupt at any time."
        case .idle, .error: return "Tap the microphone to start."
        case .connecting: return "Getting your conversation ready."
        }
    }

    @ViewBuilder
    private var dialogue: some View {
        if let failure = store.error, !failure.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(JcTheme.danger)
                VoicePlainReply(text: failure, tint: JcTheme.text)
            }
        } else if !store.replySegments.isEmpty {
            VStack(spacing: 12) {
                if !store.userTranscript.isEmpty {
                    Text(store.userTranscript)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                VoiceKaraokeReply(segments: store.replySegments, spokenWords: store.spokenWords)
            }
        } else if !store.userTranscript.isEmpty {
            VoicePlainReply(text: store.userTranscript)
        } else {
            VStack(spacing: 8) {
                Text(store.state == .idle ? "What's on your mind?" :
                     store.state == .listening ? (store.muted ? "Take your time." : "Go ahead, I'm here.") :
                     store.state == .connecting ? "One moment…" : "Thinking it through…")
                    .font(.system(size: 20, weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(JcTheme.text)
                    .multilineTextAlignment(.center)
                Text(store.state == .idle ? "Ask a question or think out loud." :
                     store.state == .listening ? "Your words will appear here." : "Your reply will appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Actions

    /// Mic permission is asked for before starting, never before stopping.
    ///
    /// Unlike the phone there is no Settings deep link to offer when macOS has
    /// already refused: `ensureMic` puts the refusal in `store.error`, which the
    /// panel renders through the reply slot like any other failure.
    private func primary() async {
        if store.isActive {
            await store.stopAll()
            return
        }
        guard await store.ensureMic() else { return }
        await store.primaryAction()
    }
}
