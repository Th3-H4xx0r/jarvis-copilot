import SwiftUI

/// A background session's real terminal (`claude attach` in a server PTY), for
/// slash commands and Claude's menus — the chat stays the main surface. The
/// screen is the web's xterm page (`/static/agents_terminal.html`) in a
/// `WKWebView`, so Claude's full-screen redraws come out right; it boots
/// authenticated the same way the embedded server tabs do (`ServerWebView`).
/// The key bar underneath sends the keys a phone keyboard lacks.
struct AgentTerminalView: View {
    let ckey: String
    let title: String
    let api: AgentsAPI

    @Environment(\.dismiss) private var dismiss
    @State private var terminalId: String?
    @State private var error: String?
    @State private var progress: Double = 0
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    VStack(spacing: 14) {
                        CodingInlineError(message: error)
                        Button("Try again") { Task { await start() } }
                            .buttonStyle(.jcGlass(tint: JcTheme.accent))
                    }
                    .padding(20)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else if let terminalId, let url = Self.pageURL(terminalId: terminalId,
                                                                  base: BridgeClient.shared.apiBaseURL()) {
                    if isLoading {
                        ProgressView(value: max(progress, 0.02))
                            .progressViewStyle(.linear)
                            .tint(JcTheme.accent)
                    }
                    ServerWebView(url: url, headers: BridgeClient.shared.apiAuthHeaders(),
                                  progress: $progress, isLoading: $isLoading)
                        .background(AgentPane.pane)
                    AgentTerminalKeyBar { key in
                        Task { try? await api.terminalInput(terminalId, data: key) }
                    }
                    .background(JcTheme.bg)
                } else {
                    ProgressView()
                        .tint(JcTheme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(AgentPane.pane.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(JcTheme.accent)
                }
            }
        }
        .task { await start() }
        .onDisappear {
            // Detach only: the session keeps running on the server.
            if let id = terminalId { Task { await api.terminalClose(id) } }
        }
    }

    private func start() async {
        error = nil
        let size = UIScreen.main.bounds.size
        // A first guess at the grid; the page fits it to the view and resizes.
        let cols = max(40, Int(size.width / 7.4))
        let rows = max(16, Int((size.height - 220) / 15))
        do {
            terminalId = try await api.terminalStart(ckey: ckey, rows: rows, cols: cols)
        } catch {
            if !wasCancelled(error) { self.error = apiErrorMessage(error) }
        }
    }

    /// `<server>/static/agents_terminal.html?terminal_id=<id>`.
    static func pageURL(terminalId: String, base: URL?) -> URL? {
        guard let base else { return nil }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let root = (comps?.path ?? "").hasSuffix("/") ? String((comps?.path ?? "").dropLast()) : (comps?.path ?? "")
        comps?.path = root + "/static/agents_terminal.html"
        comps?.queryItems = [URLQueryItem(name: "terminal_id", value: terminalId)]
        return comps?.url
    }
}

/// Two rows of keys a soft keyboard can't type, sent as raw sequences to the
/// PTY: Claude's menus (↑/↓ + Enter, or 1-6), Esc to cancel, ⇧Tab to cycle the
/// permission mode, and Ctrl-C. Lifted from the old Coding terminal.
struct AgentTerminalKeyBar: View {
    var enabled: Bool = true
    let onKey: (String) -> Void

    /// Arrows use normal cursor-key mode (CSI A/B), which Claude Code reads.
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
                        .frame(height: 40)
                        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
                .accessibilityLabel(Self.spoken(key.0))
            }
        }
    }

    private static func spoken(_ label: String) -> String {
        switch label {
        case "↑": return "Up"
        case "↓": return "Down"
        case "⏎": return "Return"
        case "^C": return "Control C"
        case "⇥": return "Tab"
        case "⇧⇥": return "Shift Tab"
        case "Esc": return "Escape"
        default: return label
        }
    }
}
