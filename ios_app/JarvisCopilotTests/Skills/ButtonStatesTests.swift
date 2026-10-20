import XCTest
@testable import JarvisCopilot

/// What a live button shows and does: the door alarm, the car, wearable switches, his own states.
@MainActor
final class ButtonStatesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func button(_ action: RingAction, id: String = "b") -> ControlButton {
        ControlButton(id: id, name: "B", symbol: "bolt.fill", action: action)
    }

    private func alarm(_ state: String, mode: String? = nil, deadline: Date? = nil, siren: Bool = false,
                       contact: String? = nil) -> DoorAlarmInfo {
        var json: [String: Any] = ["state": state, "siren_on": siren]
        if let mode { json["mode"] = mode }
        if let deadline { json["deadline"] = deadline.timeIntervalSince1970 }
        if let contact { json["contact_name"] = contact }
        return DoorAlarmInfo(json: json)
    }

    private func states(_ b: ControlButton, door: DoorAlarmInfo? = nil, car: CarLive? = nil) -> [ResolvedState]? {
        ButtonStateResolver.resolve(b, live: LiveValues(door: door, car: car), now: now)
    }

    // MARK: door

    func testAnArmButtonArmsWhileDisarmed() {
        let s = states(button(.door(.armAway)), door: alarm("disarmed"))
        XCTAssertEqual(s?.first?.state.title, "Arm Away")
        XCTAssertEqual(s?.first?.action, .door(.armAway))
    }

    func testWhileArmingItStopsThenDisarmsAtTheDeadline() throws {
        let deadline = now.addingTimeInterval(45)
        let b = button(.door(.armAway, skipFaceID: true))
        let timeline = try XCTUnwrap(ButtonStateResolver.timeline(b, live: LiveValues(door: alarm("arming", mode: "away",
                                                                                                   deadline: deadline)), now: now))
        XCTAssertEqual(timeline.state(at: now)?.title, "Stop arming")
        XCTAssertEqual(timeline.state(at: now)?.endsAt, deadline)
        XCTAssertEqual(timeline.state(at: deadline.addingTimeInterval(1))?.title, "Disarm",
                       "a tile drawn after the delay reads Disarm, even if the app slept through it")
        XCTAssertEqual(timeline.nextChange(after: now), deadline)
        let resolved = try XCTUnwrap(states(b, door: alarm("arming", mode: "away", deadline: deadline)))
        XCTAssertEqual(resolved[0].action, .door(.cancelArming))
        XCTAssertEqual(resolved[1].action, .door(.disarm, skipFaceID: true), "the button's Skip Face ID carries over")
    }

    func testArmedShowsDisarmAndGoingOffShowsSilence() {
        XCTAssertEqual(states(button(.door(.armHome)), door: alarm("armed_home"))?.first?.state.caption, "Armed Home")
        let going = states(button(.door(.disarm)), door: alarm("triggered", siren: true))?.first
        XCTAssertEqual(going?.state.title, "Silence")
        XCTAssertEqual(going?.state.alert, true)
        XCTAssertEqual(going?.action, .door(.silence))
    }

    func testOnlyArmButtonsCanArm() {
        for command in [DoorButtonCommand.disarm, .silence, .status, .armNow, .cancelArming] {
            let s = states(button(.door(command)), door: alarm("disarmed"))?.first
            XCTAssertEqual(s?.action, .door(.status), "\(command) must never arm the house")
            XCTAssertEqual(s?.state.title, "Disarmed")
        }
    }

    func testAFixedTileFollowsNothing() {
        var b = button(.door(.armAway))
        b.followsLive = false
        XCTAssertNil(states(b, door: alarm("armed_away")))
    }

    // MARK: pressing

    func testAPressOnAStaleTileIsRefusedNotTurnedIntoADisarm() {
        let b = button(.door(.armAway, skipFaceID: true))
        let live = LiveValues(door: alarm("armed_away"))
        guard case .changed(let state) = ButtonStateResolver.press(b, shownState: "door.arming", live: live, now: now) else {
            return XCTFail("a press that saw Stop arming must not disarm")
        }
        XCTAssertEqual(state.title, "Disarm")
        guard case .run(let action) = ButtonStateResolver.press(b, shownState: "door.armed_away", live: live, now: now) else {
            return XCTFail("a press that saw Disarm disarms")
        }
        XCTAssertEqual(action, .door(.disarm, skipFaceID: true))
    }

    func testAPressAfterTheDeadlineUsesTheArmedState() {
        let deadline = now.addingTimeInterval(-1)
        let live = LiveValues(door: alarm("arming", mode: "away", deadline: deadline))
        guard case .changed = ButtonStateResolver.press(button(.door(.armAway)), shownState: "door.arming",
                                                         live: live, now: now) else {
            return XCTFail("the delay has ended: Stop arming is stale")
        }
    }

    func testAButtonWithoutStatesRunsItsOwnAction() {
        guard case .run(let action) = ButtonStateResolver.press(button(.skill(id: "vibrate", arguments: [:])),
                                                                 shownState: nil, live: LiveValues(), now: now) else {
            return XCTFail()
        }
        XCTAssertEqual(action, .skill(id: "vibrate", arguments: [:]))
    }

    // MARK: car

    func testCarLockFlipsAndRemoteStartCountsDown() {
        XCTAssertEqual(states(button(.car(command: "lock")), car: CarLive(locked: true))?.first?.action,
                       .car(command: "unlock"))
        let started = now.addingTimeInterval(-60)
        let running = states(button(.car(command: "start")), car: CarLive(running: true, startedAt: started))?.first
        XCTAssertEqual(running?.state.title, "Stop engine")
        XCTAssertEqual(running?.state.endsAt, started.addingTimeInterval(ButtonStateResolver.remoteStartRun))
        XCTAssertNil(states(button(.car(command: "horn")), car: CarLive(locked: true)), "the horn has no state")
        XCTAssertNil(states(button(.car(command: "lock")), car: CarLive()), "nothing known yet: the button's own action")
    }

    // MARK: wearables

    func testAWearableSwitchFollowsTheDeviceOrWhatTheButtonLastSet() {
        let b = button(.wearable(deviceID: "bottle", skill: "bottle_sterilise", arguments: ["on": "true", "confirm": "true"]))
        var live = LiveValues()
        live.wearableState = { _, _, _ in CommandLiveState(on: true) }
        let on = ButtonStateResolver.resolve(b, live: live, now: now)?.first
        XCTAssertEqual(on?.state.title, "Stop sterilising")
        XCTAssertEqual(on?.action, .wearable(deviceID: "bottle", skill: "bottle_sterilise",
                                             arguments: ["on": "false", "confirm": "true"]))
        live.wearableState = { _, _, _ in nil }
        live.lastSet["b"] = (false, now.addingTimeInterval(-60))
        XCTAssertEqual(ButtonStateResolver.resolve(b, live: live, now: now)?.first?.state.title, "Sterilise now")
        live.lastSet["b"] = (true, now.addingTimeInterval(-7 * 3600))
        XCTAssertNil(ButtonStateResolver.resolve(b, live: live, now: now), "a guess older than 6 h is dropped")
    }

    // MARK: his own states

    func testHisOwnStatesFollowALiveValue() {
        var b = button(.prompt("x"))
        b.states = ButtonStates(follows: "bottle.status", rules: [
            .init(when: .equals("Sterilising"), title: "Stop", symbol: "stop.fill",
                  action: .skill(id: "vibrate", arguments: [:])),
            .init(when: .otherwise, title: "Clean", symbol: "drop", action: .prompt("clean it")),
        ], countdownKey: "bottle.ends")
        var live = LiveValues()
        live.values = ["bottle.status": .string("sterilising"), "bottle.ends": .number(now.timeIntervalSince1970 + 90)]
        let first = ButtonStateResolver.resolve(b, live: live, now: now)?.first
        XCTAssertEqual(first?.state.title, "Stop")
        XCTAssertEqual(first?.state.endsAt, now.addingTimeInterval(90))
        live.values["bottle.status"] = .string("Idle")
        XCTAssertEqual(ButtonStateResolver.resolve(b, live: live, now: now)?.first?.action, .prompt("clean it"))
    }

    func testStatesSurviveARoundTrip() throws {
        var b = button(.door(.armAway))
        b.states = ButtonStates(follows: "car.locked", rules: [.init(when: .on, title: "Unlock", symbol: "lock.open",
                                                                       action: .car(command: "unlock"))])
        b.timeline = ButtonTimeline(ButtonLiveState(id: "x", title: "T", symbol: "s"))
        b.followsLive = false
        let back = try JSONDecoder().decode(ControlButton.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
        let info = try JSONDecoder().decode([ControlButtonInfo].self, from: JSONEncoder().encode([b])).first
        XCTAssertEqual(info?.timeline?.state(at: now)?.title, "T", "the widget extension reads the timeline")
    }

    // MARK: review fixes

    func testATileWithNoStateNeverRunsADifferentAction() {
        let b = button(.door(.armAway, skipFaceID: true))
        let armed = LiveValues(door: alarm("armed_away"))
        guard case .changed = ButtonStateResolver.press(b, shownState: nil, live: armed, now: now) else {
            return XCTFail("an Arm Away tile with no state must never disarm")
        }
        guard case .run(let action) = ButtonStateResolver.press(b, shownState: nil, live: LiveValues(door: alarm("disarmed")),
                                                                 now: now) else { return XCTFail() }
        XCTAssertEqual(action, .door(.armAway, skipFaceID: true))
    }

    func testArmNowFinishesArmingRatherThanCancellingIt() {
        let s = states(button(.door(.armNow)), door: alarm("arming", mode: "away", deadline: now.addingTimeInterval(30)))
        XCTAssertEqual(s?.first?.state.title, "Arm now")
        XCTAssertEqual(s?.first?.action, .door(.armNow))
    }

    func testAGuessedWearableStateGoesBackToTheButtonWhenItExpires() throws {
        let b = button(.wearable(deviceID: "bottle", skill: "bottle_sterilise", arguments: ["on": "true"]))
        var live = LiveValues()
        live.lastSet["b"] = (true, now.addingTimeInterval(-60))
        let timeline = try XCTUnwrap(ButtonStateResolver.timeline(b, live: live, now: now))
        XCTAssertEqual(timeline.state(at: now)?.title, "Stop sterilising")
        XCTAssertEqual(timeline.state(at: now.addingTimeInterval(ButtonStateResolver.optimisticFor))?.id,
                       ButtonStateResolver.ownStateID)
    }

    func testAPressOnAStateTheButtonNoLongerHasIsRefused() {
        var b = button(.door(.armAway))
        b.followsLive = false
        guard case .changed = ButtonStateResolver.press(b, shownState: "door.arming", live: LiveValues(), now: now) else {
            return XCTFail("the tile still showed a live state: don't guess")
        }
    }

    // MARK: his icons, every wearable state

    func testHisIconReplacesAStatesIconEverywhereItShows() throws {
        var b = button(.door(.armAway))
        b.stateSymbols = ["door.arming": "figure.walk.departure", "door.armed_away": "house.lodge"]
        let deadline = now.addingTimeInterval(45)
        let timeline = try XCTUnwrap(ButtonStateResolver.timeline(b, live: LiveValues(door: alarm("arming", mode: "away",
                                                                                                   deadline: deadline)), now: now))
        XCTAssertEqual(timeline.state(at: now)?.symbol, "figure.walk.departure")
        XCTAssertEqual(timeline.state(at: deadline)?.symbol, "house.lodge")
        XCTAssertEqual(states(b, door: alarm("triggered", siren: true))?.first?.state.symbol, "speaker.slash.fill",
                       "a state he didn't change keeps the standard icon")
    }

    func testEveryStateAButtonCanShowIsListedForItsIcon() {
        let door = ButtonStateResolver.possibleStates(button(.door(.armAway))).map(\.id)
        XCTAssertEqual(Set(door), ["door.disarmed", "door.arming", "door.armed_away", "door.armed_home", "door.entry",
                                   "door.siren", "door.triggered"])
        XCTAssertEqual(Set(ButtonStateResolver.possibleStates(button(.car(command: "lock"))).map(\.id)),
                       ["car.locked", "car.unlocked"])
        let sterilise = button(.wearable(deviceID: "b", skill: "bottle_sterilise", arguments: ["on": "true"]))
        XCTAssertEqual(Set(ButtonStateResolver.possibleStates(sterilise).map(\.id)),
                       ["bottle_sterilise.on", "bottle_sterilise.off"])
        XCTAssertTrue(ButtonStateResolver.possibleStates(button(.prompt("x"))).isEmpty)
    }

    func testAModeShowsWhatTheDeviceIsOnNow() {
        let b = button(.wearable(deviceID: "ring", skill: "ring_set_input_mode", arguments: ["mode": "music"]))
        var live = LiveValues()
        live.wearableState = { _, _, _ in CommandLiveState(mode: "jarvis") }
        let s = ButtonStateResolver.resolve(b, live: live, now: now)?.first
        XCTAssertEqual(s?.state.caption, "Now: jarvis")
        XCTAssertEqual(s?.action, b.action)
    }

    func testARunningWearableCountsDownToItsEnd() {
        let b = button(.wearable(deviceID: "bottle", skill: "bottle_sterilise", arguments: ["on": "true"]))
        var live = LiveValues()
        live.wearableState = { _, _, _ in CommandLiveState(on: true, endsAt: self.now.addingTimeInterval(120)) }
        XCTAssertEqual(ButtonStateResolver.resolve(b, live: live, now: now)?.first?.state.endsAt, now.addingTimeInterval(120))
    }

    func testHisIconsSurviveARoundTrip() throws {
        var b = button(.car(command: "lock"))
        b.stateSymbols = ["car.locked": "lock.shield"]
        XCTAssertEqual(try JSONDecoder().decode(ControlButton.self, from: JSONEncoder().encode(b)).stateSymbols,
                       ["car.locked": "lock.shield"])
    }
}
