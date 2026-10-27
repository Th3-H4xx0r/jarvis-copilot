import XCTest
@testable import JarvisCopilot

/// Door-alarm and car actions (with Skip Face ID), server boards as actions, and the picker's index.
@MainActor
final class ButtonActionsTests: XCTestCase {

    // MARK: door + car, Skip Face ID

    private var sentDoor: [(String, String, Bool)] = []
    private var sentCar: [(String, String?, Bool)] = []
    private var asked: [PendingSecureAction] = []
    private var registered = true
    private var foreground = false
    private var serverHasKey = true

    override func setUp() async throws {
        sentDoor = []
        sentCar = []
        asked = []
        registered = true
        foreground = false
        serverHasKey = true
    }

    private func runner() -> SecureActionRunner {
        var r = SecureActionRunner()
        r.sendDoor = { [unowned self] action, proof, byButton in
            if byButton && !serverHasKey {
                throw APIError.http(status: 403, message: "This server has no button key. Approve it with Face ID.")
            }
            sentDoor.append((action, proof.signature, byButton))
            return DoorState(json: ["alarm": ["state": "disarmed"]])
        }
        r.armDoor = { _ in
            throw APIError.http(status: 409, message: "Front door is open. Close it or bypass it to arm.")
        }
        r.runCar = { [unowned self] command, proof, byButton in
            sentCar.append((command.rawValue, proof?.signature, byButton))
            return "Done"
        }
        r.faceIDProof = { _, _, _ in ToyotaApprover.Proof(nonce: "n", ts: 1, signature: "face") }
        r.buttonProof = { _, _ in ToyotaApprover.Proof(nonce: "n", ts: 1, signature: "button") }
        r.buttonKeyRegistered = { [unowned self] in registered }
        r.forgetButtonKey = { [unowned self] in registered = false }
        r.isForeground = { [unowned self] in foreground }
        r.askOnTap = { [unowned self] action, _ in asked.append(action); return true }
        return r
    }

    func testAPressedSkipButtonDisarmsWithTheButtonKey() async {
        let line = await runner().door(.disarm, skipFaceID: true, physical: true)
        XCTAssertEqual(line, "Disarmed")
        XCTAssertEqual(sentDoor.map(\.1), ["button"])
        XCTAssertEqual(sentDoor.map(\.2), [true])
        XCTAssertTrue(asked.isEmpty)
    }

    func testAShortcutNeverUsesTheButtonKey() async {
        _ = await runner().door(.disarm, skipFaceID: true, physical: false)
        XCTAssertTrue(sentDoor.isEmpty, "a Shortcut or Siri run goes to Face ID")
        XCTAssertEqual(asked.map(\.command), ["disarm"])
    }

    func testTheAlarmCardsUnlockedDisarmUsesTheButtonKey() async {
        let line = await runner().door(.disarm, skipFaceID: false, physical: false, unlocked: true)
        XCTAssertEqual(line, "Disarmed")
        XCTAssertEqual(sentDoor.map(\.1), ["button"])
        XCTAssertEqual(sentDoor.map(\.2), [true])
        XCTAssertTrue(asked.isEmpty, "no 'Tap to approve' notification")
    }

    func testAnUnlockedDisarmWithoutARegisteredKeyStillAsks() async {
        registered = false
        _ = await runner().door(.silence, skipFaceID: false, physical: false, unlocked: true)
        XCTAssertTrue(sentDoor.isEmpty)
        XCTAssertEqual(asked.map(\.command), ["silence"])
    }

    func testOnlyDisarmAndSilenceCardsAskForTheUnlock() {
        for id in ["door.armed_away", "door.armed_home", "door.entry", "door.triggered", "door.siren"] {
            XCTAssertTrue(StopButtonActivityIntent.needsUnlock(id), id)
        }
        for id in ["door.arming", "door.disarmed", "car.locked", ""] {
            XCTAssertFalse(StopButtonActivityIntent.needsUnlock(id), id)
        }
        XCTAssertTrue(StopButtonActivityIntent.press(buttonID: "", stateID: "door.entry", unlocked: true).unlocked)
        XCTAssertTrue(SecureActionPending.wantsButtonKey, "any Face ID approval registers the key the card signs with")
    }

    func testAQueuedPressNeverKeepsTheUnlock() {
        let press = ButtonPress(buttonID: "door", physical: false, shownState: "door.entry", unlocked: true)
        let later = ButtonPress(queueEntry: press.queueEntry)
        XCTAssertFalse(later.unlocked, "run later, it isn't the unlock he just did")
        XCTAssertEqual(later.shownState, "door.entry")
    }

    func testAServerWithoutTheKeyFallsBackToFaceIDAndIsRemembered() async {
        serverHasKey = false
        let line = await runner().door(.silence, skipFaceID: true, physical: true)
        XCTAssertFalse(registered, "the next Face ID registers the key again")
        XCTAssertEqual(asked.map(\.command), ["silence"])
        XCTAssertTrue(line.contains("Face ID"), line)
    }

    func testWithoutSkipTheOpenAppAsksFaceIDRightAway() async {
        foreground = true
        _ = await runner().door(.disarm, skipFaceID: false, physical: true)
        XCTAssertEqual(sentDoor.map(\.1), ["face"])
        XCTAssertEqual(sentDoor.map(\.2), [false])
    }

    func testArmingWithAnOpenDoorSaysWhich() async {
        let line = await runner().door(.armHome, skipFaceID: false, physical: true)
        XCTAssertTrue(line.contains("Front door is open"), line)
    }

    func testCarStopNeedsNoProofAndUnlockCanSkip() async {
        let r = runner()
        _ = await r.car("stop", skipFaceID: false, physical: true)
        _ = await r.car("unlock", skipFaceID: true, physical: true)
        XCTAssertEqual(sentCar.map(\.0), ["stop", "unlock"])
        XCTAssertEqual(sentCar.map(\.1), [nil, "button"])
        XCTAssertEqual(sentCar.map(\.2), [false, true])
    }

    func testSkipOnlyCountsForCommandsThatNeedFaceID() throws {
        XCTAssertTrue(RingAction.door(.disarm, skipFaceID: true).skipsFaceID)
        XCTAssertTrue(RingAction.door(.armHome, skipFaceID: true).skipsFaceID,
                      "an Arm button shows Disarm once armed: its switch counts for that")
        XCTAssertFalse(RingAction.door(.status, skipFaceID: true).skipsFaceID)
        XCTAssertTrue(RingAction.car(command: "stop", skipFaceID: true).skipsFaceID, "Stop shows Start once off")
        XCTAssertTrue(RingAction.car(command: "unlock", skipFaceID: true).skipsFaceID)
        XCTAssertFalse(RingAction.car(command: "unlock").skipsFaceID)
        for action in [RingAction.door(.disarm, skipFaceID: true), .car(command: "lock"),
                       .serverDevice(deviceID: "pod", skill: "pod_status", arguments: [:])] {
            XCTAssertEqual(try JSONDecoder().decode(RingAction.self, from: JSONEncoder().encode(action)), action)
        }
    }

    func testOnlyFreshTapsRunWhenTheAppOpens() async {
        let suite = UserDefaults(suiteName: "ButtonActionsTests-\(UUID().uuidString)")!
        let saved = SecureActionPending.defaults
        SecureActionPending.defaults = suite
        defer { SecureActionPending.defaults = saved }
        let now = Date()
        SecureActionPending.save([PendingSecureAction(target: .door, command: "disarm", at: now.addingTimeInterval(-60)),
                                  PendingSecureAction(target: .car, command: "unlock", at: now.addingTimeInterval(-3600))])
        foreground = true
        await SecureActionPending.drain(runner: runner(), now: now)
        XCTAssertEqual(sentDoor.map(\.0), ["disarm"])
        XCTAssertTrue(sentCar.isEmpty, "an hour-old tap doesn't unlock the car")
        XCTAssertEqual(SecureActionPending.load(), [])
    }

    func testAButtonThatSkipsFaceIDTellsTheWidget() throws {
        var b = ControlButton(id: "d", name: "Disarm", symbol: "lock.open", action: .door(.disarm, skipFaceID: true))
        let data = try JSONEncoder().encode([b])
        XCTAssertEqual(try JSONDecoder().decode([ControlButtonInfo].self, from: data).first?.skipsFaceID, true)
        b.action = .door(.disarm)
        let plain = try JSONEncoder().encode([b])
        XCTAssertNil(try JSONDecoder().decode([ControlButtonInfo].self, from: plain).first?.skipsFaceID)
    }

    // MARK: server boards

    private let rows: [[String: Any]] = [
        ["id": "phone", "skills": [["name": "flashlight_on"], ["name": "esp32_set_led"]]],
        ["id": "mac", "skills": [["name": "device_messages_send"]]],
        ["id": "pod", "name": "Jarvis Pod", "online": true,
         "skills": [["name": "pod_status"], ["name": "pod_settings_set",
                                             "input_schema": ["type": "object",
                                                              "properties": ["volume": ["type": "integer"]]]]]],
        ["id": "board", "name": "Hall board", "skills": [["name": "esp32_set_led"]]],
        ["id": "relayed", "skills": [["name": "esp32_set_led"]]],
    ]

    func testOnlyBoardsTheServerHoldsAreListed() {
        let boards = ServerDevices.parse(rows, onPhone: ["relayed"])
        XCTAssertEqual(boards.map(\.id), ["pod", "board"])
        XCTAssertEqual(boards.first?.online, true)
    }

    func testABoardActionRunsThroughTheServer() async {
        let savedFetch = ServerDevices.fetch, savedInvoke = ServerDevices.invoke, savedPaired = ServerDevices.isPaired
        defer {
            ServerDevices.fetch = savedFetch
            ServerDevices.invoke = savedInvoke
            ServerDevices.isPaired = savedPaired
            ServerDevices.forgetCache()
        }
        ServerDevices.forgetCache()
        ServerDevices.isPaired = { true }
        ServerDevices.fetch = { [rows] in rows }
        var calls: [(String, String, Int?)] = []
        ServerDevices.invoke = { device, skill, args in
            calls.append((device, skill, args["volume"] as? Int))
            return ["ok": true]
        }
        let line = await ServerDevices.run(deviceID: "pod", skill: "pod_settings_set", values: ["volume": "40"])
        XCTAssertEqual(calls.map(\.0), ["pod"])
        XCTAssertEqual(calls.first?.2, 40, "values are typed by the tool's schema")
        XCTAssertTrue(line.hasPrefix("pod_settings_set"), line)
        let missing = await ServerDevices.run(deviceID: "gone", skill: "pod_status", values: [:])
        XCTAssertTrue(missing.contains("isn't connected"), missing)
    }

    // MARK: the picker's index

    private func cap(_ name: String, _ properties: [String: [String: Any]] = [:]) -> DeviceCapability {
        DeviceCapability(name: name, description: "Does \(name). More detail here.",
                         inputSchema: DeviceCapability.schema(properties))
    }

    private var devices: [ActionPickerDevice] {
        [ActionPickerDevice(id: "bottle1", model: "VSITOO S1 Pro",
                      capabilities: [cap("bottle_sterilise", ["on": ["type": "boolean"]]), cap("bottle_get_status")]),
         ActionPickerDevice(id: "iphone", model: "iPhone",
                      capabilities: [cap("flashlight_on"), cap("clipboard_read"), cap("media_control")]),
         ActionPickerDevice(id: "door", model: DoorAlarmDevice.model,
                      capabilities: [cap("door_alarm_ring"), cap("door_show_alarm"), cap("door_show_approvals")]),
         ActionPickerDevice(id: "cam", model: "Dashcam", capabilities: [cap("dashcam_set_recording", ["enabled": ["type": "boolean"]])]),
         ActionPickerDevice(id: "glasses", model: "INMO GO3", capabilities: [],
                      unavailable: [UnavailableCapability(capability: cap("glasses_remote_key"),
                                                          reason: "Turn on Experimental Controls in Glasses")])]
    }

    func testTheIPhoneComesFirstAndEachDeviceHasItsOwnSection() {
        let sections = ActionPickerIndex.sections(devices: devices, serverDevices: [])
        XCTAssertEqual(sections.map(\.title), ["iPhone", "Bottle", "Door alarm", "Dashcam", "Glasses", "Ring", "Car"])
    }

    func testServerCallbacksAreNeverOffered() {
        let rows = ActionPickerIndex.sections(devices: devices, serverDevices: []).flatMap(\.rows)
        for hidden in ActionPickerIndex.hiddenSkills {
            XCTAssertFalse(rows.contains { $0.searchText.contains(hidden) }, hidden)
        }
        let door = ActionPickerIndex.sections(devices: devices, serverDevices: []).first { $0.title == "Door alarm" }
        XCTAssertEqual(door?.rows.map(\.title), DoorButtonCommand.allCases.map(\.title))
    }

    func testTheCatalogueReplacesThePhonesOwnCopyOfASkill() {
        let phone = ActionPickerIndex.sections(devices: devices, serverDevices: [])[0]
        XCTAssertTrue(phone.rows.contains { $0.title == "Torch on" })
        XCTAssertFalse(phone.rows.contains { $0.title == "Flashlight on" }, "no second torch row")
        XCTAssertTrue(phone.rows.contains { $0.title == "Clipboard read" })
        XCTAssertTrue(phone.rows.contains { $0.title == "Media control" },
                      "the catalogue only covers play/pause/next with fixed values; the tool does more")
    }

    func testOneTapOnOffForEnabledSwitchesToo() {
        let cam = ActionPickerIndex.sections(devices: devices, serverDevices: []).first { $0.title == "Dashcam" }
        XCTAssertEqual(cam?.rows.prefix(2).map(\.title), ["Set Recording on", "Set Recording off"])
    }

    func testSearchFindsByNameDetailOrToolAndDropsEmptySections() {
        let sections = ActionPickerIndex.sections(devices: devices, serverDevices: [])
        XCTAssertEqual(ActionPickerIndex.filter(sections, query: "sterilise").map(\.title), ["Bottle"])
        XCTAssertEqual(ActionPickerIndex.filter(sections, query: "bottle_get").flatMap(\.rows).map(\.title), ["Get status"])
        XCTAssertEqual(ActionPickerIndex.filter(sections, query: "disarm").map(\.title), ["Door alarm"])
        XCTAssertTrue(ActionPickerIndex.filter(sections, query: "zzz").isEmpty)
        XCTAssertEqual(ActionPickerIndex.filter(sections, query: "").count, sections.count)
    }

    func testExperimentalGlassesToolsAreGreyedWithTheReason() {
        let glasses = ActionPickerIndex.sections(devices: devices, serverDevices: []).first { $0.title == "Glasses" }
        XCTAssertEqual(glasses?.rows.first?.unavailable, "Turn on Experimental Controls in Glasses")
    }

    func testWithNoDevicesTheServerBackedSectionsStillShow() {
        let titles = ActionPickerIndex.sections(devices: [], serverDevices: []).map(\.title)
        XCTAssertEqual(titles, ["iPhone", "Ring", "Door alarm", "Car"])
    }

    func testTheCurrentActionIsTicked() {
        let rows = ActionPickerIndex.sections(devices: devices, serverDevices: []).flatMap(\.rows)
        XCTAssertEqual(rows.filter { $0.matches(.door(.disarm, skipFaceID: true)) }.map(\.title), ["Disarm"])
        XCTAssertEqual(rows.filter { $0.matches(.skill(id: "flashlight_on", arguments: [:])) }.map(\.title), ["Torch on"])
    }
}
