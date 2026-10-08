import XCTest
@testable import JarvisCopilot

@MainActor
final class CarLightsStateTests: XCTestCase {
    func testColoursCoalesceAndAtMostTenASecondLeave() {
        var q = MelkWriteQueue()
        let t0 = Date()
        q.push(Melk.color(MelkColor(r: 1, g: 0, b: 0)), kind: .color)
        q.push(Melk.color(MelkColor(r: 2, g: 0, b: 0)), kind: .color)
        XCTAssertEqual(q.next(now: t0), Melk.color(MelkColor(r: 2, g: 0, b: 0)), "only the newest colour")
        q.push(Melk.color(MelkColor(r: 3, g: 0, b: 0)), kind: .color)
        XCTAssertNil(q.next(now: t0.addingTimeInterval(0.05)), "not within 100 ms")
        XCTAssertEqual(q.wait(now: t0.addingTimeInterval(0.05)) ?? -1, 0.05, accuracy: 0.001)
        XCTAssertEqual(q.next(now: t0.addingTimeInterval(0.1)), Melk.color(MelkColor(r: 3, g: 0, b: 0)))
        XCTAssertTrue(q.isEmpty)
    }

    func testAnEffectDropsAColourStillWaiting() {
        var q = MelkWriteQueue()
        q.push(Melk.color(MelkColor(r: 9, g: 9, b: 9)), kind: .color)
        q.push(Melk.effect(5), kind: .replacesColor)
        q.push(Melk.speed(40), kind: .other)
        let now = Date()
        XCTAssertEqual(q.next(now: now), Melk.effect(5))
        XCTAssertEqual(q.next(now: now), Melk.speed(40))
        XCTAssertNil(q.next(now: now.addingTimeInterval(1)), "the colour would have undone the effect")
    }

    func testChangesUpdateTheStateAndPickTheFrames() {
        var s = CarLightsState()
        let (afterEffect, frames) = CarLightsChange.effect(193).apply(to: s)
        XCTAssertEqual(afterEffect.mode, .effect)
        XCTAssertEqual(frames.map(\.0), [Melk.effect(193)])
        s = afterEffect
        // Brightness on the effects page uses the effects light mode.
        XCTAssertEqual(CarLightsChange.brightness(60).apply(to: s).1.map(\.0), [Melk.brightness(60, mode: .effects)])
        let (lightsMic, micFrames) = CarLightsChange.micEffect(2).apply(to: s)
        XCTAssertEqual(lightsMic.mode, .deviceMic)
        XCTAssertEqual(micFrames.map(\.0), [Melk.deviceMic(true), Melk.deviceMicEffect(2)])
        XCTAssertEqual(CarLightsChange.deviceMic(on: false).apply(to: lightsMic).0.mode, .color)
        let (off, _) = CarLightsChange.power(false).apply(to: s)
        XCTAssertEqual(off.summary, "Off")
        XCTAssertNil(off.displayColor)
        XCTAssertEqual(CarLightsChange.timer(MelkTimer(slot: .off, hour: 1, minute: 2, days: 3, enabled: true))
            .apply(to: CarLightsState()).0.timers.first { $0.slot == .off }?.hour, 1)
    }

    func testThePhoneMicRule() {
        LoudnessRotation.resetRotationForTests()
        var rotation = LoudnessRotation()
        for _ in 0..<20 { XCTAssertNil(rotation.next(db: 40.9), "warming up (whole dB: 40)") }
        XCTAssertEqual(rotation.count, 200)
        XCTAssertEqual(rotation.next(db: 44.9), MelkColor.black, "44 < 40 + 5")
        XCTAssertEqual(rotation.count, 205, "a quiet reading joins five times, never trimmed")
        XCTAssertEqual(rotation.next(db: 50), MelkColor.musicRotation[1], "the index is bumped first: green before red")
        XCTAssertEqual(rotation.next(db: 50), MelkColor.musicRotation[2])
    }

    func testEachPageSendsItsOwnBrightness() {
        var s = CarLightsState()
        s.mode = .color
        let (afterEffects, frames) = CarLightsChange.brightness(30, page: .effects).apply(to: s)
        XCTAssertEqual(frames.map(\.0), [Melk.brightness(30, mode: .effects)])
        XCTAssertEqual(afterEffects.effectBrightness, 30)
        XCTAssertEqual(afterEffects.brightness, s.brightness, "the colour page's value is its own")
        XCTAssertEqual(CarLightsChange.brightness(70, page: .rgb).apply(to: afterEffects).1.map(\.0),
                       [Melk.brightness(70, mode: .rgb)])
    }

    func testADueColourLeavesBeforeBrightness() {
        var q = MelkWriteQueue()
        q.push(Melk.color(MelkColor(r: 5, g: 5, b: 5)), kind: .color)
        q.push(Melk.brightness(50, mode: .rgb), kind: .other)
        let now = Date()
        XCTAssertEqual(q.next(now: now), Melk.color(MelkColor(r: 5, g: 5, b: 5)))
        XCTAssertEqual(q.next(now: now), Melk.brightness(50, mode: .rgb))
    }

    func testTheShippedLayoutIsValidAndEditable() throws {
        let layout = CarLightLayout.bundled
        XCTAssertFalse(layout.lamps.isEmpty, "CarLights.json missing from the bundle or invalid")
        XCTAssertTrue(layout.lamps.allSatisfy { $0.shape != nil })
        // Every lamp sits inside the car.
        for lamp in layout.lamps {
            let c = try XCTUnwrap(lamp.center)
            XCTAssertLessThan(abs(c.x), 1.0, lamp.id); XCTAssertLessThan(abs(c.z), 2.4, lamp.id)
            XCTAssertTrue((0...CarModel.beltHeight).contains(c.y), "\(lamp.id) is above the cut")
        }
        XCTAssertThrowsError(try CarLightLayout.decode(Data(#"{"version":1,"lamps":[{"id":"a","name":"A","controller":"main","at":[1,2]}]}"#.utf8)))
        XCTAssertThrowsError(try CarLightLayout.decode(Data(#"{"version":1,"lamps":[{"id":"a","name":"A","controller":"main","at":[0,0,0]},{"id":"a","name":"B","controller":"main","at":[0,0,0]}]}"#.utf8)))
    }

    func testLampsFindTheirController() throws {
        let layout = try CarLightLayout.decode(Data(#"""
            {"version":1,"lamps":[
              {"id":"dash","name":"Dash","controller":"main","at":[0,0.8,0.6]},
              {"id":"feet","name":"Feet","controller":"Footwells","at":[0,0.3,0.6]}]}
            """#.utf8))
        let controllers = [CarLightsController(id: "A", advertisedName: "MELK-OC1", name: "Car lights"),
                           CarLightsController(id: "B", advertisedName: "MELK-OC2", name: "Footwells")]
        XCTAssertEqual(CarLightLayout.controllerID(for: layout.lamps[0], in: controllers), "A")
        XCTAssertEqual(CarLightLayout.controllerID(for: layout.lamps[1], in: controllers), "B")
        XCTAssertNil(CarLightLayout.controllerID(for: layout.lamps[1], in: [controllers[0]]), "named controller not paired")
        XCTAssertEqual(layout.lamps(on: "A", controllers: controllers).map(\.id), ["dash"])
    }
}
