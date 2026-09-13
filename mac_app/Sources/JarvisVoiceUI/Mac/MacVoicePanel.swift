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
    @State private var modelPicker = MacModelPicker()
    /// Which picker is open. Drawn inside the panel — see `MacVoicePickers`.
    @State private var openPicker: MacPickerKind?

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
        VStack(spacing: 0) {
            topBar

            Spacer(minLength: 18)

            VoiceOrb(state: store.state,
                     amplitude: store.state == .listening && store.muted ? 0 : store.amplitude,
                     size: Self.orbSize,
                     animating: onScreen)
                .frame(height: Self.orbSize + 8)
                // The orb is decoration and must never take a click. It draws
                // its shader surface at size / 0.53 — the visible sphere is 53%
                // of it — inside a frame of `size`, and SwiftUI does not clip:
                // the rectangle it hit-tests extends about 55 points past the
                // sphere in every direction, over the row of chips above it.
                // That is what made the session and model pickers dead while the
                // pop-out button, sitting beyond the overhang, worked fine.
                .allowsHitTesting(false)

            Spacer(minLength: 6)

            dialogue
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
                // The reply is a scroll view that follows the segment being
                // spoken, and it will happily draw outside the space it was
                // given — over the transcript sitting above it. The panel is
                // short enough that this is the common case, not the edge one.
                .clipped()

            statusLine
                .padding(.bottom, 6)

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
        .padding(.horizontal, 16)
        .frame(minWidth: Self.minWidth, idealWidth: Self.idealWidth, maxWidth: .infinity,
               minHeight: Self.minHeight, idealHeight: Self.idealHeight, maxHeight: .infinity)
        .background(backdrop)
        .overlay {
            if let kind = openPicker {
                MacPickerSheet(title: kind.title,
                               rows: kind == .session
                                   ? sessionPicker.rows { store.sessionTargetChanged() }
                                   : modelPicker.rows()) {
                    openPicker = nil
                }
            }
        }
        .task {
            // Loaded up front so a chip opens onto its list rather than onto
            // "Loading…" — both are one small request.
            await sessionPicker.load()
            await modelPicker.load()
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
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
        HStack(spacing: 6) {
            // Disabled mid-turn, like the phone's: switching either one under a
            // live turn changes which chat it lands in, or which model finishes
            // answering it.
            MacPickerChip(symbol: "bubble.left", text: sessionPicker.chipLabel,
                          enabled: !store.isActive,
                          accessibilityLabel: "Voice session: \(sessionPicker.chipLabel)") {
openPicker = .session
            }
            MacPickerChip(symbol: "sparkles", text: modelPicker.chipLabel,
                          enabled: !store.isActive,
                          accessibilityLabel: "Voice model: \(modelPicker.chipLabel)") {
                openPicker = .model
            }
            Spacer(minLength: 2)
            if showsOpenInWindow {
                Button {
                    NotificationCenter.default.post(
                        name: Notification.Name(JarvisVoicePanel.openWindowNotificationName),
                        object: nil)
                } label: {
                    Image(systemName: "macwindow")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(JcTheme.muted)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in a window")
                .accessibilityLabel("Open in a window")
            }
        }
        .padding(.top, 4)
    }

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

    /// The state, as a caption above the controls rather than a pill above the
    /// orb.
    ///
    /// It moved for two reasons. It sat directly under the popover's arrow, with
    /// no room between the two; and it said in a label what the headline under
    /// the orb already says in a sentence — "Listening" over "Go ahead, I'm
    /// here." Down here it reads as the status of the buttons beside it, it
    /// fills the space the control hint used to, and it no longer moves when a
    /// reply grows into the middle of the panel.
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
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .thinking: return store.toolStatus ?? "Thinking"
        case .speaking: return "Jarvis is speaking"
        case .error: return "Let's try again"
        }
    }

    /// No control hint line. The phone carries one under its controls ("Tap the
    /// microphone to start", "You can interrupt at any time") because it has a
    /// screen to spend on it; here it was a third line of muted text in a panel
    /// whose three buttons are already labelled Mute / Start / Send.
    @ViewBuilder
    private var dialogue: some View {
        if let failure = store.error, !failure.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(JcTheme.danger)
                VoicePlainReply(text: failure, tint: JcTheme.text)
            }
        } else if !store.replySegments.isEmpty {
            VStack(spacing: 8) {
                if !store.userTranscript.isEmpty {
                    Text(store.userTranscript)
                        .font(.system(size: 11.5))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                VoiceKaraokeReply(segments: store.replySegments, spokenWords: store.spokenWords)
            }
        } else if !store.userTranscript.isEmpty {
            VoicePlainReply(text: store.userTranscript)
        } else {
            // The headline only. The phone pairs it with a subtitle ("Your words
            // will appear here") that describes the empty space below it; in a
            // panel this size that space is a few lines, and saying so twice is
            // most of what is on screen.
            Text(store.state == .idle ? "What's on your mind?" :
                 store.state == .listening ? (store.muted ? "Take your time." : "Go ahead, I'm here.") :
                 store.state == .connecting ? "One moment…" : "Thinking it through…")
                .font(.system(size: 17, weight: .medium))
                .tracking(-0.4)
                .foregroundStyle(JcTheme.text)
                .multilineTextAlignment(.center)
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
