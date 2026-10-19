import XCTest
@testable import JarvisCopilot

/// A button's Lock Screen card and Dynamic Island: what it carries, one card per source, the
/// result then gone, push tokens to the server, and Stop from the card.
@MainActor
final class ButtonActivityTests: XCTestCase {

    private var system: FakeButtonSystem!
    private var uploads: UploadLog!

    override func setUp() async throws {
        system = FakeButtonSystem()
        uploads = UploadLog()
    }

    private func controller() -> ButtonActivityController {
        let log = uploads!
        return ButtonActivityController(system: system, upload: { source, token in
            log.calls.append("\(source)=\(token)")
            return log.ok
        })
    }

    private func arming(ends: Date = Date().addingTimeInterval(45)) -> ButtonLiveState {
        ButtonLiveState(id: "door.arming", title: "Stop arming", symbol: "xmark.shield", caption: "Away in",
                        startedAt: ends.addingTimeInterval(-60), endsAt: ends)
    }

    private let disarm = ButtonLiveState(id: "door.armed", title: "Disarm", symbol: "lock.open", caption: "Armed Away")

    // MARK: content

    func testContentRoundTripsAndStaysUnderTheFourKilobyteBudget() throws {
        var state = arming()
        state.tint = "#3EC7C7"
        state.alert = true
        let content = ButtonActivityAttributes.ContentState(state: state, finished: true, result: "Armed Away")
        let data = try JSONEncoder().encode(content)
        XCTAssertEqual(try JSONDecoder().decode(ButtonActivityAttributes.ContentState.self, from: data), content)
        XCTAssertLessThan(data.count, 4096)
        let attributes = ButtonActivityAttributes(source: "door", buttonID: "b1", name: "Door alarm", symbol: "shield")
        let back = try JSONDecoder().decode(ButtonActivityAttributes.self, from: JSONEncoder().encode(attributes))
        XCTAssertEqual(back.source, "door")
        XCTAssertEqual(back.buttonID, "b1")
    }

    /// ActivityKit decodes a push with a default JSONDecoder: camelCase keys, dates as seconds
    /// since 2001-01-01. The server's door pushes are written to match.
    func testPushedContentUsesSecondsSince2001() throws {
        let ends = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let encoded = try JSONEncoder().encode(ButtonActivityAttributes.ContentState(
            state: arming(ends: ends), finished: false, result: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(state["endsAt"] as? Double, 800_000_000)

        let pushed = """
        {"state": {"id": "door.arming", "title": "Stop arming", "symbol": "xmark.shield", "caption": "Away in",
                   "alert": false, "startedAt": 799999940, "endsAt": 800000000},
         "finished": false}
        """
        let decoded = try JSONDecoder().decode(ButtonActivityAttributes.ContentState.self, from: Data(pushed.utf8))
        XCTAssertEqual(decoded.state.endsAt, ends)
        XCTAssertNil(decoded.result)
    }

    // MARK: one card per source

    func testOneCardPerSourceIsUpdatedNotDoubled() async {
        let c = controller()
        await c.show(source: "door", buttonID: "away", name: "Door alarm", symbol: "shield", state: arming())
        await c.show(source: "door", buttonID: "home", name: "Arm Home", symbol: "house", state: disarm)
        XCTAssertEqual(system.started.count, 1, "Arm Away and Arm Home share the door's card")
        XCTAssertEqual(system.started[0].content.state, disarm)
        XCTAssertEqual(system.started[0].attributes.buttonID, "away")
        await c.show(source: "car", buttonID: "start", name: "Car", symbol: "car", state: arming())
        XCTAssertEqual(system.started.count, 2)
        XCTAssertEqual(Set(c.running.keys), ["door", "car"])
    }

    func testTheCardGoesStaleJustAfterItsCountdown() async {
        let ends = Date().addingTimeInterval(30)
        let c = controller()
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: arming(ends: ends))
        XCTAssertEqual(system.started[0].staleDates, [ends.addingTimeInterval(ButtonActivityController.staleGrace)])
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: disarm)
        XCTAssertEqual(system.started[0].staleDates.last, .some(nil), "no countdown, never stale")
    }

    func testNoCardWhileLiveActivitiesAreOff() async {
        system.enabled = false
        await controller().show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: arming())
        XCTAssertTrue(system.started.isEmpty)
    }

    // MARK: finish and end

    func testFinishShowsTheResultThenEnds() async {
        let c = controller()
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: arming())
        await c.finish(source: "door", result: "Armed Away")
        let card = system.started[0]
        XCTAssertEqual(card.log, ["request", "update finished=Armed Away", "end finished=Armed Away after 4.0"])
        XCTAssertNil(c.running["door"])
        // Arming again starts a fresh card.
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: arming())
        XCTAssertEqual(system.started.count, 2)
    }

    func testEndGoesAtOnce() async {
        let c = controller()
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: arming())
        await c.end(source: "door")
        XCTAssertEqual(system.started[0].log, ["request", "end now"])
        await c.end(source: "door")   // nothing up: nothing to do
        XCTAssertEqual(system.started[0].log.count, 2)
    }

    // MARK: cards from before, and from the server

    func testAdoptsTheCardFromBeforeAndEndsADuplicate() async {
        let first = FakeButtonActivity(id: "old1", source: "door", buttonID: "b", state: arming())
        let second = FakeButtonActivity(id: "old2", source: "door", buttonID: "", state: arming())
        system.running = [first, second]
        let c = controller()
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: disarm)
        await c.drain()
        XCTAssertTrue(system.started.isEmpty)
        XCTAssertEqual(first.content.state, disarm)
        XCTAssertEqual(second.log, ["end now"])
    }

    func testACardTheServerStartedIsTheOneUpdated() async {
        let c = controller()
        c.setDoorPushToStart(enabled: true)
        let pushed = FakeButtonActivity(id: "srv", source: "door", buttonID: "", state: arming())
        system.newHandler?(pushed)
        system.newHandler?(pushed)   // seen twice: still one
        await c.show(source: "door", buttonID: "away", name: "Door", symbol: "shield", state: disarm)
        XCTAssertTrue(system.started.isEmpty)
        XCTAssertEqual(pushed.content.state, disarm)
        pushed.token?("abcd")
        await c.drain()
        XCTAssertEqual(uploads.calls, ["door=abcd"], "its own token goes up as the door's")
    }

    func testASwipedAwayCardStaysAwayForThatState() async {
        let c = controller()
        let state = arming()
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: state)
        system.started[0].gone?(true)
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: state)
        XCTAssertEqual(system.started.count, 1)
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: disarm)
        XCTAssertEqual(system.started.count, 2, "a new state brings it back")
    }

    func testACardThatEndedOnItsOwnIsStartedAgain() async {
        let c = controller()
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: arming())
        system.started[0].gone?(false)   // an end push
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: arming())
        XCTAssertEqual(system.started.count, 2)
    }

    // MARK: push tokens

    func testEachTokenGoesToTheServerOnceAndAFailureIsRetried() async {
        let c = controller()
        await c.show(source: "door", buttonID: "b", name: "Door", symbol: "shield", state: arming())
        let card = system.started[0]
        uploads.ok = false
        card.token?("aa")
        await c.drain()
        uploads.ok = true
        card.token?("aa")
        await c.drain()
        card.token?("aa")
        await c.drain()
        card.token?("bb")
        await c.drain()
        XCTAssertEqual(uploads.calls, ["door=aa", "door=aa", "door=bb"])
    }

    func testDoorPushToStartTokenIsSentWhileOnAndForgottenWhenOff() async {
        let c = controller()
        c.setDoorPushToStart(enabled: true)
        await c.drain()
        XCTAssertTrue(uploads.calls.isEmpty, "no token yet")
        system.startTokenHandler?("cc")
        await c.drain()
        c.setDoorPushToStart(enabled: true)
        await c.drain()
        c.setDoorPushToStart(enabled: false)
        await c.drain()
        c.setDoorPushToStart(enabled: false)
        await c.drain()
        c.setDoorPushToStart(enabled: true)
        await c.drain()
        XCTAssertEqual(uploads.calls, ["door-start=cc", "door-start=", "door-start=cc"])
    }

    func testAPushToStartTokenWhileOffStaysHome() async {
        let c = controller()
        c.observe()
        system.startTokenHandler?("cc")
        await c.drain()
        XCTAssertTrue(uploads.calls.isEmpty)
    }

    // MARK: Stop

    func testStopPressesTheButtonForTheStateTheCardShowed() async throws {
        let saved = ControlButtonBridge.run
        defer { ControlButtonBridge.run = saved }
        var pressed: [ButtonPress] = []
        ControlButtonBridge.run = { pressed.append($0) }
        _ = try await StopButtonActivityIntent(buttonID: "away", stateID: "door.arming").perform()
        _ = try await StopButtonActivityIntent(buttonID: "", stateID: "door.arming").perform()
        XCTAssertEqual(pressed, [ButtonPress(buttonID: "away", physical: false, shownState: "door.arming"),
                                 ButtonPress(buttonID: "door", physical: false, shownState: "door.arming")],
                       "never his own Control Center press; a server-started card stops the door alarm itself")
    }
}

// MARK: - Fakes

@MainActor
final class UploadLog {
    var calls: [String] = []
    var ok = true
}

@MainActor
final class FakeButtonActivity: ButtonActivityHandle {
    let id: String
    let attributes: ButtonActivityAttributes
    var content: ButtonActivityAttributes.ContentState
    var isLive = true
    var log: [String] = []
    var staleDates: [Date?] = []
    var token: (@MainActor @Sendable (String) -> Void)?
    var gone: (@MainActor @Sendable (Bool) -> Void)?

    init(id: String, source: String, buttonID: String, state: ButtonLiveState) {
        self.id = id
        attributes = ButtonActivityAttributes(source: source, buttonID: buttonID, name: "Door", symbol: "shield")
        content = .init(state: state, finished: false, result: nil)
    }

    func update(_ content: ButtonActivityAttributes.ContentState, staleDate: Date?) async {
        self.content = content
        staleDates.append(staleDate)
        if content.finished { log.append("update finished=\(content.result ?? "")") }
    }

    func end(_ content: ButtonActivityAttributes.ContentState?, dismissAfter: TimeInterval?) async {
        if let content { self.content = content }
        isLive = false
        if let dismissAfter {
            log.append("end finished=\(content?.result ?? "") after \(dismissAfter)")
        } else {
            log.append("end now")
        }
    }

    func watch(token: @escaping @MainActor @Sendable (String) -> Void,
               gone: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.token = token
        self.gone = gone
    }
}

@MainActor
final class FakeButtonSystem: ButtonActivitySystem {
    var enabled = true
    var running: [any ButtonActivityHandle] = []
    var started: [FakeButtonActivity] = []
    var newHandler: (@MainActor @Sendable (any ButtonActivityHandle) -> Void)?
    var startTokenHandler: (@MainActor @Sendable (String) -> Void)?

    func request(_ attributes: ButtonActivityAttributes, _ content: ButtonActivityAttributes.ContentState,
                 staleDate: Date?) -> (any ButtonActivityHandle)? {
        let card = FakeButtonActivity(id: "new\(started.count)", source: attributes.source,
                                      buttonID: attributes.buttonID, state: content.state)
        card.staleDates.append(staleDate)
        card.log.append("request")
        started.append(card)
        return card
    }

    func watchNew(_ handler: @escaping @MainActor @Sendable (any ButtonActivityHandle) -> Void) {
        newHandler = handler
    }

    func watchStartToken(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        startTokenHandler = handler
    }
}
