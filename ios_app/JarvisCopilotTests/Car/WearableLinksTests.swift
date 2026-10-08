import XCTest
@testable import JarvisCopilot

@MainActor
final class WearableLinksTests: XCTestCase {
    func testTheDashcamRidesInTheCarByDefault() {
        let links = WearableLinks(storage: isolatedDefaults())
        XCTAssertEqual(links.host(of: "dashcam"), "car")
        XCTAssertNil(links.host(of: "ring"))
    }

    func testAnUnlinkSticksAcrossLaunches() {
        let defaults = isolatedDefaults()
        WearableLinks(storage: defaults).unlink("dashcam")
        XCTAssertNil(WearableLinks(storage: defaults).host(of: "dashcam"), "the default link must not come back")
    }

    func testOnlyAHostThatAcceptsAKindTakesIt() throws {
        let links = WearableLinks(storage: isolatedDefaults())
        links.register(host: FakeHost(accepts: ["dashcam", "lights"]))
        XCTAssertThrowsError(try links.link("ring", to: "car"))
        XCTAssertThrowsError(try links.link("lights", to: "garage"), "no such host")
        try links.link("lights", to: "car")
        XCTAssertEqual(links.host(of: "lights"), "car")
    }

    func testLinkedCardsLeaveTheListAndComeBackWhenUnlinked() {
        let links = WearableLinks(storage: isolatedDefaults())
        links.register(host: FakeHost(accepts: ["dashcam"]))
        let dashcam = FakeLinkable(kind: "dashcam")
        links.register(dashcam)
        XCTAssertEqual(links.children(of: "car").map(\.kind), ["dashcam"])
        XCTAssertTrue(links.topLevel.isEmpty)
        links.unlink("dashcam")
        XCTAssertTrue(links.children(of: "car").isEmpty)
        XCTAssertEqual(links.topLevel.map(\.kind), ["dashcam"])
        XCTAssertEqual(links.candidates(for: "car").map(\.kind), ["dashcam"])
    }

    func testAChildWhoseHostIsMissingStaysOnTheList() {
        let links = WearableLinks(storage: isolatedDefaults())
        links.register(FakeLinkable(kind: "dashcam"))
        XCTAssertEqual(links.topLevel.map(\.kind), ["dashcam"], "linked to a car that isn't registered: never hidden")
    }

    func testControlsGatherFromTheHostAndItsChildrenOnce() async throws {
        let links = WearableLinks(storage: isolatedDefaults())
        let recorder = ControlRecorder()
        let host = FakeHost(accepts: ["dashcam"])
        host.ownControls = [recorder.control("car.horn", .button)]
        links.register(host: host)
        let child = FakeLinkable(kind: "dashcam")
        child.controls = [recorder.control("dashcam.rec", .toggle(isOn: false)), recorder.control("car.horn", .button)]
        links.register(child)
        XCTAssertEqual(links.controls(for: "car").map(\.id), ["car.horn", "dashcam.rec"])

        try await links.perform("dashcam.rec", value: .toggle(true), on: "car")
        XCTAssertEqual(recorder.received, [.toggle(true)])
        do {
            try await links.perform("nope", value: .press, on: "car")
            XCTFail("unknown control must throw")
        } catch {}
    }

    func testADisabledControlRefuses() async {
        let links = WearableLinks(storage: isolatedDefaults())
        let recorder = ControlRecorder()
        let host = FakeHost(accepts: [])
        host.ownControls = [recorder.control("car.lock", .button, enabled: false)]
        links.register(host: host)
        do {
            try await links.perform("car.lock", value: .press, on: "car")
            XCTFail("disabled control must throw")
        } catch {}
        XCTAssertTrue(recorder.received.isEmpty)
    }

    func testOnlyAVisibleChangeInAChildRepublishes() {
        let links = WearableLinks(storage: isolatedDefaults())
        let child = FakeLinkable(kind: "dashcam")
        links.register(child)
        let settle = { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        child.subject.send()
        settle()
        let before = links.revision
        // Progress ticks that change nothing the host shows: no redraw.
        child.subject.send()
        child.subject.send()
        settle()
        XCTAssertEqual(links.revision, before)
        // A new status: one redraw.
        child.linkStatus = LinkedWearableStatus(text: "Uploading", connected: true)
        child.subject.send()
        settle()
        XCTAssertEqual(links.revision, before + 1)
    }

    func testMalformedControlsNeverReachTheHost() {
        let links = WearableLinks(storage: isolatedDefaults())
        let recorder = ControlRecorder()
        let host = FakeHost(accepts: [])
        host.ownControls = [
            recorder.control("car.ok", .level(value: 1, range: 0...10, step: 1, unit: nil)),
            recorder.control("car.inf", .level(value: 1, range: 0...Double.infinity, step: 1, unit: nil)),
            recorder.control("car.none", .choice(selected: "", options: [])),
        ]
        links.register(host: host)
        XCTAssertEqual(links.controls(for: "car").map(\.id), ["car.ok"])
        XCTAssertEqual(WearableControl.format(.infinity), "inf", "no Int(_:) trap")
        XCTAssertEqual(WearableControl.format(1e20), "1e+20")
        XCTAssertEqual(CarPlayScreens.levelSteps(range: 0...1, step: 1e-300).count, 11, "a tiny step can't overflow")
    }
}
