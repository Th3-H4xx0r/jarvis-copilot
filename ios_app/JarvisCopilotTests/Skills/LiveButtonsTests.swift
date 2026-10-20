import XCTest
@testable import JarvisCopilot

/// The live buttons coordinator: timelines written for Control Center, one Lock Screen card per
/// source, and what a press just did shown straight away.
@MainActor
final class LiveButtonsTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var buttons: [ControlButton] = []
    private var applied: [String: ButtonTimeline?] = [:]
    private var shown: [(source: String, state: String)] = []
    private var finished: [(source: String, result: String)] = []
    private var pushToStart: [Bool] = []
    private var door: DoorAlarmInfo?

    private func coordinator() -> LiveButtons {
        let c = LiveButtons()
        c.buttons = { [unowned self] in buttons }
        c.apply = { [unowned self] in applied = $0 }
        c.fetchDoor = { [unowned self] in door }
        c.fetchCar = { nil }
        c.widgetData = { [:] }
        c.wearableState = { _, _, _ in nil }
        c.showCard = { [unowned self] source, _, _, _, state in shown.append((source, state.id)); return true }
        c.runningCards = { [:] }
        c.notify = { _, _ in }
        c.finishCard = { [unowned self] source, result in finished.append((source, result)) }
        c.setDoorPushToStart = { [unowned self] in pushToStart.append($0) }
        c.reloadControls = {}
        c.now = { [unowned self] in now }
        return c
    }

    private func arming(in seconds: TimeInterval) -> DoorAlarmInfo {
        DoorAlarmInfo(json: ["state": "arming", "mode": "away", "deadline": now.timeIntervalSince1970 + seconds])
    }

    func testTwoDoorButtonsShareOneCard() async {
        buttons = [ControlButton(id: "away", name: "Away", symbol: "a", action: .door(.armAway)),
                   ControlButton(id: "home", name: "Home", symbol: "h", action: .door(.armHome))]
        let c = coordinator()
        await c.doorChanged(arming(in: 45))
        XCTAssertEqual(shown.map(\.source), ["door"], "one Lock Screen card for the door, not one per button")
        XCTAssertEqual(applied["away"]??.state(at: now)?.title, "Stop arming")
        XCTAssertEqual(pushToStart.last, true, "the server may start a door card when arming starts elsewhere")
    }

    func testTheCardFinishesWhenTheCountdownIsOver() async {
        buttons = [ControlButton(id: "away", name: "Away", symbol: "a", action: .door(.armAway))]
        let c = coordinator()
        await c.doorChanged(arming(in: 45))
        await c.doorChanged(DoorAlarmInfo(json: ["state": "armed_away"]))
        XCTAssertEqual(finished.map(\.result), ["Armed Away"])
        XCTAssertEqual(applied["away"]??.state(at: now)?.title, "Disarm")
    }

    func testACardCanBeTurnedOff() async {
        var b = ControlButton(id: "away", name: "Away", symbol: "a", action: .door(.armAway))
        b.showsLiveActivity = false
        buttons = [b]
        let c = coordinator()
        await c.doorChanged(arming(in: 45))
        XCTAssertTrue(shown.isEmpty)
        XCTAssertEqual(pushToStart.last, false)
    }

    func testACarCommandShowsItsResultStraightAway() async {
        let b = ControlButton(id: "lock", name: "Lock", symbol: "lock", action: .car(command: "lock"))
        buttons = [b]
        let c = coordinator()
        await c.didRun(b, action: .car(command: "lock"), line: "Locked")
        XCTAssertEqual(applied["lock"]??.state(at: now)?.title, "Unlock")
        await c.didRun(b, action: .car(command: "unlock"), line: "Unlock the car failed: offline")
        XCTAssertEqual(applied["lock"]??.state(at: now)?.title, "Unlock", "a failed command changes nothing")
    }

    func testTheDoorCardsStopCancelsOnlyWhileArming() async {
        var ran: [RingAction] = []
        let c = coordinator()
        c.runAction = { action, context in
            XCTAssertFalse(context.physical, "a card press never skips Face ID")
            ran.append(action)
            return "ok"
        }
        door = arming(in: 30)
        await c.pressDoorCard(shownState: "door.arming")
        door = DoorAlarmInfo(json: ["state": "armed_away"])
        await c.pressDoorCard(shownState: "door.arming")
        XCTAssertEqual(ran, [.door(.cancelArming)], "once armed, a stale Stop does nothing")
    }

    // MARK: review fixes

    func testTheCardSaysArmedAwayWhenTheDelayRunsOutWithoutAFreshRead() async {
        buttons = [ControlButton(id: "away", name: "Away", symbol: "a", action: .door(.armAway))]
        let c = coordinator()
        await c.doorChanged(arming(in: 45))
        now = now.addingTimeInterval(50)
        await c.recompute()
        XCTAssertEqual(finished.map(\.result), ["Armed Away"], "not \"Disarmed\" from the old arming reading")
    }

    func testTheCardStaysUpWhileTheAlarmIsGoingOff() async {
        buttons = [ControlButton(id: "d", name: "Disarm", symbol: "a", action: .door(.disarm))]
        let c = coordinator()
        await c.doorChanged(DoorAlarmInfo(json: ["state": "triggered", "siren_on": true]))
        XCTAssertEqual(shown.map(\.state), ["door.siren"])
        XCTAssertTrue(finished.isEmpty)
    }

    func testAFailedReadKeepsTheLastGoodTile() async {
        buttons = [ControlButton(id: "away", name: "Away", symbol: "a", action: .door(.armAway))]
        let c = coordinator()
        await c.recompute()
        XCTAssertNil(applied["away"] ?? nil, "never read: nothing written over the tile")
        XCTAssertFalse(applied.keys.contains("away"))
    }

    func testAStaleDoorCardStopDoesNotDisarm() async {
        var ran: [RingAction] = []
        let c = coordinator()
        c.runAction = { action, _ in ran.append(action); return "ok" }
        door = DoorAlarmInfo(json: ["state": "entry"])
        await c.pressDoorCard(shownState: "door.arming")
        XCTAssertTrue(ran.isEmpty, "the card showed Stop arming; the entry delay's disarm is not what he pressed")
    }
}
