import AppKit
import SwiftUI

/// The orb, loose on the desktop: a small floating window you can drag
/// anywhere; it keeps its place across launches, shows the agents' mood, and a
/// click opens the island. Turned on in Settings or with ⌃⌥D.
@MainActor
final class DesktopOrbController {
    private var panel: NSPanel?
    private let model: AppModel
    private let island: IslandController
    private var moveObserver: NSObjectProtocol?

    init(model: AppModel, island: IslandController) {
        self.model = model
        self.island = island
        if Prefs.desktopOrb { show() }
    }

    func toggle() {
        Prefs.desktopOrb.toggle()
        sync()
    }

    func sync() {
        if Prefs.desktopOrb { show() } else { hide() }
    }

    private func show() {
        guard panel == nil else { return }
        let size: CGFloat = 120
        let origin = Prefs.desktopOrbOrigin ?? {
            let f = NSScreen.main?.visibleFrame ?? .zero
            return CGPoint(x: f.maxX - size - 40, y: f.minY + 80)
        }()
        let p = NSPanel(contentRect: NSRect(origin: origin, size: CGSize(width: size, height: size)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: DesktopOrbView(model: model) { [weak self] in
            self?.island.toggle()
        })
        p.orderFrontRegardless()
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p,
                                                              queue: .main) { [weak p] _ in
            MainActor.assumeIsolated {
                if let p { Prefs.desktopOrbOrigin = p.frame.origin }
            }
        }
        panel = p
    }

    private func hide() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct DesktopOrbView: View {
    let model: AppModel
    let tap: () -> Void

    var body: some View {
        OrbView(mood: model.mood, skin: OrbSkin.current, size: 72)
            .frame(width: 120, height: 120)
            .overlay(alignment: .topTrailing) {
                if model.waitingCount > 0 {
                    Text("\(model.waitingCount)")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.98, green: 0.75, blue: 0.14)))
                        .padding(18)
                }
            }
            .contentShape(Circle())
            .onTapGesture(perform: tap)
            .help("Jarvis — \(model.sessions.count) agent session\(model.sessions.count == 1 ? "" : "s")")
    }
}

/// A scripted tour with made-up sessions: a session working through steps, an
/// approval, a question, a finish. Nothing is sent anywhere; the real state
/// comes back when it ends.
@MainActor
enum DemoEngine {
    static func run(model: AppModel, island: IslandController) {
        model.demoActive = true
        let now = Date().timeIntervalSince1970
        func session(_ key: String, _ project: String, _ state: String, _ step: String,
                     pending: String? = nil) -> [String: Any] {
            var s: [String: Any] = ["key": key, "agent": "claude", "session_id": key, "cwd": "/Users/demo/\(project)",
                                    "project": project, "state": state, "step": step,
                                    "steps": [["t": "Read package.json"], ["t": step]],
                                    "started_at": now - 120, "last_event_at": now,
                                    "terminal": ["bundle_id": "com.apple.Terminal"],
                                    "turn": ["prompt": "Make the tests pass", "files": [
                                        ["path": "/Users/demo/\(project)/src/app.ts", "added": 4, "removed": 1,
                                         "lines": [["k": "-", "t": "const x = 1"], ["k": "+", "t": "const x = 2"]]]]]]
            if let pending { s["pending"] = ["kind": "approval", "fingerprint": pending] }
            return s
        }
        let steps: [(TimeInterval, () -> Void)] = [
            (0, { model.setDemo(sessions: [session("d1", "storefront", "working", "Bash: npm test")], pending: []); island.attention() }),
            (3, { model.setDemo(sessions: [session("d1", "storefront", "working", "Edit app.ts"),
                                          session("d2", "api", "thinking", "Thinking…")], pending: []) }),
            (6, { model.setDemo(sessions: [session("d1", "storefront", "approval", "Needs approval: Bash", pending: "demo-fp"),
                                          session("d2", "api", "working", "Grep TODO")],
                                pending: [["fingerprint": "demo-fp", "kind": "permission", "agent": "claude",
                                           "key": "d1", "cwd": "/Users/demo/storefront", "tool": "Bash",
                                           "summary": "Bash: rm -rf dist", "command": "rm -rf dist", "can_always": true]]) }),
            (12, { model.setDemo(sessions: [session("d1", "storefront", "finished", "All 42 tests pass."),
                                           session("d2", "api", "question", "Which database?")],
                                 pending: [["fingerprint": "demo-q", "kind": "ask", "agent": "claude", "key": "d2",
                                            "cwd": "/Users/demo/api", "questions": [[
                                                "question": "Which database?", "multiSelect": false,
                                                "options": [["label": "Postgres"], ["label": "SQLite"]]]]]]) }),
            (17, {
                MacChatStore.shared.showDemo([("Why did CI fail on storefront#42?",
                                               "The **api** tests need `STRIPE_KEY`; it isn't set in the CI env.")])
                island.open(.chat)
            }),
            (22, {
                model.endDemo()
                MacChatStore.shared.endDemo()
                island.open(.agents)
            }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() }
        }
    }
}
