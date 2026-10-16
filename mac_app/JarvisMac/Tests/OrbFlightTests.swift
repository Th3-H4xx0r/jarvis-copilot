import XCTest
import AppKit
import AVFoundation
import CoreAudio
import QuartzCore
import SwiftUI
@testable import Jarvis

/// The notch's small orb flies into the open island and becomes its big orb
/// (Voice's on the stage, the Agents header's, or the tab row's) — and back
/// into the notch when the island folds.
final class OrbFlightTests: XCTestCase {
    private let ear = CGRect(x: 168, y: 7, width: 23, height: 23)
    private let stage = CGRect(x: 324, y: 104, width: 72, height: 72)

    func testEachTabHasItsOrbHome() {
        XCTAssertEqual(OrbHome.of(.voice), .voice)
        XCTAssertEqual(OrbHome.of(.agents), .agents)
        for tab in [IslandTab.chat, .services, .music, .mail] {
            XCTAssertEqual(OrbHome.of(tab), .row, "\(tab) keeps its orb in the tab row")
        }
    }

    func testOnlyTheNotchAndTheOpenIslandTradeTheOrb() {
        XCTAssertEqual(OrbFlightPlan.direction(from: .compact, to: .expanded, reduceMotion: false), .out)
        XCTAssertEqual(OrbFlightPlan.direction(from: .expanded, to: .compact, reduceMotion: false), .back)
        XCTAssertNil(OrbFlightPlan.direction(from: .hidden, to: .expanded, reduceMotion: false), "no orb in the notch to fly")
        XCTAssertNil(OrbFlightPlan.direction(from: .expanded, to: .hidden, reduceMotion: false))
        XCTAssertNil(OrbFlightPlan.direction(from: .compact, to: .expanded, reduceMotion: true), "Reduce Motion: no flight")
    }

    func testThePathRunsFromTheEarToHome() {
        let start = OrbPath.at(0, ear: ear, home: stage)
        XCTAssertEqual(start.center.x, ear.midX, accuracy: 0.001)
        XCTAssertEqual(start.center.y, ear.midY, accuracy: 0.001)
        XCTAssertEqual(start.side, ear.width, accuracy: 0.001)
        let end = OrbPath.at(1, ear: ear, home: stage)
        XCTAssertEqual(end.center.x, stage.midX, accuracy: 0.001)
        XCTAssertEqual(end.center.y, stage.midY, accuracy: 0.001)
        XCTAssertEqual(end.side, stage.width, accuracy: 0.001)
    }

    func testItDropsOutOfTheNotchBeforeItGlides() {
        let early = OrbPath.at(0.25, ear: ear, home: stage)
        XCTAssertGreaterThan(early.center.y - ear.midY, abs(early.center.x - ear.midX) * 3)
    }

    /// The spring carries it a little past home: it swells, but stays put.
    func testLandingPopsInSizeNotPlace() {
        let past = OrbPath.at(1.06, ear: ear, home: stage)
        XCTAssertGreaterThan(past.side, stage.width)
        XCTAssertLessThan(past.side, stage.width * 1.08)
        XCTAssertEqual(past.center.x, stage.midX, accuracy: 0.001)
        XCTAssertEqual(past.center.y, stage.midY, accuracy: 0.001)
    }

    func testTheGlowLightsMidFlightOnly() {
        XCTAssertEqual(OrbPath.glow(0), 0, accuracy: 0.001)
        XCTAssertEqual(OrbPath.glow(1), 0, accuracy: 0.001)
        XCTAssertEqual(OrbPath.glow(1.05), 0, accuracy: 0.001)
        XCTAssertGreaterThan(OrbPath.glow(0.5), OrbPath.glow(0.2))
    }

    /// Opening: the ear and home orbs step aside while the flying one travels;
    /// it waits for home's first layout before it sets off, then lands.
    @MainActor
    func testOpeningWaitsForHomeThenFliesAndLands() {
        let ui = IslandUI()
        ui.orbEar = ear
        ui.tab = .agents
        ui.flyOrb(.out)
        XCTAssertEqual(ui.orbFlight?.home, .agents)
        XCTAssertEqual(ui.orbFlight?.launched, false, "home isn't laid out yet")
        XCTAssertTrue(ui.hidesEar)
        XCTAssertTrue(ui.hidesOrb(.agents))
        XCTAssertFalse(ui.hidesOrb(.row))
        ui.reportOrbHome(.agents, CGRect(x: 96, y: 90, width: 22, height: 22))
        XCTAssertEqual(ui.orbFlight?.launched, true)
        XCTAssertEqual(ui.orbProgress, 1)
        ui.landOrb(serial: ui.orbFlight!.serial)
        XCTAssertNil(ui.orbFlight)
        XCTAssertFalse(ui.hidesEar)
        XCTAssertFalse(ui.hidesOrb(.agents))
    }

    /// Folding flies it back from where it sat — even though the tab then
    /// changes (Voice folds back to the last tab).
    @MainActor
    func testFoldingFliesBackFromWhereItSat() {
        let ui = IslandUI()
        ui.orbEar = ear
        var hidden: [Bool] = []
        ui.setVoiceOrbHidden = { hidden.append($0); return true }
        ui.reportOrbHome(.voice, stage)
        ui.tab = .voice
        ui.flyOrb(.back)
        ui.tab = .agents
        XCTAssertEqual(ui.orbFlight?.from, stage)
        XCTAssertEqual(ui.orbProgress, 0)
        XCTAssertEqual(hidden, [true], "the stage's own orb steps aside")
        ui.landOrb(serial: ui.orbFlight!.serial)
        XCTAssertNil(ui.orbFlight)
        XCTAssertEqual(hidden, [true, false])
    }

    /// Each flight leaves from where the last one left the orb — never from a
    /// reset in the same update as its spring (that made every open after the
    /// first, and every fold, jump instead of fly).
    @MainActor
    func testEveryFlightLeavesFromWhereTheLastLeftIt() {
        let ui = IslandUI()
        ui.orbEar = ear
        ui.reportOrbHome(.agents, CGRect(x: 96, y: 90, width: 22, height: 22))
        ui.tab = .agents
        for _ in 0..<3 {
            XCTAssertEqual(ui.orbProgress, 0, "folded: the orb is in the notch")
            ui.flyOrb(.out)
            XCTAssertEqual(ui.orbFlight?.launched, true)
            XCTAssertEqual(ui.orbProgress, 1)
            ui.landOrb(serial: ui.orbFlight!.serial)
            ui.flyOrb(.back)
            XCTAssertEqual(ui.orbFlight?.direction, .back)
            XCTAssertEqual(ui.orbProgress, 0)
            ui.landOrb(serial: ui.orbFlight!.serial)
        }
    }

    /// Opened or folded without a flight, the orb rests where that state keeps it,
    /// so the next flight starts from the right end.
    @MainActor
    func testWithoutAFlightTheOrbRestsWhereTheStateKeepsIt() {
        let ui = IslandUI()
        ui.restOrb(open: true)
        XCTAssertEqual(ui.orbProgress, 1)
        ui.restOrb(open: false)
        XCTAssertEqual(ui.orbProgress, 0)
        ui.orbEar = ear
        ui.tab = .chat
        ui.flyOrb(.out)
        ui.restOrb(open: false)
        XCTAssertNil(ui.orbFlight, "a fold to hidden ends the flight")
    }

    /// An older voice panel (no orb hand-off) opens without a flight rather
    /// than showing two orbs.
    @MainActor
    func testNoFlightIntoAPanelThatCantHideItsOrb() {
        let ui = IslandUI()
        ui.orbEar = ear
        ui.tab = .voice
        ui.setVoiceOrbHidden = { _ in false }
        ui.flyOrb(.out)
        XCTAssertNil(ui.orbFlight)
        ui.setVoiceOrbHidden = nil
        ui.flyOrb(.out)
        XCTAssertNil(ui.orbFlight)
    }

    /// Never seen the notch (it opened from hidden): nothing to fly from.
    @MainActor
    func testNoFlightWithoutTheEar() {
        let ui = IslandUI()
        ui.tab = .agents
        ui.flyOrb(.out)
        XCTAssertNil(ui.orbFlight)
    }

    /// A home that never lays out (the tab failed to appear) gives up and puts
    /// the orbs back rather than leaving the island orbless.
    @MainActor
    func testAFlightWithNoHomeGivesUp() {
        let ui = IslandUI()
        ui.orbEar = ear
        ui.tab = .chat
        ui.flyOrb(.out)
        let serial = ui.orbFlight!.serial
        ui.abandonOrbFlight(serial: serial)
        XCTAssertNil(ui.orbFlight)
    }

    /// The real island on the real notch, opened and folded a few times — the
    /// orb must fly every time, both ways. Runs only with JC_ISLAND_LIVE=<marker
    /// path> (and JC_VOICE_DYLIB / JC_API_ORIGIN for Voice): it writes the marker,
    /// gives a screen recorder a moment to start, then plays the sequence.
    @MainActor
    func testLiveFlightsOnTheNotch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let marker = env["JC_ISLAND_LIVE"] else { throw XCTSkip("set JC_ISLAND_LIVE to fly the orb on the notch") }
        let model = AppModel()
        model.attach()                                  // connected: the pill stays up
        let c = IslandController(model: model)
        let menu = JarvisMenu(model: model, island: c)
        if let dylib = env["JC_VOICE_DYLIB"], let api = env["JC_API_ORIGIN"] {
            model.handle(["type": "hello", "api": api, "voice_dylib": dylib])
        }
        c.voicePanel = { menu.makeVoicePanel(island: true) }
        c.ui.setVoiceOrbHidden = { VoicePanelOrb.setHidden($0, on: menu.voicePanelClass()) }
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        c.activity()
        wait(1.5)
        try "go".write(toFile: marker, atomically: true, encoding: .utf8)
        wait(1.5)
        var log: [String] = []
        for open in [{ c.toggle() }, { c.toggle() }, { c.openVoice() }, { c.openVoice() }] {
            open()
            wait(0.05)
            log.append("open: flight=\(c.ui.orbFlight.map { "\($0.direction) \($0.home) launched=\($0.launched)" } ?? "none")")
            wait(1.3)
            c.close()
            wait(0.05)
            log.append("close: flight=\(c.ui.orbFlight.map { "\($0.direction) \($0.home)" } ?? "none")")
            wait(1.1)
        }
        try log.joined(separator: "\n").write(toFile: marker + ".log", atomically: true, encoding: .utf8)
    }

    /// How long the main thread stalls while push to talk opens the small voice
    /// island (the animation stutters when it does). JC_ISLAND_HITCH=<report
    /// path> with JC_VOICE_DYLIB / JC_API_ORIGIN; JC_HITCH_MIC also starts the
    /// microphone the way the key does (and stops it without sending).
    @MainActor
    func testPushToTalkOpensWithoutStalling() throws {
        let env = ProcessInfo.processInfo.environment
        guard let report = env["JC_ISLAND_HITCH"], let dylib = env["JC_VOICE_DYLIB"], let api = env["JC_API_ORIGIN"] else {
            throw XCTSkip("set JC_ISLAND_HITCH, JC_VOICE_DYLIB and JC_API_ORIGIN to measure push to talk")
        }
        // Not attached to jc-client: its hello would swap in the installed dylib.
        let model = AppModel()
        model.handle(["type": "hello", "api": api, "voice_dylib": dylib])
        let c = IslandController(model: model)
        let menu = JarvisMenu(model: model, island: c)
        c.voicePanel = { menu.makeVoicePanel(island: true) }
        c.voiceMiniPanel = { menu.makeVoiceMiniPanel() }
        c.ui.setVoiceOrbHidden = { VoicePanelOrb.setHidden($0, on: menu.voicePanelClass()) }
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        c.activity()
        wait(1.5)
        var lines: [String] = []
        for round in 0..<3 {
            var ticks: [Double] = []
            let timer = Timer(timeInterval: 0.008, repeats: true) { _ in ticks.append(CACurrentMediaTime()) }
            RunLoop.main.add(timer, forMode: .common)
            wait(0.2)
            let t0 = CACurrentMediaTime()
            var openedAt = t0
            if env["JC_HITCH_MIC"] != nil {
                // The app's order: the mic first, the island once audio flows.
                VoicePanelTalk.begin(on: menu.voicePanelClass()) { openedAt = CACurrentMediaTime(); c.openVoice(mini: true) }
            } else {
                c.openVoice(mini: true)
            }
            let tOpen = CACurrentMediaTime()
            let tTalk = tOpen
            wait(2.0)
            timer.invalidate()
            if env["JC_HITCH_MIC"] != nil {
                lines.append(String(format: "  island opened +%.0f ms after the key", (openedAt - t0) * 1000))
            }
            // The island's animation: from when it opened.
            let during = ticks.filter { $0 >= openedAt - 0.01 && $0 <= openedAt + 0.7 }
            let gaps = zip(during.dropFirst(), during).map { (at: ($1 - t0) * 1000, ms: ($0 - $1) * 1000) }
            let worst = gaps.map(\.ms).max() ?? 0
            let stalls = gaps.filter { $0.ms > 25 }.map { String(format: "%.0f ms at +%.0f", $0.ms, $0.at) }
            lines.append(String(format: "round %d: openVoice %.0f ms, began %.0f ms, worst gap %.0f ms; stalls: ",
                                round, (tOpen - t0) * 1000, (tTalk - tOpen) * 1000, worst) + stalls.joined(separator: ", "))
            if env["JC_HITCH_MIC"] != nil {
                let diag = NSSelectorFromString("diagnostics")
                if let cls = menu.voicePanelClass() as AnyObject as? NSObjectProtocol, cls.responds(to: diag),
                   let out = cls.perform(diag)?.takeUnretainedValue() as? [String] {
                    lines.append(contentsOf: (round == 0 ? out : Array(out.suffix(14))).map { "    " + $0 })
                }
                let sel = NSSelectorFromString("stopEverything")
                if let cls = menu.voicePanelClass() as AnyObject as? NSObjectProtocol, cls.responds(to: sel) { _ = cls.perform(sel) }
            }
            c.close()
            wait(1.2)
        }
        try lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }

    /// Where the voice engine's ~1 s start goes (JC_AUDIO_TIMING=<report>):
    /// building the echo-cancelling graph vs starting it, cold and warm.
    @MainActor
    func testWhereTheMicStartTimeGoes() throws {
        guard let report = ProcessInfo.processInfo.environment["JC_AUDIO_TIMING"] else {
            throw XCTSkip("set JC_AUDIO_TIMING to time the mic start")
        }
        var lines: [String] = []
        func ms(_ t: CFTimeInterval) -> String { String(format: "%.0f ms", (CACurrentMediaTime() - t) * 1000) }
        let plainOnly = ProcessInfo.processInfo.environment["JC_AUDIO_PLAIN"] != nil
        for round in 0..<(plainOnly ? 0 : 2) {
            var t = CACurrentMediaTime()
            let engine = AVAudioEngine()
            let input = engine.inputNode
            lines.append("round \(round): inputNode \(ms(t))")
            t = CACurrentMediaTime()
            try input.setVoiceProcessingEnabled(true)
            lines.append("  setVoiceProcessingEnabled \(ms(t))")
            t = CACurrentMediaTime()
            let fmt = input.outputFormat(forBus: 0)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
            input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { _, _ in }
            engine.prepare()
            lines.append("  connect+tap+prepare \(ms(t))")
            t = CACurrentMediaTime()
            try engine.start()
            lines.append("  start \(ms(t))")
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            engine.stop()
            t = CACurrentMediaTime()
            try engine.start()
            lines.append("  restart (graph kept) \(ms(t))")
            lines.append("  mic running while started: \(Self.inputRunning())")
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            engine.stop()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            lines.append("  mic running after stop, graph kept: \(Self.inputRunning())")
            input.removeTap(onBus: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        lines.append("baseline (all released): \(Self.inputRunning())")
        // Without echo cancellation: what push to talk could start with.
        for round in 0..<2 {
            let t = CACurrentMediaTime()
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            var peak: Float = 0
            input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, _ in
                if let ch = buf.floatChannelData { for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[0][i])) } }
            }
            engine.prepare()
            try engine.start()
            lines.append("plain round \(round): build+start \(ms(t)), \(fmt.channelCount)ch @\(Int(fmt.sampleRate))")
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            lines.append("  room peak \(String(format: "%.4f", peak))")
            input.removeTap(onBus: 0)
            engine.stop()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            lines.append("  mic running after stop: \(Self.inputRunning())")
        }
        try lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }

    /// Whether the default input device is running in any process (what lights
    /// the menu bar's mic indicator).
    private static func inputRunning() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
        return running != 0
    }

    /// The flight drawn at points along the way (offscreen; JC_ISLAND_SNAPSHOT
    /// writes a filmstrip PNG to look at).
    @MainActor
    func testRenderTheFlight() throws {
        guard let out = ProcessInfo.processInfo.environment["JC_ISLAND_SNAPSHOT"] else {
            throw XCTSkip("set JC_ISLAND_SNAPSHOT to render the orb's flight")
        }
        let frames: [CGFloat] = [0, 0.2, 0.45, 0.7, 0.9, 1.04, 1]
        let (ear, stage) = (self.ear, self.stage)
        let strip = HStack(spacing: 6) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, t in
                ZStack(alignment: .topLeading) {
                    Color.black
                    FlyingOrb(ear: ear, home: stage, progress: t, mood: .idle)
                }
                .frame(width: 480, height: 200)
                .clipped()
            }
        }
        .padding(6)
        .background(Color(white: 0.3))
        .transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: strip)
        host.frame = CGRect(x: 0, y: 0, width: 6 + CGFloat(frames.count) * 486, height: 212)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + "-flight.png"))
    }
}
