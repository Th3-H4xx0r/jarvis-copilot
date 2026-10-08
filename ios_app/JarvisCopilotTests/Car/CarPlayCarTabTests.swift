import XCTest
@testable import JarvisCopilot

@MainActor
final class CarPlayCarTabTests: XCTestCase {
    private let dashcam = CarPlayLinked(kind: "dashcam", title: "A4", status: "Up to date", connected: true,
                                        symbol: "video", screen: .dashcam)

    func testTheTabIsTheCarControlsThenLinkedDevices() {
        let s = CarPlayScreens.carTab(CarPlayCarInput(controls: [], linked: [dashcam]), others: [])
        XCTAssertEqual(s.map(\.title), ["Controls", "Linked devices"])
        XCTAssertEqual(s[0].rows.map(\.title), ["No controls yet"])
        XCTAssertEqual(s[0].rows[0].action, .none)
        XCTAssertEqual(s[1].rows.first?.title, "A4")
        XCTAssertEqual(s[1].rows.first?.action, .push(.dashcam), "same depth as before: tab → dashcam → clip")
    }

    func testANotSetUpDashcamRowDoesNotPush() {
        var notSetUp = dashcam
        notSetUp.screen = nil
        let s = CarPlayScreens.carTab(CarPlayCarInput(controls: [], linked: [notSetUp]), others: [])
        XCTAssertEqual(s[1].rows.first?.action, CarPlayAction.none)
    }

    func testUnlinkedCarWearablesKeepTheirRows() {
        let other = CarPlayCarDevice(id: "x", name: "Thing", status: "Connected", connected: true, isDashcam: false)
        let s = CarPlayScreens.carTab(CarPlayCarInput(controls: [], linked: []), others: [other])
        XCTAssertEqual(s.map(\.title), ["Controls", "Linked devices", "Other wearables"])
        XCTAssertEqual(s[1].rows.first?.title, "Nothing linked yet")
        XCTAssertEqual(s[2].rows.first?.action, .push(.device(id: "x")))
    }

    func testTogglesAndButtonsActInPlaceLevelsAndChoicesOpenAList() {
        let toggle = CarPlayControl(id: "lights.power", title: "Lights", symbol: "power", kind: .toggle(true))
        XCTAssertEqual(CarPlayScreens.controlRow(toggle).action, .control(id: "lights.power", .toggle(false)))
        XCTAssertEqual(CarPlayScreens.controlRow(toggle).detail, "On")
        let button = CarPlayControl(id: "lights.flash", title: "Flash", symbol: "bolt", kind: .button)
        XCTAssertEqual(CarPlayScreens.controlRow(button).action, .control(id: "lights.flash", .press))
        let level = CarPlayControl(id: "lights.level", title: "Brightness", symbol: "sun.max",
                                   kind: .level(value: 60, range: 0...100, step: 5, unit: "%"))
        XCTAssertEqual(CarPlayScreens.controlRow(level).action, .push(.wearableControl(id: "lights.level")))
        XCTAssertEqual(CarPlayScreens.controlRow(level).detail, "60 %")
        XCTAssertEqual(CarPlayScreen.wearableControl(id: "x").depth, 2)
    }

    func testPickersTickTheCurrentValueAndNeverPush() {
        let choice = CarPlayControl(id: "lights.mode", title: "Mode", symbol: "sparkles",
                                    kind: .choice(selected: "party", options: [.init(id: "calm", title: "Calm"),
                                                                               .init(id: "party", title: "Party")]))
        let rows = CarPlayScreens.controlPicker(choice).flatMap(\.rows)
        XCTAssertEqual(rows.map(\.title), ["Calm", "Party"])
        XCTAssertEqual(rows.map(\.checked), [false, true])
        XCTAssertEqual(rows[0].action, .control(id: "lights.mode", .choice("calm")))

        let level = CarPlayControl(id: "lights.level", title: "Brightness", symbol: "sun.max",
                                   kind: .level(value: 62, range: 0...100, step: 1, unit: nil))
        let levels = CarPlayScreens.controlPicker(level).flatMap(\.rows)
        XCTAssertEqual(levels.count, 12, "eleven spread levels plus the current one")
        XCTAssertEqual(levels.first { $0.checked }?.title, "62")
        XCTAssertFalse(levels.contains { if case .push = $0.action { return true } else { return false } })
    }

    func testLevelStepsStayOnTheStepAndWithinElevenRows() {
        XCTAssertEqual(CarPlayScreens.levelSteps(range: 0...4, step: 1), [0, 1, 2, 3, 4])
        XCTAssertEqual(CarPlayScreens.levelSteps(range: 0...100, step: 1).count, 11)
        XCTAssertEqual(CarPlayScreens.levelSteps(range: 0...100, step: 30), [0, 30, 60, 90], "snapped, never past the top step")
        XCTAssertEqual(CarPlayScreens.levelSteps(range: 5...5, step: 1), [5])
        XCTAssertEqual(CarPlayScreens.levelSteps(range: 0...0.6, step: 0.1).count, 7, "no level lost to 5.999…")
    }

    func testTheCurrentLevelIsAlwaysARow() {
        let level = CarPlayControl(id: "lights.temp", title: "Temp", symbol: "thermometer",
                                   kind: .level(value: 22, range: 16...30, step: 0.5, unit: "°"))
        let rows = CarPlayScreens.controlPicker(level).flatMap(\.rows)
        XCTAssertEqual(rows.filter(\.checked).map(\.title), ["22 °"])
        XCTAssertEqual(rows.first { $0.checked }?.action, .control(id: "lights.temp", .level(22)))
    }
}
