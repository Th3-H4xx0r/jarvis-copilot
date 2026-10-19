import AppKit
import XCTest
@testable import Jarvis

/// How smoothly the island opens and folds, per tab (JC_ISLAND_OPEN_HITCH=<report
/// path>): the main thread's worst
/// gap and its CPU while the shape springs, cold (first open) and warm. A gap
/// over a frame or two is what shows as a stutter.
@MainActor
final class IslandOpenHitchTests: XCTestCase {

    func testOpenAndCloseWithoutStalling() throws {
        let env = ProcessInfo.processInfo.environment
        guard let report = env["JC_ISLAND_OPEN_HITCH"] else {
            throw XCTSkip("set JC_ISLAND_OPEN_HITCH to measure the island opening and folding")
        }
        let model = AppModel()
        model.attach()                                  // real sessions and limits, like his
        // How often jc-client pushes while it measures (each push re-renders the island).
        var pushes: [String: (count: Int, ms: Double)] = [:]
        JcLink.shared.onMessage = { msg in
            let t = CACurrentMediaTime()
            model.handle(msg)
            let p = pushes[J.s(msg["type"])] ?? (0, 0)
            pushes[J.s(msg["type"])] = (p.count + 1, p.ms + (CACurrentMediaTime() - t) * 1000)
        }
        let c = IslandController(model: model)
        // The tabs a click on the notch opens (Voice is the orb's, and starts the mic).
        let tabs: [IslandTab] = [.agents, .chat, .music]
        // A chat that's been used for a while.
        MacChatStore.shared.showDemo((0..<24).map { i in
            ("Question \(i): how do I make the island smoother when it opens?",
             "## Step \(i)\n\nHere is a paragraph with **bold**, `code` and a [link](https://example.com).\n\n"
                + "- one point\n- another point\n- a third\n\n```swift\nlet x = \(i)\nprint(x * 2)\n```\n\nDone.")
        })
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        c.activity()
        wait(1.5)

        var lines: [String] = []
        func measure(_ label: String, _ action: () -> Void) {
            pushes = [:]
            var ticks: [CFTimeInterval] = []
            // When the shape starts to move (an open builds first, then springs).
            let before = c.ui.state
            var springAt: CFTimeInterval?
            let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
                let now = CACurrentMediaTime()
                ticks.append(now)
                if springAt == nil, c.ui.state != before { springAt = now }
            }
            RunLoop.main.add(timer, forMode: .common)
            wait(0.15)
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let t0 = CACurrentMediaTime()
            action()
            let call = (CACurrentMediaTime() - t0) * 1000
            wait(0.8)
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1_000_000
            timer.invalidate()
            let during = [t0] + ticks.filter { $0 > t0 && $0 <= t0 + 0.7 }
            let gaps = zip(during.dropFirst(), during).map { (at: ($1 - t0) * 1000, ms: ($0 - $1) * 1000) }
            let worst = gaps.map(\.ms).max() ?? 0
            let stalls = gaps.filter { $0.ms > 20 }.map { String(format: "%.0f@+%.0f", $0.ms, $0.at) }
            let pushed = pushes.sorted { $0.key < $1.key }
                .map { String(format: "%@×%d (%.1f ms)", $0.key, $0.value.count, $0.value.ms) }.joined(separator: " ")
            // What the eye sees: the gaps once the shape moves.
            let start = springAt ?? t0
            let moving = gaps.filter { $0.at >= (start - t0) * 1000 && $0.at <= (start - t0) * 1000 + 600 }
            lines.append(String(format: "%@: call %.1f ms, springs at +%.0f ms, worst gap while moving %.0f ms, worst gap %.0f ms, main CPU %.0f ms; stalls %@; pushes %@",
                                label, call, (start - t0) * 1000, moving.map(\.ms).max() ?? 0, worst, cpu,
                                stalls.isEmpty ? "none" : stalls.joined(separator: " "), pushed.isEmpty ? "none" : pushed))
        }

        measure("idle (baseline)") {}
        for tab in tabs {
            for round in 0..<3 {
                measure("\(tab) open #\(round)") { c.ui.tab = tab; c.toggle() }
                measure("\(tab) close #\(round)") { c.close() }
            }
        }
        // One agent event: jc-client pushes the whole session list on each hook.
        var sessionsPush: [String: Any]?
        JcLink.shared.request(["type": "sessions"]) { reply in
            sessionsPush = ["type": "sessions", "sessions": reply["sessions"] ?? []]
        }
        wait(1)
        if let msg = sessionsPush {
            let bytes = (try? JSONSerialization.data(withJSONObject: msg).count) ?? 0
            lines.append("sessions push: \((msg["sessions"] as? [Any])?.count ?? 0) sessions, \(bytes / 1024) KB")
            for round in 0..<3 {
                measure("push while folded #\(round)") { model.handle(msg) }
            }
            c.ui.tab = .agents
            c.toggle()
            wait(1)
            for round in 0..<3 {
                measure("push while open on Agents #\(round)") { model.handle(msg) }
            }
            c.close()
        }
        try lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }

    /// What the folded pill costs while it just sits there (JC_ISLAND_IDLE_COST=<report
    /// path>): the main thread's share with no agents, and with one working.
    func testFoldedIslandIdleCost() throws {
        guard let report = ProcessInfo.processInfo.environment["JC_ISLAND_IDLE_COST"] else {
            throw XCTSkip("set JC_ISLAND_IDLE_COST to measure the folded island at rest")
        }
        let model = AppModel()
        model.demoActive = true                         // only the sessions set here, none of jc-client's
        model.attach()                                  // connected, or the orb never shows a mood
        let c = IslandController(model: model)
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        wait(1.5)
        func mainShare(over s: Double) -> String {
            let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            wait(s)
            return String(format: "%.1f%% of the main thread", Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0) / 1e7 / s)
        }
        var lines: [String] = []
        c.activity()
        wait(1)
        lines.append("pill, no agents: " + mainShare(over: 3))
        for state in ["working", "approval", "idle"] {
            model.apply(sessions: [["key": "k", "agent": "claude", "state": state, "cwd": "/tmp/demo",
                                    "last_event_at": Date().timeIntervalSince1970]], announce: false)
            c.activity()
            wait(1)
            lines.append("pill, one agent \(state): " + mainShare(over: 3))
        }
        model.apply(sessions: [], announce: false)
        wait(1)
        lines.append("pill, no agents again: " + mainShare(over: 3))
        try lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }
}
