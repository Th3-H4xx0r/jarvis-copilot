import XCTest
import AppKit
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
