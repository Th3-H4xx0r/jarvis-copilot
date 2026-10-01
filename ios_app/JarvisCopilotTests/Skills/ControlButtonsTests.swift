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
    private var keepAlive: [String: Bool] = [:]

    override func setUp() async throws {
        keepAlive = [:]
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
                           notify: { [unowned self] title, body in notes.append((title, body)) },
                           keepAliveIsOn: { [unowned self] in keepAlive[$0] ?? false })
    }

    private func button(_ name: String, _ action: RingAction, symbol: String = "bolt.fill") -> ControlButton {
        ControlButton(id: UUID().uuidString, name: name, symbol: symbol, action: action)
    }

    func testASavedButtonIsWhatTheWidgetLists() {
        let s = store()
        let b = button("Play / pause", .skill(id: "play_pause", arguments: [:]), symbol: "playpause.fill")
        s.save(b)
        XCTAssertEqual(ControlButtonShelf.infos(defaults: defaults),
                       [ControlButtonInfo(id: b.id, name: "Play / pause", symbol: "playpause.fill",
                                          keepsState: false, isOn: false)])
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

    // MARK: buttons that keep their state

    private func info(_ id: String) -> ControlButtonInfo? {
        ControlButtonShelf.infos(defaults: defaults).first { $0.id == id }
    }

    func testAButtonThatKeepsItsStateFlipsAndTheWidgetSeesIt() async {
        let s = store()
        var b = button("Lamp", .prompt("toggle the lamp"))
        b.keepsState = true
        s.save(b)
        await s.press(b.id)
        XCTAssertEqual(info(b.id)?.isOn, true)
        XCTAssertEqual(info(b.id)?.caption, "On")
        XCTAssertEqual(info(b.id)?.keepsState, true)
        await s.press(b.id)
        XCTAssertEqual(info(b.id)?.isOn, false)
        XCTAssertEqual(info(b.id)?.caption, "Off")
    }

    func testTheSwitchsLineCanBeTheLastResultOrOwnText() async {
        let s = store()
        var b = button("Day", .skill(id: "battery_level", arguments: [:]))
        b.keepsState = true
        b.captionKind = .lastResult
        s.save(b)
        reply = "battery_level: 85%"
        await s.set(b.id, true)
        XCTAssertEqual(info(b.id)?.caption, "battery_level: 85%")
        b = s.button(b.id)!
        b.captionKind = .text
        b.captionText = "Saving battery"
        s.save(b)
        XCTAssertEqual(info(b.id)?.caption, "Saving battery")
    }

    func testAKeepAliveSwitchSetsExactlyThatStateAndShowsTheRealOne() async {
        let s = store()
        var b = button("X5 link", .skill(id: "keep_alive_x5ring", arguments: ["wearable": "x5ring", "state": "toggle"]))
        b.keepsState = true
        s.save(b)
        keepAlive["x5ring"] = true
        await s.set(b.id, true)
        XCTAssertEqual(ran.last, .skill(id: "keep_alive_x5ring", arguments: ["wearable": "x5ring", "state": "on"]))
        XCTAssertEqual(info(b.id)?.isOn, true)
    }

    func testASwitchRunsItsOnActionAndItsOffAction() async {
        let s = store()
        var b = button("Bottle UV", .wearable(deviceID: "b1", skill: "bottle_sterilise",
                                              arguments: ["on": "true", "confirm": "true"]))
        b.keepsState = true
        b.offAction = .wearable(deviceID: "b1", skill: "bottle_sterilise", arguments: ["on": "false"])
        s.save(b)
        await s.set(b.id, true)
        await s.set(b.id, false)
        XCTAssertEqual(ran, [b.action, b.offAction])
        XCTAssertEqual(info(b.id)?.isOn, false)
    }

    func testASwitchWithoutAnOffActionRunsTheSameActionBothWays() async {
        let s = store()
        var b = button("Lamp", .prompt("toggle the lamp"))
        b.keepsState = true
        s.save(b)
        await s.set(b.id, true)
        await s.set(b.id, false)
        XCTAssertEqual(ran, [b.action, b.action])
    }

    func testOnOffQuickActionsExistForEveryCommandWithAnOnSwitch() {
        let capability = DeviceCapability(name: "bottle_sterilise", description: "",
                                          inputSchema: DeviceCapability.schema([
                                              "on": ["type": "boolean"], "confirm": ["type": "boolean"],
                                          ], required: ["on"]))
        let quick = WearableQuickActions.actions(for: capability)
        XCTAssertEqual(quick.map(\.label), ["Sterilise now", "Stop sterilising"])
        XCTAssertEqual(quick.first?.arguments, ["on": "true", "confirm": "true"])
        XCTAssertEqual(quick.last?.arguments, ["on": "false"])
        let plain = DeviceCapability(name: "bottle_get_status", description: "", inputSchema: DeviceCapability.schema())
        XCTAssertTrue(WearableQuickActions.actions(for: plain).isEmpty)
    }

    func testAKeepAliveChangedElsewhereRelightsTheSwitch() {
        let s = store()
        var b = button("X5 link", .skill(id: "keep_alive_x5ring", arguments: ["wearable": "x5ring", "state": "toggle"]))
        b.keepsState = true
        s.save(b)
        XCTAssertEqual(info(b.id)?.isOn, false)
        keepAlive["x5ring"] = true
        s.syncKeepAlive()
        XCTAssertEqual(info(b.id)?.isOn, true)
    }

    func testAQueuedSwitchFlipIsRunWithItsValue() async {
        let s = store()
        var b = button("Lamp", .prompt("lamp"))
        b.keepsState = true
        s.save(b)
        ControlButtonShelf.queue(b.id + "=on", defaults: defaults)
        await s.runPending()
        XCTAssertEqual(info(b.id)?.isOn, true)
    }

    func testButtonsSavedBeforeStatesExistedStillLoad() throws {
        // Exactly what the first build wrote: no state fields at all.
        let action = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RingAction.prompt("hi")))
        let old: [[String: Any]] = [["id": "a", "name": "Old", "symbol": "bolt.fill", "action": action]]
        let data = try JSONSerialization.data(withJSONObject: old)
        defaults.setValue(data, forKey: ControlButtonShelf.key)
        let loaded = store().button("a")
        XCTAssertEqual(loaded?.name, "Old")
        XCTAssertEqual(loaded?.keepsState, false)
        XCTAssertEqual(loaded?.action, .prompt("hi"))
    }

    func testTheSymbolCatalogueHasThousandsAndSearches() {
        XCTAssertGreaterThan(SFSymbolCatalog.all.count, 5000)
        XCTAssertTrue(SFSymbolCatalog.search("bolt fill").contains { $0.name == "bolt.fill" })
        XCTAssertTrue(SFSymbolCatalog.search("", category: "health").allSatisfy { $0.categories.contains("health") })
        XCTAssertFalse(SFSymbolCatalog.all.contains { $0.name.hasSuffix(".ar") })
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
