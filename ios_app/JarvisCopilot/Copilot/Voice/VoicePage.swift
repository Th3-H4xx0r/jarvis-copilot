import SwiftUI
import UIKit

/// A single conversation surface backed by the app-wide voice session.
struct VoicePage: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var store: VoiceStore
    @State private var models: VoiceModelStore
    @State private var showPicker = false
    @State private var showSessionPicker = false
    private let sessionSelection = VoiceSessionSelection.shared
    @State private var showMicDialog = false
    @State private var showDiagnostics = false
    /// Voice ⇄ Live. Mirrored into `VoiceSettings` so it survives a relaunch
    /// (design §7.1); held in `@State` as well so the switch animates.
    @State private var liveMode: Bool
    /// Holds the conversation layout between turns of a live session.
    ///
    /// The store clears the transcript and reply at the START of every turn
    /// (`.clearReply`), so "is there text right now" flickers false between
    /// turns. Keyed on that alone, the orb would swell back to full size and
    /// shrink again every time you spoke. Once a session has shown text it keeps
    /// the conversation layout until the session ends — as the Mac panel does.
    @State private var stickyConversation = false

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so the
    /// store can't be a default argument. Tests inject stores built with mocks.
    init(store: VoiceStore? = nil,
         models: VoiceModelStore? = nil) {
        let resolved = store ?? MainActor.assumeIsolated { VoiceStore.shared }
        _store = State(initialValue: resolved)
        _models = State(initialValue: models ?? MainActor.assumeIsolated { VoiceModelStore.shared })
        _liveMode = State(initialValue: MainActor.assumeIsolated { resolved.settings.liveMode })
    }

    private static let controlsGap: CGFloat = 14
    /// The orb once a conversation has the screen: small enough to give the text
    /// the room, big enough to still read as the voice that is talking.
    private static let orbCompact: CGFloat = 96

    /// Something to read: the user's words, a reply, or an error.
    private var hasContent: Bool {
        !(store.error ?? "").isEmpty || !store.userTranscript.isEmpty || !store.replySegments.isEmpty
    }

    /// Conversation layout — text above, small orb right above the controls —
    /// rather than the invitation — large orb centred, headline beneath it.
    private var conversationLayout: Bool { hasContent || stickyConversation }

    var body: some View {
        NavigationStack {
            Group {
                if liveMode {
                    LiveView()
                } else {
                    voiceStage
                }
            }
            .jcScreen(liveMode ? "Live" : "Voice")
            .toolbar { toolbar }
        }
        // The Siri / Control-Center latch. On appear for a cold launch (the request
        // lands before any view exists) and on every generation change for a warm
        // one. Such a request is a request for VOICE, so it also brings the surface
        // back from Live rather than being swallowed by it.
        .task {
            if await store.consumeVoiceLaunch(), liveMode { switchTo(live: false) }
        }
        // Pre-warm while Voice is the tab on screen: the session and the socket
        // are ready before the tap, so the tap only has to start the mic.
        // Not in Live mode — there is no voice turn coming, and the warm socket
        // would just sit open for the length of an ambient recording.
        .task { if router.selectedTab == .voice, !liveMode { await store.prewarmVoice() } }
        .onChange(of: router.selectedTab) { _, tab in
            if tab == .voice {
                if !liveMode { Task { await store.prewarmVoice() } }
            } else {
                store.voiceSurfaceHidden()
            }
        }
        .onChange(of: hasContent) { _, now in
            if now { stickyConversation = true }
        }
        .onChange(of: store.isActive) { _, active in
            // A new session opens on the invitation, with the big orb; one that
            // just ended keeps its last reply on screen if there still is one.
            stickyConversation = active ? false : hasContent
        }
        .onChange(of: router.voiceLaunchGeneration) { _, _ in
            // The warm-launch half of the latch above, and it has to make the same
            // Live → Voice switch: a Siri request that landed on the Live screen
            // would otherwise start a turn on a surface that cannot show it.
            Task {
                if await store.consumeVoiceLaunch(), liveMode { switchTo(live: false) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: store.pauseForBackground()
            case .active:
                Task {
                    await store.resumeFromBackground()
                    if router.selectedTab == .voice, !liveMode { await store.prewarmVoice() }
                }
            default: break
            }
        }
        .sheet(isPresented: $showPicker) {
            VoiceModelPickerSheet(store: store, models: models)
        }
        .sheet(isPresented: $showSessionPicker) {
            VoiceSessionPicker(selection: sessionSelection) { store.sessionTargetChanged() }
        }
        .sheet(isPresented: $showDiagnostics) {
            VoiceDiagnosticsSheet(lines: store.diagnostics)
        }
        .alert("Enable Microphone", isPresented: $showMicDialog) {
            Button("Not now", role: .cancel) {}
            Button("Open Settings") { openSystemSettings() }
        } message: {
            Text("iOS has blocked microphone access, so the system prompt won't appear "
               + "again. Tap Open Settings, turn on Microphone, then come back.")
        }
    }

    // MARK: - Stage

    /// The conversation surface: the orb, the status pill and the voice controls.
    /// Extracted unchanged from `body` so Live mode can replace the whole thing
    /// without a branch inside the layout — the orb's animation depends on there
    /// being exactly one stack in a fixed order, and a conditional inside it would
    /// be the one thing that breaks it.
    private var voiceStage: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                stage(height: max(geo.size.height - VoiceControls.height - Self.controlsGap, 0))

                if store.canRetryOnServer {
                    VoiceTryServerChip { store.retryLastOnServer() }
                        .padding(.bottom, 10)
                }

                VoiceControls(state: store.state,
                              isActive: store.isActive,
                              muted: store.muted,
                              onPrimary: { Task {
                                  if store.isActive { await store.stopAll() }
                                  else { await onPrimary() }
                              } },
                              onMute: store.toggleMute,
                              onFinish: store.finishSpeaking,
                              onInterrupt: {
                                  if store.mode == .quality { Task { await store.stopAll() } }
                                  else { store.interrupt() }
                              })
                    .padding(.bottom, Self.controlsGap)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// ONE stack in a fixed order for both layouts, like the Mac panel's. Which
    /// layout is showing is expressed only as sizes — how tall the conversation
    /// may grow, how much the spacers take, how big the orb is — never by
    /// swapping views in and out. That is what lets SwiftUI animate the orb
    /// SLIDING down and SHRINKING as one motion while the text opens above it,
    /// instead of fading one orb out and another in somewhere else.
    ///
    ///   invitation:    ⟷ · status · ORB · headline · ⟷ · hint
    ///   conversation:  TEXT · status · orb
    private func stage(height: CGFloat) -> some View {
        let orbFull = min(246, max(150, height * 0.43))
        return VStack(spacing: 0) {
            conversation
                .frame(maxWidth: .infinity, maxHeight: conversationLayout ? .infinity : 0)
                .opacity(conversationLayout ? 1 : 0)

            Spacer(minLength: 0)
                .frame(maxHeight: conversationLayout ? 0 : .infinity)

            statusPill
                .padding(.top, conversationLayout ? 6 : 0)
                .padding(.bottom, conversationLayout ? 4 : 16)

            orb(full: orbFull)

            invitation
                .padding(.top, 22)
                .frame(maxHeight: conversationLayout ? 0 : nil)
                .opacity(conversationLayout ? 0 : 1)

            Spacer(minLength: 0)
                .frame(maxHeight: conversationLayout ? 0 : .infinity)

            Text(controlHint)
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)
                .frame(maxHeight: conversationLayout ? 0 : nil)
                .opacity(conversationLayout ? 0 : 1)
        }
        .padding(.horizontal, 28)
        .frame(height: height)
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86),
                   value: conversationLayout)
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            if store.state == .listening && store.captureReady && !store.muted && !store.audioInterrupted {
                HStack(spacing: 2) {
                    ForEach(0..<5) { index in
                        Capsule().fill(JcTheme.cyan)
                            .frame(width: 2, height: 3 + 9 * min(store.amplitude * 12, 1)
                                   * [0.4, 0.75, 1.0, 0.6, 0.35][index])
                    }
                }
                .frame(height: 12)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: store.amplitude)
                .accessibilityHidden(true)
            }
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(JcTheme.text.opacity(0.85))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(.white.opacity(0.045), in: Capsule())
        .accessibilityElement(children: .combine)
        // Kept in the layout at zero opacity when idle: letting it collapse would
        // move the orb every time a turn starts or ends.
        .opacity(store.state == .idle ? 0 : 1)
        .accessibilityHidden(store.state == .idle)
    }

    /// The orb, at whichever size the layout wants.
    ///
    /// Always RENDERED at full size and scaled down, rather than asked for at the
    /// smaller size: the shader takes its size as an argument, and a shader
    /// argument does not animate — it would jump to the small surface on the
    /// first frame while the frame around it was still shrinking.
    private func orb(full: CGFloat) -> some View {
        let side = conversationLayout ? Self.orbCompact : full
        return VoiceOrb(state: store.state,
                        amplitude: store.state == .listening && store.muted ? 0 : store.amplitude,
                        size: full, animating: tickerEnabled)
            .scaleEffect(side / full)
            .frame(width: side, height: side)
            // The shader surface overhangs the frame by nearly double, and
            // SwiftUI hit-tests all of it — on the Mac that swallowed the
            // buttons beside it. The long press lives on the frame instead.
            .allowsHitTesting(false)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.7) { showDiagnostics = true }
    }

    /// Question and answer in one scrolling column that fades at both ends, so a
    /// long reply can push the question up and out of view rather than being
    /// squeezed under a transcript pinned above it.
    @ViewBuilder
    private var conversation: some View {
        Group {
            if let failure = store.error, !failure.isEmpty {
                VStack(spacing: 12) {
                    JcIcon("exclamationmark.circle")
                        .foregroundStyle(JcTheme.danger)
                    VoicePlainReply(text: failure, tint: JcTheme.text)
                }
                .padding(.top, 24)
            } else if hasContent {
                VoiceKaraokeReply(segments: store.replySegments,
                                  spokenWords: store.spokenWords,
                                  lead: store.userTranscript)
            } else {
                // Between turns of a live session the text area stays where it
                // is, quietly, rather than the layout folding back up.
                Text(headlineText)
                    .font(.system(size: 15))
                    .foregroundStyle(JcTheme.muted)
                    .frame(maxHeight: .infinity)
            }
        }
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.94),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    /// The invitation beneath the big orb.
    private var invitation: some View {
        VStack(spacing: 10) {
            Text(headlineText)
                .font(.system(size: 25, weight: .medium))
                .tracking(-0.6)
                .foregroundStyle(JcTheme.text)
                .multilineTextAlignment(.center)
            Text(store.state == .idle ? "Ask a question or think out loud." :
                 store.state == .listening ? "Your words will appear here." : "Your reply will appear here.")
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var headlineText: String {
        switch store.state {
        case .idle: return "What’s on your mind?"
        case .listening: return store.muted ? "Take your time." : "Go ahead, I’m here."
        case .connecting: return store.captureReady ? "Go ahead, I’m here." : "One moment…"
        default: return "Thinking it through…"
        }
    }

    private var statusText: String {
        if store.audioInterrupted { return "Audio paused" }
        if store.muted && store.isActive { return "Microphone off" }
        if store.state == .listening && !store.captureReady { return "Starting microphone…" }
        switch store.state {
        case .idle: return ""
        // The mic is live from the tap, and what is said while the socket opens
        // is kept — so once audio is flowing it IS listening.
        case .connecting: return store.captureReady ? "Listening" : "Connecting"
        case .listening: return "Listening"
        case .thinking: return store.toolStatus ?? "Thinking"
        case .speaking: return "Jarvis is speaking"
        case .error: return "Let's try again"
        }
    }

    private var statusColor: Color {
        store.muted || store.audioInterrupted ? JcTheme.muted : voiceStateColor(store.state)
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

    // MARK: - Chrome

    /// The model chip carries the model NAME — the whole point of the picker is
    /// knowing what is answering without opening it.
    ///
    /// The session chip is ICON-ONLY: with a title on it too the trailing group
    /// grew past the bar and squeezed the "Voice" title down to "V…". The
    /// session's name lives in the picker sheet (and in the accessibility label).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The leading slot was empty; this is the Voice ⇄ Live switch of §7.1.
        // A menu rather than a tap-to-flip button: both modes are named, so it is
        // never ambiguous which one a tap is about to put you in.
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button { switchTo(live: false) } label: {
                    Label(liveMode ? "Voice" : "Voice ✓", jcIcon: "waveform.circle")
                }
                Button { switchTo(live: true) } label: {
                    Label(liveMode ? "Live ✓" : "Live", jcIcon: "dot.radiowaves.left.and.right")
                }
            } label: {
                HStack(spacing: 5) {
                    JcIcon(liveMode ? "dot.radiowaves.left.and.right" : "waveform.circle",
                           size: 14, weight: .medium)
                    Text(liveMode ? "Live" : "Voice")
                        .font(.system(size: 13, weight: .medium))
                    JcIcon("chevron.down", size: 9, weight: .semibold)
                }
                .foregroundStyle(JcTheme.accent)
            }
            .accessibilityLabel("Mode: \(liveMode ? "Live" : "Voice")")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSessionPicker = true } label: {
                JcIcon("bubble.left", size: 15, weight: .medium)
                    .foregroundStyle(JcTheme.accent)
            }
            .accessibilityLabel("Voice session: \(sessionSelection.chipLabel)")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showPicker = true } label: {
                HStack(spacing: 6) {
                    JcIcon("sparkles").foregroundStyle(JcTheme.accent)
                    Text(models.chipLabel).lineLimit(1)
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: 140)
            }
            .accessibilityLabel("Voice model: \(models.chipLabel)")
        }
    }

    // MARK: - Actions

    /// Switch surfaces, leaving neither one holding the microphone.
    ///
    /// Both modes record, and they configure `AVAudioSession` differently on
    /// purpose (`.videoChat` with echo cancellation for a conversation,
    /// `.default` without it for a room). Leaving the old one running would mean
    /// whichever claim was raised last silently decided the capture quality of the
    /// surface the user is actually looking at.
    @MainActor
    private func switchTo(live: Bool) {
        guard live != liveMode else { return }
        liveMode = live
        store.settings.liveMode = live
        if live {
            Task { await store.stopAll() }
        } else {
            Task { await LiveStore.shared.stop() }
        }
    }

    /// The 60 fps orb only animates while Voice is on screen — every tab stays
    /// mounted in the shell, so an ungated ticker would repaint behind all six.
    private var tickerEnabled: Bool {
        scenePhase == .active && router.selectedTab == .voice && !liveMode
    }

    private func onPrimary() async {
        // Stopping never needs permission.
        let stopping = store.isActive && (store.mode == .realtime || store.state == .listening)
        if stopping {
            await store.primaryAction()
            return
        }
        if await store.ensureMic() {
            await store.primaryAction()
        } else {
            showMicDialog = true
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
