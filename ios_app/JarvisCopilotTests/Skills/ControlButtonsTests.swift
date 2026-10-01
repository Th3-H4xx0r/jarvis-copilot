import XCTest
@testable import JarvisCopilot

/// Control Center buttons: set up in settings, listed and drawn by the widget, run in the app.
@MainActor
final class ControlButtonsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var reloads = 0
    private var ran: [RingAction] = []
    private var notes: [(String, String)] = []
    private var reply = "done"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "ControlButtonsTests-\(UUID().uuidString)")
        reloads = 0
        ran = []
        notes = []
        reply = "done"
    }

    private func store() -> ControlButtonStore {
        ControlButtonStore(defaults: defaults,
                           reloadControls: { [unowned self] in reloads += 1 },
                           runAction: { [unowned self] action in ran.append(action); return reply },
                           notify: { [unowned self] title, body in notes.append((title, body)) })
    }

    private func button(_ name: String, _ action: RingAction, symbol: String = "bolt.fill") -> ControlButton {
        ControlButton(id: UUID().uuidString, name: name, symbol: symbol, action: action)
    }

    func testASavedButtonIsWhatTheWidgetLists() {
        let s = store()
        let b = button("Play / pause", .skill(id: "play_pause", arguments: [:]), symbol: "playpause.fill")
        s.save(b)
        XCTAssertEqual(ControlButtonShelf.infos(defaults: defaults),
                       [ControlButtonInfo(id: b.id, name: "Play / pause", symbol: "playpause.fill")])
        XCTAssertEqual(reloads, 1, "Control Center is told to redraw")
    }

    func testSavingAgainReplacesAndDeletingRemoves() {
        let s = store()
        var b = button("One", .prompt("hi"))
        s.save(b)
        b.name = "Renamed"
        s.save(b)
        XCTAssertEqual(ControlButtonShelf.infos(defaults: defaults).map(\.name), ["Renamed"])
        s.delete(b.id)
        XCTAssertEqual(ControlButtonShelf.infos(defaults: defaults), [])
    }

    func testButtonsSurviveARestart() {
        let b = button("Torch", .skill(id: "flashlight_on", arguments: [:]))
        store().save(b)
        XCTAssertEqual(store().button(b.id), b)
    }

    func testAPressRunsTheButtonsActionSilently() async {
        let s = store()
        let b = button("Next", .skill(id: "next_track", arguments: [:]))
        s.save(b)
        await s.press(b.id)
        XCTAssertEqual(ran, [b.action])
        XCTAssertTrue(notes.isEmpty)
    }

    func testAPromptsReplyComesBackAsANotification() async {
        let s = store()
        let b = button("Day", .prompt("How am I doing today?"))
        s.save(b)
        reply = "You're well rested."
        await s.press(b.id)
        XCTAssertEqual(notes.first?.0, "Day")
        XCTAssertEqual(notes.first?.1, "You're well rested.")
    }

    func testAFailureComesBackAsANotification() async {
        let s = store()
        let b = button("Ring", .skill(id: "ring_sync", arguments: [:]))
        s.save(b)
        reply = "ring_sync failed: not connected"
        await s.press(b.id)
        XCTAssertEqual(notes.count, 1)
    }

    func testPressesQueuedByTheWidgetRunWhenTheAppIsUp() async {
        let s = store()
        let a = button("A", .prompt("a")), b = button("B", .skill(id: "vibrate", arguments: [:]))
        s.save(a)
        s.save(b)
        ControlButtonShelf.queue(a.id, defaults: defaults)
        ControlButtonShelf.queue(b.id, defaults: defaults)
        await s.runPending()
        XCTAssertEqual(ran, [a.action, b.action])
        XCTAssertEqual(ControlButtonShelf.takePending(defaults: defaults), [])
    }

    func testAPressForADeletedButtonDoesNothing() async {
        await store().press("gone")
        XCTAssertTrue(ran.isEmpty)
    }

    func testTheIntentHandsThePressToTheApp() async throws {
        let saved = ControlButtonBridge.run
        defer { ControlButtonBridge.run = saved }
        var pressed: [String] = []
        ControlButtonBridge.run = { pressed.append($0) }
        let entity = ControlButtonEntity(ControlButtonInfo(id: "b1", name: "B", symbol: "bolt.fill"))
        _ = try await RunJarvisButtonIntent(button: entity).perform()
        XCTAssertEqual(pressed, ["b1"])
    }

    // MARK: wearable keep-alive as an action

    func testEveryWearableWithAKeepAliveSwitchIsAnAction() {
        for device in WearableKeepAlive.switchable {
            let option = RingActionCatalogue.option("keep_alive_\(device.key)")
            XCTAssertEqual(option?.skill, "wearables_keep_alive", device.key)
            XCTAssertEqual(option?.arguments["wearable"], device.key)
        }
    }

    func testTheKeepAliveSkillTurnsAWearablesSwitchOnOffAndToggles() async throws {
        let key = WearableKeepAlive.scale
        let before = WearableKeepAlive.isOn(key)
        defer { WearableKeepAlive.set(before, for: key) }
        let hub = WearablesDevice()
        var out = try await hub.invoke("wearables_keep_alive", args: ["wearable": key, "state": "on"])
        XCTAssertEqual(out["keep_alive"] as? Bool, true)
        XCTAssertTrue(WearableKeepAlive.isOn(key))
        out = try await hub.invoke("wearables_keep_alive", args: ["wearable": key, "state": "toggle"])
        XCTAssertEqual(out["keep_alive"] as? Bool, false)
        XCTAssertFalse(WearableKeepAlive.isOn(key))
    }

    func testTheKeepAliveSkillRejectsAnUnknownWearable() async {
        do {
            _ = try await WearablesDevice().invoke("wearables_keep_alive", args: ["wearable": "toaster", "state": "on"])
            XCTFail("expected a bad argument")
        } catch {}
    }
}
