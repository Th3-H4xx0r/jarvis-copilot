import XCTest
@testable import JarvisCopilot

/// The Mac and the PC as button targets (2026-11-15): their jc-client tools and power actions show
/// in the action picker and on a Tools page from the Agents card, greyed while the computer
/// sleeps — except Wake, which goes through the server's wake path.
@MainActor
final class ComputerToolsTests: XCTestCase {

    private let rows: [[String: Any]] = [
        ["id": "pc-1", "name": "pranav-computer", "online": false,
         "skills": [["name": "chrome_open", "description": "Opens a page in Chrome. Then waits."],
                    ["name": "ui_look", "description": "Screenshot with numbered targets."]]],
        ["id": "mac-1", "name": "Pranavs-MacBook-Pro.local", "online": true,
         "skills": [["name": "vscode_run", "description": "Runs a VS Code command."]]],
        ["id": "board", "name": "Hall board", "skills": [["name": "esp32_set_led"]]],
        ["id": "browser-1", "name": "Chrome", "skills": [["name": "notes_add"]]],
    ]

    private let computers: [String: (name: String, computer: ServerComputer)] = [
        "pc-1": ("pranav-computer", ServerComputer(os: "windows", awake: false, wakeCapable: true)),
        "mac-1": ("Pranav's MacBook Pro", ServerComputer(os: "macos", awake: true)),
        "mac-2": ("Studio", ServerComputer(os: "macos", awake: false)),
    ]

    func testComputersAreListedWithTheirTools() {
        let devices = ServerDevices.parse(rows, onPhone: [], computers: computers)
        XCTAssertEqual(devices.map(\.id), ["pc-1", "mac-1", "board", "mac-2"],
                       "computers kept with any tools, boards as before, a plain browser left out, an unlisted Mac still offered")
        let pc = devices[0]
        XCTAssertEqual(pc.name, "pranav-computer")
        XCTAssertEqual(pc.capabilities.map(\.name), ["chrome_open", "ui_look"])
        XCTAssertEqual(pc.computer?.isPC, true)
        XCTAssertFalse(pc.online, "online is the Agents card's awake")
        XCTAssertEqual(devices[1].name, "Pranav's MacBook Pro")
        XCTAssertTrue(devices[1].online)
        XCTAssertNil(devices[2].computer)
        XCTAssertEqual(devices[3].capabilities.count, 0)
        XCTAssertEqual(ServerDevices.parse(rows, onPhone: []).map(\.id), ["board"], "without the Agents list, boards only")
    }

    func testPickerOffersAComputerSectionGreyedWhileAsleep() throws {
        let boards = ServerDevices.parse(rows, onPhone: [], computers: computers)
        let sections = ActionPickerIndex.sections(devices: [], serverDevices: boards)
        let pc = try XCTUnwrap(sections.first { $0.id == "server.pc-1" })
        XCTAssertEqual(pc.title, "pranav-computer")
        XCTAssertEqual(pc.symbol, "desktopcomputer")
        XCTAssertEqual(pc.rows.prefix(5).map(\.title), ["Wake PC", "Sleep", "Lock", "Unlock", "Screen"])
        XCTAssertNil(pc.rows[0].unavailable, "Wake works while the PC sleeps")
        XCTAssertEqual(pc.rows[1].unavailable, "pranav-computer is asleep — wake it first")
        let tool = try XCTUnwrap(pc.rows.first { $0.title == "Chrome open" })
        XCTAssertTrue(pc.rows.contains { $0.title == "UI look" }, "tool names keep their acronyms")
        XCTAssertEqual(tool.unavailable, "pranav-computer is asleep — wake it first")
        XCTAssertEqual(tool.detail, "Opens a page in Chrome")
        if case .pick(let action) = pc.rows[0].kind {
            XCTAssertEqual(action, .serverDevice(deviceID: "pc-1", skill: "computer_wake", arguments: [:]))
        } else { XCTFail("power actions are one tap") }
        if case .form(.serverDevice(let id, _, let cap)) = tool.kind {
            XCTAssertEqual(id, "pc-1"); XCTAssertEqual(cap.name, "chrome_open")
        } else { XCTFail("tools edit their arguments like other server devices") }

        let mac = try XCTUnwrap(sections.first { $0.id == "server.mac-1" })
        XCTAssertEqual(mac.symbol, "laptopcomputer")
        XCTAssertTrue(mac.rows.allSatisfy { $0.unavailable == nil }, "an awake Mac: everything available")
        XCTAssertEqual(mac.rows.first?.title, "Wake Mac")
        XCTAssertTrue(sections.contains { $0.id == "server.board" })
        XCTAssertFalse(ActionPickerIndex.filter(sections, query: "lock pc").isEmpty, "search finds power actions")
    }

    func testAPCThatCantBeWokenSaysWhy() {
        let c = ServerComputer(os: "windows", awake: false, wakeCapable: false, wakeReason: "This Wi-Fi adapter can't wake the PC")
        XCTAssertEqual(ComputerPowerAction.wake.unavailable(c, name: "PC"), "This Wi-Fi adapter can't wake the PC")
        XCTAssertNil(ComputerPowerAction.wake.unavailable(ServerComputer(os: "macos", awake: false), name: "Mac"))
    }

    func testPowerActionsMapToTheCardsServerCalls() {
        for action in ComputerPowerAction.allCases {
            XCTAssertEqual(ComputerPowerAction(skill: action.skill), action)
        }
        XCTAssertNil(ComputerPowerAction(skill: "chrome_open"))
        XCTAssertNil(ComputerPowerAction(skill: "computer_reboot"))
        XCTAssertEqual(ComputerPowerAction.wake.macPower, .wake)
        XCTAssertEqual(ComputerPowerAction.sleep.macPower, .letSleep)
        XCTAssertEqual(ComputerPowerAction.unlock.macPower, .unlock, "Unlock keeps the card's Face ID path")
        XCTAssertNil(ComputerPowerAction.screen.macPower)
        XCTAssertEqual(ComputerToolsCopy.powerActions(ServerComputer(os: "macos", awake: true)), [.sleep, .lock, .unlock, .screen])
        XCTAssertEqual(ComputerToolsCopy.powerActions(ServerComputer(os: "windows", awake: false)).first, .wake)
    }

    func testAComputerOffersItsPowerActionsToButtons() async {
        let savedFetch = ServerDevices.fetch, savedPaired = ServerDevices.isPaired, savedComputers = ServerDevices.computers
        defer {
            ServerDevices.fetch = savedFetch
            ServerDevices.isPaired = savedPaired
            ServerDevices.computers = savedComputers
            ServerDevices.forgetCache()
        }
        ServerDevices.forgetCache()
        ServerDevices.isPaired = { true }
        ServerDevices.fetch = { [rows] in rows }
        ServerDevices.computers = { [computers] in computers }
        let wake = await ServerDevices.offers(deviceID: "pc-1", skill: "computer_wake")
        let tool = await ServerDevices.offers(deviceID: "pc-1", skill: "chrome_open")
        let boardPower = await ServerDevices.offers(deviceID: "board", skill: "computer_wake")
        XCTAssertTrue(wake)
        XCTAssertTrue(tool)
        XCTAssertFalse(boardPower, "a board has no power actions")
    }

    // MARK: Widget creator moved to More

    func testWidgetCreatorIsAMoreTileNotASettingsRow() throws {
        XCTAssertTrue(MoreDestination.visible.contains(.widgets))
        XCTAssertEqual(MoreDestination.widgets.title, "Widget creator")
        XCTAssertEqual(MoreDestination.widgets.symbol, "square.grid.2x2.fill")
        XCTAssertEqual(MoreDestination.widgets.powerID, "widgets", "still hidden while the Widgets integration is off")
        let settings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("JarvisCopilot/Copilot/Settings/SettingsPage.swift")
        let text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertFalse(text.contains("WidgetCreatorPage"), "Settings no longer opens Widget creator")
    }
}
