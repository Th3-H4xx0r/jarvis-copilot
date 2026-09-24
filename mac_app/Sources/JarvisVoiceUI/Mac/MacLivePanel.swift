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
        VStack(spacing: 0) {
            topBar
            statusRow
                .padding(.top, 10)
            notices
            transcript
            controls
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 16)
        .frame(minWidth: MacVoicePanel.minWidth, idealWidth: MacVoicePanel.idealWidth,
               maxWidth: .infinity, minHeight: MacVoicePanel.minHeight,
               idealHeight: MacVoicePanel.idealHeight, maxHeight: .infinity)
        .background(MacPanelBackdrop())
        .task { await store.load() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 6) {
            MacPanelModeSwitch(mode: $mode)
            Spacer(minLength: 2)
            if showsOpenInWindow {
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
        .padding(.top, 4)
    }

    /// Recording or not, for how long, from which mic, heard by whom.
    private var statusRow: some View {
        let split = LiveRecorderStatus.split(store.statusText)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.capturing ? (store.interrupted ? Color.orange : Color.red) : JcTheme.muted)
                    .frame(width: 7, height: 7)
                Text(split.headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                if store.capturing, let started = store.captureStartedAt {
                    // Periodic, never gated on scenePhase: under AppKit that reads
                    // .background forever and the clock would freeze.
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.elapsed(from: started, to: context.date))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(JcTheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            if !hearing.isEmpty {
                Text(hearing)
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            if let detail = split.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hearing: String {
        let who: String
        if !store.serverEngine.isEmpty { who = "\(store.serverEngine) transcribes" }
        else if store.transcribingOnDevice { who = "Transcribed on this Mac" }
        else if store.capturing { who = "Transcribed by the server" }
        else { who = "" }
        return [store.sourceLabel, who].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The store's honest sentences, in the order the phone shows them.
    @ViewBuilder
    private var notices: some View {
        let lines = [store.error, store.serverWarning, store.sttNotice, store.codecNotice, store.spoolWarning]
            .filter { !$0.isEmpty }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .onTapGesture { store.dismissError() }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.timeline.isEmpty && store.partialText.isEmpty && store.committingText.isEmpty {
                        Text(store.capturing
                             ? "Listening…"
                             : "Record to capture the room. What is said appears here as it is heard.")
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    ForEach(store.timeline) { item in
                        switch item {
                        case .turn(let turn): MacLiveTurnRow(turn: turn)
                        case .note(let note): MacLiveNoteRow(note: note)
                        }
                    }
                    if !inProgress.isEmpty {
                        Text(inProgress)
                            .font(.system(size: 13))
                            .foregroundStyle(JcTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.vertical, 10)
            }
            .onChange(of: store.timeline.count) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: store.partialText) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
    }

    /// The words still being heard: the server's partial or the Mac's own.
    private var inProgress: String {
        [store.committingText, store.partialText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let bottom = "live-bottom"

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            // The room's loudness, so a silent mic shows before a silent transcript does.
            GeometryReader { geo in
                Capsule().fill(JcTheme.muted.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.red.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(min(1, max(0, store.level))))
                    }
            }
            .frame(height: 4)
            .opacity(store.capturing ? 1 : 0)

            Button {
                Task {
                    if store.capturing { await store.stop() } else { await store.start() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.capturing ? "stop.fill" : "record.circle")
                        .font(.system(size: 15, weight: .semibold))
                    Text(store.capturing ? "Stop" : (store.preparing ? "Preparing…" : "Record"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Capsule().fill(store.capturing ? Color.red.opacity(0.85) : JcTheme.accent.opacity(0.9)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.preparing)
            .accessibilityLabel(store.capturing ? "Stop recording" : "Record the room")
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// One speaker's run of lines, as the phone groups them.
private struct MacLiveTurnRow: View {
    let turn: LiveTurn

    private var translation: String {
        turn.lines.compactMap { $0.translation }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(LiveFormat.speakerLabel(id: turn.first.speakerID, name: turn.first.speakerName))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
                if let lang = turn.language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(JcTheme.muted)
                }
            }
            Text(turn.text)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 12).italic())
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(turn.notes) { note in MacLiveNoteRow(note: note) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A watcher's note (monitor, fact-check) under the line it is about.
private struct MacLiveNoteRow: View {
    let note: LiveInsight

    var body: some View {
        Text(note.text)
            .font(.system(size: 11))
            .foregroundStyle(JcTheme.muted)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle().fill(JcTheme.accent.opacity(0.5)).frame(width: 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
