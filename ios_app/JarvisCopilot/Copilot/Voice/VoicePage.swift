import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The Voice tab — a recreation of the webui voice experience: a state-coloured
/// orb, the user's line above it, and the reply lit up word-by-word as it's
/// spoken.
///
/// Port of `pages/voice_page.dart` at its current HEAD, which is deliberately
/// bare: caption → orb → reply → three buttons, and nothing else. No mode
/// segment, no waveform, no device strip, no status pill and no error banner —
/// a failure is shown THROUGH the reply slot, so it reads as an answer. The
/// settings those controls used to expose now live behind the toolbar chip.
///
/// It references the single app-wide session (``VoiceStore/shared``) rather than
/// constructing one: the mic, the audio session and the socket are all
/// process-wide, so a second store would fight the first, and a rebuilt page must
/// not be able to spawn one.
struct VoicePage: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var store: VoiceStore
    @State private var models: VoiceModelStore
    @State private var showPicker = false
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

    // Flutter's fixed run down the stage: caption, 30, orb 248, 30. The caption is
    // pinned at its two-line height so the orb doesn't jump when a transcript
    // wraps (Flutter lets it shift; a 248 pt orb sliding 21 pt reads as a glitch).
    private static let orbSize: CGFloat = 248
    private static let captionHeight: CGFloat = 44
    private static let orbGap: CGFloat = 30

    /// What the control row leaves under itself, and nothing more.
    ///
    /// This page used to add `GlassNavBar.reservedHeight` here as well, because
    /// the pill was an overlay and the `safeAreaInset` the shell applied to each
    /// page did not survive the page's own `NavigationStack` (a
    /// `UINavigationController` re-reads the safe area from UIKit). `NavShell`
    /// now gives the pill REAL layout space, so this container already ends at the
    /// top of the pill's strip — the compensation had become a second reservation
    /// and floated the mic a whole bar-height too high (measured: 101 pt of
    /// clearance where the chat composer has 20). See `ShellPolishSnapshotTests`.
    private static let controlsGap: CGFloat = 12

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
                                  onPrimary: { Task { await onPrimary() } },
                                  onMute: store.toggleMute,
                                  onFinish: store.finishSpeaking,
                                  onInterrupt: store.interrupt)
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

    /// Everything above the controls. Flutter splits the space it doesn't spend on
    /// the caption + orb three ways — `Spacer(flex: 3)`, `Expanded(flex: 6)` for
    /// the reply, `Spacer(flex: 1)` — which SwiftUI has no weighted spacer for, so
    /// the leftover is measured and divided here.
    private func stage(height: CGFloat) -> some View {
        let fixed = Self.captionHeight + Self.orbGap + Self.orbSize + Self.orbGap
        let leftover = max(height - fixed, 0)

        return VStack(spacing: 0) {
            Color.clear.frame(height: leftover * 0.3)

            VoiceTopLine(text: store.userTranscript.isEmpty
                         ? voiceCaption(for: store.state)
                         : store.userTranscript)
                .frame(height: Self.captionHeight)
                .animation(.easeInOut(duration: 0.25), value: store.userTranscript)

            Color.clear.frame(height: Self.orbGap)

            VoiceOrb(state: store.state, amplitude: store.amplitude,
                     size: Self.orbSize, animating: tickerEnabled)
                .onLongPressGesture(minimumDuration: 0.7) { showDiagnostics = true }

            Color.clear.frame(height: Self.orbGap)

            reply
                .frame(maxWidth: .infinity)
                .frame(height: leftover * 0.6, alignment: .top)

            Color.clear.frame(height: leftover * 0.1)
        }
        .padding(.horizontal, 28)
    }

    /// The reply slot. A failure is the reply (Flutter: `reply = _c.error!` with
    /// every word "spoken"); otherwise the karaoke reply, and before either, a
    /// quiet echo of the state where the reply will land.
    @ViewBuilder
    private var reply: some View {
        if let failure = store.error, !failure.isEmpty {
            // Flutter lights every word of a failure (`spokenWords = 1 << 30`), so
            // it reads in the reply's own white — the red orb and the "Something
            // went wrong" caption above it are what mark it as a failure.
            VoicePlainReply(text: failure)
        } else if !store.replySegments.isEmpty {
            VoiceKaraokeReply(segments: store.replySegments, spokenWords: store.spokenWords)
        } else {
            VoiceStatusLabel(state: store.state, toolStatus: store.toolStatus)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.7) { showDiagnostics = true }
        }
    }

    // MARK: - Chrome

    /// Flutter's app bar: a sparkles chip that opens the model picker, then the
    /// wake-word ear. The chip carries the model NAME here — the whole point of
    /// the picker is knowing what is answering without opening it.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            VoiceModelChip(label: models.chipLabel) { showPicker = true }
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
