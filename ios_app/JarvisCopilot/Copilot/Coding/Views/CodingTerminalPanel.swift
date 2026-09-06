import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The live terminal: the server PTY's output rendered as monospaced lines, with
/// the console key bar and a raw input row beneath it.
///
/// Flutter fed `/api/terminal/output` into the `xterm` package's `TerminalView`.
/// There is no terminal emulator here and no third-party packages, so
/// `TerminalBuffer` keeps a plain scrollback and this draws it — which is why
/// the panel measures its own viewport and pushes the size to the PTY
/// (`resizeTerminal`) instead of xterm doing it.
struct CodingTerminalPanel: View {
    let session: CodingSessionStore
    var host: String = "server"

    /// A definite height is required inside a ScrollView; this is the Flutter
    /// clamp's middle (`0.42 × screen`, clamped 220…560) without needing the
    /// screen metrics.
    var height: CGFloat = 380

    @State private var viewport = (rows: 0, cols: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            pane
                .frame(height: height)
                .background(CodingUI.pane,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var header: some View {
        HStack {
            Text("LIVE TERMINAL")
                .font(.system(size: 11.5, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(JcTheme.muted)
            Spacer()
            Text("\(host == "desktop" ? "desktop" : "server") · type below")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
            Button { session.detachTerminal() } label: {
                Image(systemName: "xmark.circle").font(.system(size: 15))
                    .foregroundStyle(JcTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Detach terminal")
        }
    }

    @ViewBuilder
    private var pane: some View {
        if let error = session.terminalError, session.terminal.isEmpty {
            VStack(spacing: 6) {
                Text("Terminal unavailable")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(JcTheme.danger)
                Text(error)
                    .font(.system(size: 12)).foregroundStyle(JcTheme.danger.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.terminalStarting && session.terminal.isEmpty {
            ProgressView().tint(JcTheme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // A drop mid-session (a failed keystroke POST, a dead stream) must
                // SAY so — but not by hiding the output the user is reading.
                if let error = session.terminalError { errorStrip(error) }
                lines
            }
        }
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            Text(message).font(.system(size: 11)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(JcTheme.danger)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(JcTheme.danger.opacity(0.12))
    }

    private var lines: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Keyed on the buffer's monotonic ids, not the offset:
                        // once the scrollback cap starts evicting, an offset key
                        // re-identifies every row on screen each frame.
                        ForEach(session.terminal.displayLines) { line in
                            // A blank line still needs a glyph's worth of height,
                            // otherwise a cleared screen collapses to nothing.
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: CodingTerminalPanel.fontSize, design: .monospaced))
                                .foregroundStyle(CodingUI.paneText)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("terminal-bottom")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(6)
                }
                .onChange(of: session.outputTick) { _, _ in
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("terminal-bottom", anchor: .bottom) }
            }
            .onChange(of: geo.size, initial: true) { _, size in resize(to: size) }
        }
    }

    /// Push the rendered size to the PTY, but only when the row/col count really
    /// changed — a resize is a network call and a tmux repaint.
    private func resize(to size: CGSize) {
        let next = CodingUI.terminalViewport(size: size, cell: CodingTerminalPanel.cell)
        guard next != viewport else { return }
        viewport = next
        session.resizeTerminal(rows: next.rows, cols: next.cols)
    }

    static let fontSize: CGFloat = 11.5

    /// One character cell of the monospaced face the pane draws with. Measured
    /// rather than guessed: the system mono's advance is not `fontSize × 0.6`.
    static var cell: CGSize {
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: max(1, width), height: max(1, font.lineHeight))
        #else
        return CGSize(width: fontSize * 0.6, height: fontSize * 1.2)
        #endif
    }
}

// MARK: - Console key bar

/// A fixed 2-row keypad that sends raw key SEQUENCES to the server PTY. It makes
/// the interactive TUI prompts a soft keyboard can't drive usable: selection
/// menus (↑/↓ + Enter, or 1-6), permission boxes, Esc-to-cancel, the ⇧Tab
/// permission-mode cycler, and Ctrl-C. The sequences are standard xterm codings.
struct CodingTerminalKeyBar: View {
    var enabled: Bool = true
    let onKey: (String) -> Void

    /// Arrows use NORMAL cursor-key mode (CSI A/B) — Claude Code's TUI reads
    /// these for menu nav. A TUI that turns on DECCKM would want SS3 instead.
    static let row1: [(String, String)] = [
        ("Esc", "\u{1b}"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("⏎", "\r"), ("^C", "\u{3}"),
    ]
    static let row2: [(String, String)] = [
        ("1", "1"), ("2", "2"), ("3", "3"), ("4", "4"), ("5", "5"), ("6", "6"),
        ("⇥", "\t"), ("⇧⇥", "\u{1b}[Z"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            row(Self.row1)
            row(Self.row2)
        }
        .padding(.horizontal, 13)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func row(_ keys: [(String, String)]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.0) { key in
                Button { onKey(key.1) } label: {
                    Text(key.0)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(JcTheme.surface.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(JcTheme.muted.opacity(0.22), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
            }
        }
    }
}

// MARK: - Raw input row

/// The terminal's own composer: the text bytes then Enter, straight into the
/// PTY (`CodingSessionStore.sendText`) — the same channel the chat composer uses.
struct CodingTerminalInputRow: View {
    let session: CodingSessionStore
    var enabled: Bool = true

    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Type into the terminal…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 15))
                .foregroundStyle(JcTheme.text)
                .padding(.leading, 6)
                .padding(.vertical, 8)
                .disabled(!enabled)
            Button(action: send) {
                Group {
                    if sending {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(canSend ? AnyShapeStyle(JcTheme.blueGradient)
                                    : AnyShapeStyle(JcTheme.glassFill), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(JcTheme.glassFill, in: Capsule())
        .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var canSend: Bool {
        enabled && !sending && !CodingUI.trim(text).isEmpty
    }

    private func send() {
        let body = CodingUI.trim(text)
        guard !body.isEmpty, !sending else { return }
        text = ""
        sending = true
        Task {
            _ = await session.sendText(body)
            sending = false
        }
    }
}
