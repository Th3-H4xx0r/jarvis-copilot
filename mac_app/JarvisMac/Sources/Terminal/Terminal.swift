import AppKit

/// "Jump to terminal": bring the app a session runs in to the front — and the
/// exact iTerm session or Terminal tab when the hooks told us which one.
/// After coucou's TerminalTarget / ClaudeHost (github.com/Louis-CFM/coucou, MIT).
enum TerminalTarget {
    static let knownTerminals = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty", "com.cmuxterm.app", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "org.alacritty", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    ]

    private static let byTermProgram = [
        "apple_terminal": "com.apple.Terminal", "iterm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty", "kitty": "net.kovidgoyal.kitty",
        "warpterminal": "dev.warp.Warp-Stable", "wezterm": "com.github.wez.wezterm",
        "vscode": "com.microsoft.VSCode", "zed": "dev.zed.Zed",
    ]

    static func candidates(sessionBundleId: String?) -> [String] {
        let own = sessionBundleId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !own.isEmpty else { return knownTerminals }
        return [own] + knownTerminals.filter { $0 != own }
    }

    static func pick(sessionBundleId: String?, running: Set<String>) -> String? {
        candidates(sessionBundleId: sessionBundleId).first { running.contains($0) }
    }

    static func bundleId(for session: MacSession) -> String {
        if !session.terminalBundleId.isEmpty { return session.terminalBundleId }
        return byTermProgram[session.termProgram.lowercased()] ?? ""
    }

    @MainActor
    @discardableResult
    static func activate(session: MacSession?) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        let running = Set(apps.compactMap(\.bundleIdentifier))
        let wanted = session.map(bundleId(for:))
        guard let id = pick(sessionBundleId: wanted, running: running),
              let app = apps.first(where: { $0.bundleIdentifier == id }) else { return false }
        app.activate()
        if let session { focusTab(session, bundleId: id) }
        return true
    }

    /// iTerm: select the session whose unique id the hook saw (ITERM_SESSION_ID
    /// is "w0t1p0:UUID"). Terminal: the tab whose tty matches. Best effort.
    private static func focusTab(_ session: MacSession, bundleId: String) {
        var script: String?
        if bundleId == "com.googlecode.iterm2", let uuid = session.itermSession.split(separator: ":").last {
            script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if unique id of s is "\(escape(String(uuid)))" then
                      select w
                      select t
                      select s
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        }
        guard let script else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    /// Text placed inside an AppleScript string literal.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
