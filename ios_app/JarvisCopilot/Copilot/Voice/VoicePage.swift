import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so the
    /// store can't be a default argument. Tests inject stores built with mocks.
    init(store: VoiceStore? = nil,
         wakeWord: WakeWordController? = nil,
         models: VoiceModelStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { VoiceStore.shared })
        _models = State(initialValue: models ?? MainActor.assumeIsolated { VoiceModelStore.shared })
        self.wakeWord = wakeWord ?? MainActor.assumeIsolated { WakeWordController.shared }
    }

    /// The "Hey Jarvis" listener. This screen owns both halves of it: the toolbar
    /// switch starts and stops it live, and a turn taking the mic suppresses it —
    /// the mic cannot be shared, so a listener left running would make every
    /// recording fail to start.
    private let wakeWord: WakeWordController

    private static let controlsGap: CGFloat = 14

    var body: some View {
        NavigationStack {
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
            .jcScreen("Voice")
            .toolbar { toolbar }
        }
        // The Siri / Control-Center / wake-word latch. On appear for a cold launch
        // (the request lands before any view exists) and on every generation
        // change for a warm one.
        .task { await store.consumeVoiceLaunch() }
        .onChange(of: router.voiceLaunchGeneration) { _, _ in
            Task { await store.consumeVoiceLaunch() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: store.pauseForBackground()
            case .active: Task { await store.resumeFromBackground() }
            default: break
            }
        }
        // The mic is single-owner: hand it to the turn, take it back afterwards.
        .onChange(of: store.isActive, initial: true) { _, active in
            Task { await wakeWord.setVoiceActive(active) }
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

    private func stage(height: CGFloat) -> some View {
        let orbSize = min(246, max(150, height * 0.43))
        return VStack(spacing: 0) {
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
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
            .opacity(store.state == .idle ? 0 : 1)
            .accessibilityHidden(store.state == .idle)

            Spacer(minLength: 12)

            VoiceOrb(state: store.state, amplitude: store.state == .listening && store.muted ? 0 : store.amplitude,
                     size: orbSize, animating: tickerEnabled)
                .frame(height: orbSize + 20)
                .onLongPressGesture(minimumDuration: 0.7) { showDiagnostics = true }

            Spacer(minLength: 12)

            dialogue
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 14)

            Text(controlHint)
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 28)
        .frame(height: height)
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

    @ViewBuilder
    private var dialogue: some View {
        if let failure = store.error, !failure.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(JcTheme.danger)
                VoicePlainReply(text: failure, tint: JcTheme.text)
            }
        } else if !store.replySegments.isEmpty {
            VStack(spacing: 14) {
                if !store.userTranscript.isEmpty {
                    Text(store.userTranscript)
                        .font(.system(size: 14))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                VoiceKaraokeReply(segments: store.replySegments, spokenWords: store.spokenWords)
            }
        } else if !store.userTranscript.isEmpty {
            VoicePlainReply(text: store.userTranscript)
        } else {
            VStack(spacing: 10) {
                Text(store.state == .idle ? "What’s on your mind?" :
                     store.state == .listening ? (store.muted ? "Take your time." : "Go ahead, I’m here.") :
                     store.state == .connecting ? "One moment…" : "Thinking it through…")
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
    }

    // MARK: - Chrome

    /// Flutter's app bar: a sparkles chip that opens the model picker, then the
    /// wake-word ear. The chip carries the model NAME here — the whole point of
    /// the picker is knowing what is answering without opening it.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSessionPicker = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                    Text(sessionSelection.chipLabel).lineLimit(1)
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: 110)
            }
            .accessibilityLabel("Voice session: \(sessionSelection.chipLabel)")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showPicker = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(models.chipLabel).lineLimit(1)
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: 140)
            }
            .accessibilityLabel("Voice model: \(models.chipLabel)")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await toggleWakeWord() }
            } label: {
                // `ear.slash` does NOT exist in SF Symbols — it rendered as an
                // invisible gap. `ear.and.waveform` (on) / `ear` (off) is the
                // closest live pair to Flutter's hearing / hearing_disabled.
                Image(systemName: store.wakeWordEnabled ? "ear.and.waveform" : "ear")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(store.wakeWordEnabled ? JcTheme.cyan : JcTheme.muted)
            }
            .accessibilityLabel(store.wakeWordEnabled ? "Wake word on" : "Wake word off")
        }
    }

    // MARK: - Actions

    /// The 60 fps orb only animates while Voice is the active tab and the app is
    /// foregrounded — every tab lives forever in the shell, so an ungated ticker
    /// would repaint behind all six.
    private var tickerEnabled: Bool {
        scenePhase == .active
            && orbTickerEnabled(activeTab: AppTab.allCases.firstIndex(of: router.selectedTab) ?? 0,
                                ownerTab: voiceTabIndex)
    }

    /// Flip the wake word and start/stop the listener in the same gesture — the
    /// preference on its own would only take effect on the next launch.
    ///
    /// The store's copy is written first so the icon flips immediately, and
    /// reverted if the mic was refused: a switch that reads "on" while nothing is
    /// listening is worse than one that snaps back.
    private func toggleWakeWord() async {
        let on = !store.wakeWordEnabled
        store.setWakeWordEnabled(on)
        let granted = await wakeWord.setEnabled(on)
        if on && !granted {
            store.setWakeWordEnabled(false)
            showMicDialog = true
        }
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
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
