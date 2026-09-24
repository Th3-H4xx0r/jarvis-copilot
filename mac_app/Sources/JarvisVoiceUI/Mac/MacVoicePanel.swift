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
    @State private var sessionPicker = MacSessionPicker()
    /// Which picker is open. Drawn inside the panel — see `MacVoicePickers`.
    @State private var openPicker: MacPickerKind?
    /// Holds the conversation layout between turns of a live session.
    ///
    /// The store clears the transcript and reply at the START of every turn
    /// (`.clearReply`), so "is there text right now" flickers false between
    /// turns. Keyed on that alone, the orb would swell back to full size and
    /// shrink again every time you spoke. Once a session has shown text it keeps
    /// the conversation layout until the session ends.
    @State private var stickyConversation = false
    /// Voice or Live — remembered, so the panel reopens on the one last used.
    @AppStorage("jc.mac.panelMode") private var panelModeRaw = MacPanelMode.voice.rawValue

    private var panelMode: Binding<MacPanelMode> {
        Binding(get: { MacPanelMode(rawValue: panelModeRaw) ?? .voice },
                set: { panelModeRaw = $0.rawValue })
    }

    /// Whether to offer "open in a window". True in the menubar popover, false
    /// in the window itself, which is already the thing the button asks for.
    private let showsOpenInWindow: Bool

    /// A view's `init` is not main-actor-isolated, so the store cannot be a
    /// default argument — the same reason `VoicePage` takes it this way.
    init(store: VoiceStore? = nil, showsOpenInWindow: Bool = false) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { VoiceStore.shared })
        self.showsOpenInWindow = showsOpenInWindow
    }

    private static let orbSize: CGFloat = 124
    /// The orb once a conversation has the panel: small enough to give the text
    /// the room, big enough to still read as the voice that is talking.
    private static let orbCompact: CGFloat = 54

    /// Something to read: the user's words, a reply, or an error.
    private var hasContent: Bool {
        !(store.error ?? "").isEmpty || !store.userTranscript.isEmpty || !store.replySegments.isEmpty
    }

    /// Conversation layout — text above, small orb above the mic — rather than
    /// the invitation — large orb centred, headline beneath it.
    private var conversationLayout: Bool { hasContent || stickyConversation }

    /// The size the panel is drawn for. The HOST sets the real one — the
    /// popover from its `contentSize`, the window from `setContentSize` — and
    /// these are the floor and the preference underneath that: an
    /// `NSHostingController` asked to size itself resolves to the MINIMUM, so
    /// without a floor the controls get squeezed off the bottom. Same numbers as
    /// `mac_popover._WIDTH` / `_HEIGHT`.
    static let idealWidth: CGFloat = 320
    static let idealHeight: CGFloat = 438
    static let minWidth: CGFloat = 280
    static let minHeight: CGFloat = 380

    var body: some View {
        if panelMode.wrappedValue == .live {
            MacLivePanel(mode: panelMode, showsOpenInWindow: showsOpenInWindow)
        } else {
            voiceBody
        }
    }

    private var voiceBody: some View {
        // ONE stack in a fixed order for both layouts. Which layout is showing
        // is expressed only as sizes — how tall the conversation may grow, how
        // much the two spacers may take, how big the orb is — never by swapping
        // views in and out. That is what lets SwiftUI animate the orb SLIDING
        // down and SHRINKING as one continuous motion, instead of fading one orb
        // out and another in somewhere else.
        //
        //   invitation:    top bar · ⟷ · status · ORB · headline · ⟷ · controls
        //   conversation:  top bar · TEXT · status · orb · controls
        VStack(spacing: 0) {
            topBar

            conversation
                .frame(maxWidth: .infinity, maxHeight: conversationLayout ? .infinity : 0)
                .opacity(conversationLayout ? 1 : 0)

            Spacer(minLength: 0)
                .frame(maxHeight: conversationLayout ? 0 : .infinity)

            statusLine
                .padding(.bottom, conversationLayout ? 2 : 6)

            orb

            headline
                .padding(.top, 8)
                .frame(maxHeight: conversationLayout ? 0 : nil)
                .opacity(conversationLayout ? 0 : 1)

            Spacer(minLength: 0)
                .frame(maxHeight: conversationLayout ? 0 : .infinity)

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
                // The row centres its buttons, but the labels under them sit on
                // its bottom edge — and that edge is the window's.
                .padding(.bottom, 8)
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: conversationLayout)
        .padding(.horizontal, 16)
        .frame(minWidth: Self.minWidth, idealWidth: Self.idealWidth, maxWidth: .infinity,
               minHeight: Self.minHeight, idealHeight: Self.idealHeight, maxHeight: .infinity)
        .background(MacPanelBackdrop())
        .overlay {
            if let kind = openPicker {
                MacPickerSheet(title: kind.title,
                               rows: sessionPicker.rows { store.sessionTargetChanged() }) {
                    openPicker = nil
                }
            }
        }
        .task {
            // Loaded up front so the chip opens onto its list rather than onto
            // "Loading…". The model the voice uses is still read here — the
            // choice itself is made in Jarvis Settings.
            await sessionPicker.load()
            await VoiceModelStore.shared.load()
        }
        .onAppear {
            onScreen = true
            // Opening the panel is the moment to connect: the session and the
            // socket are ready by the time the mic is tapped.
            Task { await store.prewarmVoice() }
        }
        .onDisappear {
            onScreen = false
            store.voiceSurfaceHidden()
        }
        .onChange(of: hasContent) { _, now in
            if now { stickyConversation = true }
        }
        .onChange(of: store.isActive) { _, active in
            // A new session opens on the invitation, with the big orb; one that
            // just ended keeps its last reply on screen if there still is one.
            stickyConversation = active ? false : hasContent
        }
        // A popover is dismissed by clicking away, which does not tear the
        // session down — the conversation keeps running in the tray process,
        // and re-opening the panel shows it mid-turn. Stopping is the End
        // button's job, explicitly.
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    /// The pop-out affordance, as a corner icon rather than a button in a strip
    /// of its own.
    ///
    /// It used to be an AppKit `NSButton` in a 34-point footer bolted under the
    /// panel — a grey bar with a text button in it, wearing none of this
    /// design's clothes and costing the panel a tenth of its height. Here it is
    /// what it is: one quiet control in the corner, on the row the status pill
    /// vacated.
    ///
    /// It reports by NOTIFICATION rather than a callback: the thing that acts on
    /// it is the Python tray, and a notification name crosses that bridge
    /// without either side having to hand the other a function.
    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Its own row: beside the two chips and the pop-out there is no width
            // left, and the switch was squeezed to an empty capsule.
            HStack(spacing: 6) {
                MacPanelModeSwitch(mode: panelMode)
                Spacer(minLength: 2)
                MacSettingsButton()
                if showsOpenInWindow { MacOpenInWindowButton() }
            }
            HStack(spacing: 6) {
                // Disabled mid-turn, like the phone's: switching either one under a
                // live turn changes which chat it lands in, or which model finishes
                // answering it.
                MacPickerChip(symbol: "bubble.left", text: sessionPicker.chipLabel,
                              enabled: !store.isActive,
                              accessibilityLabel: "Voice session: \(sessionPicker.chipLabel)") {
                    openPicker = .session
                }
                // The model, turn mode and transcription live in Jarvis Settings
                // (the gear) — one place, not two. The panel keeps the chat.
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
    }

    /// The state, as a small caption directly above the orb — never a pill
    /// under the popover's arrow, which is where it started and where it had no
    /// room at all.
    ///
    /// Above the orb because that keeps the two together in both layouts: over
    /// the big orb in the middle of the panel while it invites you, and between
    /// the text and the small orb once there is a conversation, where it reads
    /// as the state of the voice beneath it.
    ///
    /// The capsule went with it: chrome around two words, in a panel this size,
    /// was most of what the eye landed on. What the pill carried that the
    /// headline does not is the TOOL status — "Searching the web" rather than
    /// "Thinking" — which is the reason it still exists at all.
    ///
    /// Kept in the layout at zero opacity when idle: letting it collapse moves
    /// the buttons under the pointer every time a turn starts or ends.
    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.muted || store.audioInterrupted ? JcTheme.muted : voiceStateColor(store.state))
                .frame(width: 5, height: 5)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
        }
        .opacity(store.state == .idle ? 0 : 1)
        .accessibilityHidden(store.state == .idle)
        .accessibilityElement(children: .combine)
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

    /// The orb, at whichever size the layout wants.
    ///
    /// It is always RENDERED at full size and scaled down, rather than asked for
    /// at the smaller size. The shader takes its size as an argument, and a
    /// shader argument does not animate — it would jump to the small surface on
    /// the first frame while the frame around it was still shrinking, drawing a
    /// tiny orb in a large hole. A scale interpolates, and a 124-point render
    /// scaled to 54 looks exactly like a 54-point one.
    private var orb: some View {
        let side = conversationLayout ? Self.orbCompact : Self.orbSize
        return VoiceOrb(state: store.state,
                        amplitude: store.state == .listening && store.muted ? 0 : store.amplitude,
                        size: Self.orbSize,
                        animating: onScreen)
            .scaleEffect(side / Self.orbSize)
            .frame(width: side, height: side)
            .padding(.vertical, conversationLayout ? 6 : 4)
            // The orb is decoration and must never take a click. It draws its
            // shader surface at size / 0.53 — the visible sphere is 53% of it —
            // inside a frame of `size`, and SwiftUI does not clip: the rectangle
            // it hit-tests extends well past the sphere in every direction. At
            // the top of the panel that swallowed the picker chips; down here,
            // right above the controls, it would swallow the mic button.
            .allowsHitTesting(false)
    }

    /// Question and answer, in one scrolling column that fades at both ends.
    ///
    /// Faded rather than clipped: the reply follows the line being spoken and
    /// keeps it centred, so text is always leaving the top edge. A hard clip cut
    /// those lines in half, and a half-line reads as "this is overflowing".
    @ViewBuilder
    private var conversation: some View {
        Group {
            if let failure = store.error, !failure.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(JcTheme.danger)
                    VoicePlainReply(text: failure, tint: JcTheme.text)
                }
                .padding(.top, 16)
            } else if hasContent {
                VoiceKaraokeReply(segments: store.replySegments,
                                  spokenWords: store.spokenWords,
                                  lead: store.userTranscript)
            } else {
                // Between turns of a live session the text area stays where it
                // is, quietly, rather than the layout folding back up.
                Text(headlineText)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .frame(maxHeight: .infinity)
            }
        }
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    /// The invitation beneath the big orb. No subtitle, and no control hint:
    /// the phone has a screen to spend on both, and here they were two of the
    /// four things in a panel whose buttons already say Mute / Start / Send.
    private var headline: some View {
        Text(headlineText)
            .font(.system(size: 17, weight: .medium))
            .tracking(-0.4)
            .foregroundStyle(JcTheme.text)
            .multilineTextAlignment(.center)
    }

    private var headlineText: String {
        // The picker card closes as soon as On device is chosen, and the model
        // can take a while to download: say so where the eye already is.
        if case .preparing(let fraction) = store.transcriptionStatus, store.state == .idle {
            return fraction.map { "Downloading speech model… \(Int($0 * 100))%" }
                ?? "Getting on-device transcription ready…"
        }
        switch store.state {
        case .idle: return "What's on your mind?"
        case .listening: return store.muted ? "Take your time." : "Go ahead, I'm here."
        case .connecting: return store.captureReady ? "Go ahead, I'm here." : "One moment…"
        default: return "Thinking it through…"
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
