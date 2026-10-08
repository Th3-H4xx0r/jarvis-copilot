import XCTest
@testable import JarvisCopilot

@MainActor
final class CarLightsDeviceTests: XCTestCase {
    private func device(paired: Bool = true) -> (CarLightsDevice, CarLightsManager) {
        let manager = CarLightsManager(defaults: isolatedDefaults())
        if paired { manager.pair(.init(id: UUID(), name: "MELK-OC21", rssi: -50)) }
        return (CarLightsDevice(manager: manager, layout: .bundled, defaults: isolatedDefaults()), manager)
    }

    func testNothingButTheCatalogBeforeAnyLightsArePaired() async throws {
        let (d, _) = device(paired: false)
        XCTAssertTrue(d.controls.isEmpty)
        XCTAssertEqual(d.linkStatus.text, "Not paired")
        do { _ = try await d.invoke("lights_set", args: ["power": true]); XCTFail("needs paired lights") } catch {}
        let list = try await d.invoke("lights_list_effects", args: [:])
        XCTAssertEqual((list["scenes"] as? [Any])?.count, 28)
    }

    func testSetKeepsWhatWasSentForEveryLight() async throws {
        let (d, m) = device()
        _ = try await d.invoke("lights_set", args: ["color": "blue", "brightness": 40])
        let id = try XCTUnwrap(m.controllers.first?.id)
        XCTAssertEqual(m.state(for: id).color, MelkColor(text: "blue"))
        XCTAssertEqual(m.state(for: id).brightness, 40)
        _ = try await d.invoke("lights_set", args: ["effect": "7-Color Jump", "speed": 70])
        XCTAssertEqual(m.state(for: id).mode, .effect)
        XCTAssertEqual(m.state(for: id).effect, 193)
        XCTAssertEqual(m.state(for: id).speed, 70)
    }

    func testBadValuesAreRefusedWithWhatIsAllowed() async {
        let (d, _) = device()
        for args: [String: Any] in [["color": "chartreuse"], ["effect": "disco ball"], ["target": "boot"], [:]] {
            do { _ = try await d.invoke("lights_set", args: args); XCTFail("\(args)") } catch {}
        }
        do { _ = try await d.invoke("lights_setup", args: ["led_count": 5]); XCTFail("10–1000") } catch {}
        do { _ = try await d.invoke("lights_timer", args: ["timer": "on", "time": "25:00"]); XCTFail("bad time") } catch {}
    }

    func testALampMeansItsController() throws {
        let (d, m) = device()
        XCTAssertEqual(try d.targets("Dashboard"), [m.controllers[0].id])
        XCTAssertEqual(try d.targets("Car lights"), [m.controllers[0].id])
        XCTAssertNil(try d.targets("all"))
        XCTAssertNil(try d.targets(nil))
    }

    func testTimersAreSetFromNamesAndDays() async throws {
        let (d, m) = device()
        _ = try await d.invoke("lights_timer", args: ["timer": "off", "time": "23:15", "days": ["Mon", "Friday"], "enabled": true])
        let t = try XCTUnwrap(m.state(for: m.controllers[0].id).timers.first { $0.slot == .off })
        XCTAssertEqual(t.hour, 23); XCTAssertEqual(t.minute, 15)
        XCTAssertEqual(t.days, 0b0010001)
        XCTAssertTrue(t.enabled)
    }

    func testTheCarGetsFourControlsThatDriveTheLights() async throws {
        let (d, m) = device()
        XCTAssertEqual(d.controls.map(\.id), ["lights.power", "lights.brightness", "lights.color", "lights.effect"])
        let color = try XCTUnwrap(d.controls.first { $0.id == "lights.color" })
        try await color.perform(try color.value(fromJSON: "green"))
        XCTAssertEqual(m.state(for: m.controllers[0].id).color, MelkColor(text: "green"))
        let power = try XCTUnwrap(d.controls.first { $0.id == "lights.power" })
        try await power.perform(.toggle(false))
        XCTAssertFalse(m.state(for: m.controllers[0].id).on)
        XCTAssertTrue(d.controls.allSatisfy(\.isWellFormed))
        XCTAssertTrue(CarDevice.accepted.contains(CarLightsDevice.kind))
        XCTAssertEqual(WearableLinks.defaults[CarLightsDevice.kind], CarDevice.kind)
    }
}
