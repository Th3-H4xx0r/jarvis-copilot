import XCTest
@testable import JarvisCopilot

@MainActor
final class CarDeviceTests: XCTestCase {
    private func car(_ links: WearableLinks) -> CarDevice {
        // A stand-in "trailer" (not linked by default, unlike the real lights) is accepted too.
        let car = CarDevice(links: links, presence: CarPresence(), defaults: isolatedDefaults(),
                            accepted: ["dashcam", "trailer"])
        links.register(host: car)
        return car
    }

    func testNoControlsMeansOnlyTheStatusSkill() {
        let car = car(WearableLinks(storage: isolatedDefaults()))
        XCTAssertEqual(car.capabilities.map(\.name), ["car_get_status"])
    }

    func testALinkedControlBringsTheSetControlSkill() throws {
        let links = WearableLinks(storage: isolatedDefaults())
        let car = car(links)
        let recorder = ControlRecorder()
        let lights = FakeLinkable(kind: "trailer")
        lights.controls = [recorder.control("lights.power", .toggle(isOn: false))]
        links.register(lights)
        XCTAssertEqual(car.capabilities.map(\.name), ["car_get_status"], "not linked yet")

        try links.link("trailer", to: CarDevice.kind)
        let set = try XCTUnwrap(car.capabilities.first { $0.name == "car_set_control" })
        let props = set.inputSchema["properties"] as? [String: [String: Any]]
        XCTAssertEqual(props?["control"]?["enum"] as? [String], ["lights.power"])
        XCTAssertEqual(props?["value"]?["type"] as? String, "string", "one plain type for every provider")
    }

    func testSetControlValidatesThenRuns() async throws {
        let links = WearableLinks(storage: isolatedDefaults())
        let car = car(links)
        let recorder = ControlRecorder()
        let lights = FakeLinkable(kind: "trailer")
        lights.controls = [recorder.control("lights.power", .toggle(isOn: false))]
        links.register(lights)
        try links.link("trailer", to: CarDevice.kind)

        let out = try await car.invoke("car_set_control", args: ["control": "lights.power", "value": "on"])
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(recorder.received, [.toggle(true)])
        do {
            _ = try await car.invoke("car_set_control", args: ["control": "lights.power", "value": "purple"])
            XCTFail("a bad value must throw")
        } catch {}
        do {
            _ = try await car.invoke("car_set_control", args: ["control": "horn"])
            XCTFail("an unknown control must throw")
        } catch {}
        XCTAssertEqual(recorder.received.count, 1)
    }

    func testStatusListsTheCarAndWhatIsLinked() async throws {
        let links = WearableLinks(storage: isolatedDefaults())
        let car = car(links)
        let dashcam = FakeLinkable(kind: "dashcam", title: "A4")
        dashcam.linkStatus = LinkedWearableStatus(text: "Away", connected: false)
        links.register(dashcam)
        let status = try await car.invoke("car_get_status", args: [:])
        XCTAssertEqual((status["car"] as? [String: Any])?["color"] as? String, "Dark Cosmos")
        XCTAssertEqual(status["in_car"] as? Bool, false)
        let linked = try XCTUnwrap(status["linked"] as? [[String: Any]])
        XCTAssertEqual(linked.first?["title"] as? String, "A4")
        XCTAssertEqual(linked.first?["status"] as? String, "Away")
        XCTAssertEqual((status["controls"] as? [Any])?.count, 0)
    }

    func testTheCarKeepsItsIdAndIsNotItsOwnCarPlayRow() {
        let defaults = isolatedDefaults()
        let first = CarDevice(links: WearableLinks(storage: defaults), presence: CarPresence(), defaults: defaults)
        let again = CarDevice(links: WearableLinks(storage: defaults), presence: CarPresence(), defaults: defaults)
        XCTAssertEqual(first.deviceID, again.deviceID)
        XCTAssertTrue(first.deviceID.hasPrefix("car-"))
        XCTAssertFalse(first.carEnabled)
        XCTAssertTrue(first.accepts("dashcam"))
    }

    func testAnyOneSignalPutsThePhoneInTheCar() {
        XCTAssertFalse(CarPresence.isInCar(carPlay: false, carAudio: false, onDashcam: false))
        XCTAssertTrue(CarPresence.isInCar(carPlay: true, carAudio: false, onDashcam: false))
        XCTAssertTrue(CarPresence.isInCar(carPlay: false, carAudio: true, onDashcam: false))
        XCTAssertTrue(CarPresence.isInCar(carPlay: false, carAudio: false, onDashcam: true))
    }

    func testDashcamStatusReadsLikeItsCard() {
        XCTAssertEqual(DashcamLinkable.status(setUp: false, onCamera: true, phase: "Up to date", pendingUploads: 3),
                       LinkedWearableStatus(text: "Not set up", connected: false))
        XCTAssertEqual(DashcamLinkable.status(setUp: true, onCamera: true, phase: "Up to date", pendingUploads: 0),
                       LinkedWearableStatus(text: "Up to date", connected: true))
        XCTAssertEqual(DashcamLinkable.status(setUp: true, onCamera: false, phase: "Up to date", pendingUploads: 2),
                       LinkedWearableStatus(text: "Away · 2 to upload", connected: false))
        XCTAssertEqual(DashcamDevice.shared.linkKind, "dashcam")
    }
}
