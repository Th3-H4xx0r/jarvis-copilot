import AppKit
import SwiftUI

/// Live on the Mac: the phone's `LiveStore` — the same capture, socket, spool,
/// transcript and speaker labels — at menubar-panel size.
///
/// Like `MacVoicePanel`, this is only the frame. Everything it shows comes from
/// the shared store the phone's Live screen reads; what the phone draws with its
/// glass design system (settings, sessions, speakers, storage) stays on the
/// phone and the web, and this panel keeps to what a 320-point popover can
/// carry: the state, the words as they are heard, and Record.
struct MacLivePanel: View {
    @Binding var mode: MacPanelMode
    let showsOpenInWindow: Bool
    @State private var store: LiveStore

    init(mode: Binding<MacPanelMode>, showsOpenInWindow: Bool) {
        _mode = mode
        self.showsOpenInWindow = showsOpenInWindow
        _store = State(initialValue: MainActor.assumeIsolated { LiveStore.shared })
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                MacPanelModeSwitch(mode: $mode)
                Spacer(minLength: 2)
                if showsOpenInWindow { MacOpenInWindowButton() }
            }
            .padding(.top, 4)
            header
            warnings
            transcript
            recordButton
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 16)
        .frame(minWidth: MacVoicePanel.minWidth, idealWidth: MacVoicePanel.idealWidth,
               maxWidth: .infinity, minHeight: MacVoicePanel.minHeight,
               idealHeight: MacVoicePanel.idealHeight, maxHeight: .infinity)
        .background(MacPanelBackdrop())
        .task { await store.load() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    /// State, clock and the room's level on one line; the mic and who hears it
    /// under it — a recorder's display, on the same glass as the voice controls.
    private var header: some View {
        let headline = LiveRecorderStatus.split(store.statusText).headline
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(store.capturing ? (store.interrupted ? Color.orange : Self.red)
                                                     : JcTheme.muted.opacity(0.6))
                    .symbolEffect(.pulse, options: .repeating, isActive: store.capturing && !store.interrupted)
                Text(headline)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if store.capturing {
                    MacLevelBars(level: store.level)
                    if let started = store.captureStartedAt {
                        // Periodic, never gated on scenePhase: under AppKit that
                        // reads .background forever and the clock would freeze.
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(Self.elapsed(from: started, to: context.date))
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(JcTheme.text.opacity(0.85))
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Label(store.sourceLabel.isEmpty ? "Default microphone" : store.sourceLabel,
                      systemImage: "mic")
                    .lineLimit(1)
                if let heard = heardBy {
                    Label(heard, systemImage: "waveform")
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(JcTheme.muted)
            .labelStyle(MacQuietLabelStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var heardBy: String? {
        if !store.serverEngine.isEmpty { return store.serverEngine }
        if store.transcribingOnDevice { return "This Mac" }
        return store.capturing ? "Server" : nil
    }

    /// Problems only, and quietly: the engine's "is transcribing" note is what
    /// the header already says.
    @ViewBuilder
    private var warnings: some View {
        let problems = [store.error, store.serverWarning, store.codecNotice, store.spoolWarning]
            .filter { !$0.isEmpty }
        let info = store.serverEngine.isEmpty ? store.sttNotice : ""
        if !problems.isEmpty || !info.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(problems, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                }
                if !info.isEmpty {
                    Label(info, systemImage: "info.circle")
                        .foregroundStyle(JcTheme.muted)
                }
            }
            .font(.system(size: 11))
            .labelStyle(MacQuietLabelStyle())
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(problems.isEmpty ? JcTheme.muted.opacity(0.08) : Color.orange.opacity(0.10)))
            .contentShape(Rectangle())
            .onTapGesture { store.dismissError() }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        let speakers = MacLiveSpeakers.labels(store.timeline)
        let primary = store.config.primaryLanguage
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.timeline.isEmpty && inProgress.isEmpty { emptyState }
                    ForEach(store.timeline) { item in
                        switch item {
                        case .turn(let turn):
                            MacLiveTurnRow(turn: turn,
                                           speaker: speakers[turn.speakerKey],
                                           language: MacLiveLanguage.badge(turn.language, primary: primary))
                        case .note(let note):
                            MacLiveNoteRow(note: note)
                        }
                    }
                    if !inProgress.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(JcTheme.accent)
                                .symbolEffect(.variableColor.iterative, options: .repeating)
                            Text(inProgress)
                                .font(.system(size: 13))
                                .foregroundStyle(JcTheme.text.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .onChange(of: store.timeline.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: store.partialText) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                     .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(JcTheme.accent.opacity(0.8))
            Text(store.capturing ? "Listening" : "Capture the room")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Text(store.capturing
                 ? "Words appear here as they are heard."
                 : "Record a conversation. Jarvis transcribes it, tells the voices apart and translates what is not in your language.")
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
        .padding(.horizontal, 12)
    }

    /// The words still being heard: the server's partial or the Mac's own.
    private var inProgress: String {
        [store.committingText, store.partialText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let bottom = "live-bottom"
    private static let red = Color(jcHex: 0xFF5A5F)

    // MARK: - Record

    /// The voice panel's primary control, as Live's: a glass disc with the glyph
    /// in colour and the word under it.
    private var recordButton: some View {
        Button {
            Task { if store.capturing { await store.stop() } else { await store.start() } }
        } label: {
            VStack(spacing: VoiceControlMetrics.stackSpacing) {
                Image(systemName: store.capturing ? "stop.fill" : "record.circle")
                    .font(.system(size: store.capturing ? 17 : VoiceControlMetrics.micIcon + 2,
                                  weight: .medium))
                    .foregroundStyle(store.capturing ? Self.red : JcTheme.accent)
                    .frame(width: VoiceControlMetrics.micDiameter, height: VoiceControlMetrics.micDiameter)
                    .jcLiquidGlass(in: Circle(), tint: store.capturing ? Self.red.opacity(0.18) : .clear)
                Text(store.capturing ? "Stop" : (store.preparing ? "Preparing…" : "Record"))
                    .font(.system(size: VoiceControlMetrics.labelSize, weight: .medium))
                    .foregroundStyle(JcTheme.text)
            }
            .frame(width: VoiceControlMetrics.micSlot)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.preparing)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(store.capturing ? "Stop recording" : "Record the room")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        clock(ms: Int(now.timeIntervalSince(start) * 1000))
    }

    static func clock(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Five bars that follow the room's loudness — a recorder's meter, not a bar
/// across the panel.
struct MacLevelBars: View {
    let level: Double
    private static let shape: [Double] = [0.55, 0.85, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.shape.indices, id: \.self) { i in
                Capsule()
                    .fill(JcTheme.accent.opacity(0.9))
                    .frame(width: 2.5, height: 3 + 9 * CGFloat(min(1, max(0, level)) * Self.shape[i]))
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// An icon and a short text, close together, in the text's colour.
struct MacQuietLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.font(.system(size: 10, weight: .medium))
            configuration.title
        }
    }
}

/// Speakers numbered in the order they first speak here, their name once one
/// is known, and a steady colour each. (The phone numbers from the voice id's
/// digits, which is stable across merges but reads as "Speaker 4163".)
enum MacLiveSpeakers {
    struct Label: Equatable {
        var name: String
        var index: Int
    }

    static let palette: [Color] = [JcTheme.accent, Color(jcHex: 0xF5A76C), Color(jcHex: 0xB79CFF),
                                   Color(jcHex: 0x7FD49B), Color(jcHex: 0xFF8FB1), Color(jcHex: 0x8EC5FF)]

    static func labels(_ timeline: [LiveTimelineItem]) -> [String: Label] {
        var out: [String: Label] = [:]
        for case .turn(let turn) in timeline {
            let key = turn.speakerKey
            let name = (turn.lines.compactMap(\.speakerName).first { !$0.isEmpty } ?? "")
                .trimmingCharacters(in: .whitespaces)
            if var known = out[key] {
                if !name.isEmpty { known.name = name; out[key] = known }
            } else {
                let index = out.count
                out[key] = Label(name: name.isEmpty ? "Speaker \(index + 1)" : name, index: index)
            }
        }
        return out
    }

    static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

/// A language badge only where it tells you something: a line not in your own
/// language, by name ("Telugu", not "te").
enum MacLiveLanguage {
    static func badge(_ lang: String?, primary: String) -> String? {
        let code = base(lang)
        guard !code.isEmpty, code != base(primary) else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    static func base(_ tag: String?) -> String {
        String((tag ?? "").replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first ?? "").lowercased()
    }
}

/// One speaker's run of lines, as the phone groups them.
struct MacLiveTurnRow: View {
    let turn: LiveTurn
    let speaker: MacLiveSpeakers.Label?
    let language: String?

    private var translation: String {
        turn.lines.compactMap { $0.translation }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        let tint = MacLiveSpeakers.color(speaker?.index ?? 0)
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(tint.opacity(0.85))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(speaker?.name ?? "Speaker")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tint)
                    if let language {
                        Text(language)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(JcTheme.text.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(JcTheme.muted.opacity(0.2)))
                    }
                    Spacer(minLength: 4)
                    Text(MacLivePanel.clock(ms: turn.startMs))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(JcTheme.muted.opacity(0.8))
                }
                Text(turn.text)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.text)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.text.opacity(0.6))
                        .italic()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(turn.notes) { note in MacLiveNoteRow(note: note) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A watcher's note (monitor, fact-check): a quiet card with a sparkle.
struct MacLiveNoteRow: View {
    let note: LiveInsight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(JcTheme.accent)
            Text(note.text)
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.text.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(JcTheme.accent.opacity(0.07)))
    }
}

/// Which surface the panel shows. Remembered, so the panel reopens where it was.
enum MacPanelMode: String {
    case voice, live
}

/// Voice | Live, at the left of either panel's top bar.
struct MacPanelModeSwitch: View {
    @Binding var mode: MacPanelMode

    var body: some View {
        HStack(spacing: 2) {
            segment("Voice", .voice)
            segment("Live", .live)
        }
        .padding(2)
        .background(Capsule().fill(JcTheme.muted.opacity(0.14)))
        // Never squeezed: a row short of width takes it from the text, and the
        // switch showed as an empty capsule.
        .fixedSize()
    }

    private func segment(_ title: String, _ value: MacPanelMode) -> some View {
        Button { mode = value } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(mode == value ? JcTheme.text : JcTheme.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(mode == value ? JcTheme.accent.opacity(0.28) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) mode")
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }
}

/// The pop-out: a corner icon that asks the tray (by notification, which crosses
/// the Python bridge without either side handing the other a function) to open
/// the panel in a window.
struct MacOpenInWindowButton: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: Notification.Name(JarvisVoicePanel.openWindowNotificationName), object: nil)
        } label: {
            Image(systemName: "macwindow")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(JcTheme.accent)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in a window")
        .accessibilityLabel("Open in a window")
    }
}

/// The phone's aurora ground, as both Mac panels draw it.
struct MacPanelBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(jcHex: 0x0A0C12), Color(jcHex: 0x050608)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Circle()
                    .fill(RadialGradient(
                        colors: [JcAccent.deep.opacity(0.10), JcAccent.deep.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 170))
                    .frame(width: 340, height: 340)
                    .offset(y: -60)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }
}
