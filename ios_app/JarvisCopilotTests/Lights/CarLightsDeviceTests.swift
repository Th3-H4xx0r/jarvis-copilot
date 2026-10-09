import XCTest
@testable import JarvisCopilot

@MainActor
final class CarLightsDeviceTests: XCTestCase {
    private func device(paired: Bool = true, connected: Bool = true) -> (CarLightsDevice, CarLightsManager) {
        let manager = CarLightsManager(defaults: isolatedDefaults())
        if paired {
            manager.pair(.init(id: UUID(), name: "MELK-OC21", rssi: -50))
            if connected { manager.markReadyForTesting(manager.controllers[0].id) }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lamps-\(UUID().uuidString).json")
        return (CarLightsDevice(manager: manager, layouts: CarLightLayoutStore(file: file), defaults: isolatedDefaults()), manager)
    }

    func testNothingButTheCatalogBeforeAnyLightsArePaired() async throws {
        let (d, _) = device(paired: false)
        XCTAssertTrue(d.controls.isEmpty)
        XCTAssertEqual(d.linkStatus.text, "Not paired")
        do { _ = try await d.invoke("lights_set", args: ["power": true]); XCTFail("needs paired lights") } catch {}
        let list = try await d.invoke("lights_list_effects", args: [:])
        XCTAssertEqual((list["scenes"] as? [Any])?.count, 28)
    }

    func testAwayFromTheCarEverythingIsUnavailable() async throws {
        let (d, m) = device(connected: false)
        XCTAssertEqual(d.linkStatus.text, "Not connected")
        XCTAssertEqual(d.controls.count, 4)
        XCTAssertTrue(d.controls.allSatisfy { !$0.enabled }, "greyed out, not queued")
        for (skill, args) in [("lights_set", ["color": "blue"]), ("lights_timer", ["timer": "on", "time": "18:00"]),
                              ("lights_setup", ["led_count": 60])] as [(String, [String: Any])] {
            do { _ = try await d.invoke(skill, args: args); XCTFail(skill) } catch {
                XCTAssertTrue(error.localizedDescription.contains("aren't connected"), error.localizedDescription)
            }
        }
        XCTAssertNotEqual(m.state(for: m.controllers[0].id).color, MelkColor(text: "blue"), "nothing kept for later")
        XCTAssertEqual(CarLightsScene.look(manager: m), .unavailable)
        // Status still answers.
        _ = try await d.invoke("lights_get_status", args: [:])
    }

    func testSetChangesTheConnectedLights() async throws {
        let (d, m) = device()
        _ = try await d.invoke("lights_set", args: ["color": "blue", "brightness": 40])
        let id = try XCTUnwrap(m.controllers.first?.id)
        XCTAssertEqual(m.state(for: id).color, MelkColor(text: "blue"))
        XCTAssertEqual(m.state(for: id).brightness, 40)
        _ = try await d.invoke("lights_set", args: ["effect": 193, "speed": 70])
        XCTAssertEqual(m.state(for: id).mode, .effect)
        XCTAssertEqual(m.state(for: id).effect, 193, "a numeric effect id works too")
        XCTAssertEqual(m.state(for: id).speed, 70)
        XCTAssertEqual(CarLightsScene.look(manager: m), .cycling)
    }

    func testBadValuesAreRefusedWithWhatIsAllowed() async {
        let (d, _) = device()
        for args: [String: Any] in [["color": "chartreuse"], ["effect": "disco ball"], ["target": "Dashboard"], [:]] {
            do { _ = try await d.invoke("lights_set", args: args); XCTFail("\(args)") } catch {}
        }
        do { _ = try await d.invoke("lights_setup", args: ["led_count": 5]); XCTFail("10–1000") } catch {}
        do { _ = try await d.invoke("lights_timer", args: ["timer": "on", "time": "25:00"]); XCTFail("bad time") } catch {}
    }

    func testTargetsAreTheLightsNotLamps() throws {
        let (d, m) = device()
        XCTAssertEqual(try d.targets("Car lights"), [m.controllers[0].id])
        XCTAssertNil(try d.targets("all"))
        XCTAssertNil(try d.targets(nil))
        XCTAssertThrowsError(try d.targets("Dashboard"), "no zones: a lamp is not a target")
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
        XCTAssertTrue(d.controls.allSatisfy(\.enabled))
        let color = try XCTUnwrap(d.controls.first { $0.id == "lights.color" })
        try await color.perform(try color.value(fromJSON: "green"))
        XCTAssertEqual(m.state(for: m.controllers[0].id).color, MelkColor(text: "green"))
        let power = try XCTUnwrap(d.controls.first { $0.id == "lights.power" })
        try await power.perform(.toggle(false))
        XCTAssertFalse(m.state(for: m.controllers[0].id).on)
        XCTAssertEqual(CarLightsScene.look(manager: m), .off)
        XCTAssertTrue(d.controls.allSatisfy(\.isWellFormed))
        XCTAssertTrue(CarDevice.accepted.contains(CarLightsDevice.kind))
        XCTAssertEqual(WearableLinks.defaults[CarLightsDevice.kind], CarDevice.kind)
    }
}
