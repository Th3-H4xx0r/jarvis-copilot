import XCTest
@testable import JarvisCopilot

/// Every frame byte-exact against the reference card (`magiclantern-re/PROTOCOL.md` §0).
final class MelkFramesTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }

    func testTheReferenceCard() {
        XCTAssertEqual(hex(Melk.power(true)), "7E 04 04 01 00 01 FF 00 EF")
        XCTAssertEqual(hex(Melk.power(false)), "7E 04 04 00 00 00 FF 00 EF")
        XCTAssertEqual(hex(Melk.color(MelkColor(r: 0x12, g: 0x34, b: 0x56))), "7E 07 05 03 12 34 56 10 EF")
        XCTAssertEqual(hex(Melk.musicColor(MelkColor(r: 1, g: 2, b: 3))), "7E 07 05 03 01 02 03 20 EF")
        XCTAssertEqual(hex(Melk.brightness(80, mode: .rgb)), "7E 04 01 50 01 FF FF 00 EF")
        XCTAssertEqual(hex(Melk.brightness(80, mode: .effects)), "7E 04 01 50 FF FF FF 00 EF")
        XCTAssertEqual(hex(Melk.colorTemperature(coldPercent: 30)), "7E 06 05 02 46 1E FF 08 EF")
        XCTAssertEqual(hex(Melk.whiteLevel(100)), "7E 05 05 01 64 FF FF 08 EF")
        XCTAssertEqual(hex(Melk.effect(0xD4)), "7E 05 03 D4 06 FF FF 00 EF")
        XCTAssertEqual(hex(Melk.speed(50)), "7E 04 02 32 FF FF FF 00 EF")
        XCTAssertEqual(hex(Melk.scene(28)), "7E 05 31 1C 07 FF FF 01 EF")
        XCTAssertEqual(hex(Melk.deviceMic(true)), "7E 04 07 01 FF FF FF 00 EF")
        XCTAssertEqual(hex(Melk.deviceMicEffect(3)), "7E 07 03 83 04 FF FF 00 EF")
        XCTAssertEqual(hex(Melk.deviceMicSensitivity(50)), "7E 04 06 32 FF FF FF 00 EF")
        XCTAssertEqual(hex(Melk.pinOrder(.grb)), "7E 06 81 02 01 03 FF 00 EF")
        XCTAssertEqual(hex(Melk.pixelCount(300)), "7E 07 21 2C 01 00 FF 00 EF")
        XCTAssertEqual(hex(Melk.timer(MelkTimer(slot: .off, hour: 23, minute: 30, days: 0b0011111, enabled: true))),
                       "7E 08 82 17 1E 00 01 9F EF")
        XCTAssertEqual(hex(Melk.timerQuery(.on)), "7E 08 82 FF FF FF 00 00 EF")
    }

    func testOutOfRangeValuesAreClampedNotTrusted() {
        XCTAssertEqual(hex(Melk.brightness(250, mode: .rgb)), "7E 04 01 64 01 FF FF 00 EF")
        XCTAssertEqual(hex(Melk.effect(255)), "7E 05 03 D4 06 FF FF 00 EF")
        XCTAssertEqual(hex(Melk.scene(0)), "7E 05 31 01 07 FF FF 01 EF")
        XCTAssertEqual(hex(Melk.pixelCount(5)), "7E 07 21 0A 00 00 FF 00 EF")
        XCTAssertEqual(hex(Melk.pixelCount(5000)), "7E 07 21 E8 03 00 FF 00 EF")
        XCTAssertEqual(Melk.power(true).count, 9)
    }

    func testTimeSyncUsesSundayZero() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2026-10-11 is a Sunday.
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 21, minute: 5, second: 9))!
        XCTAssertEqual(hex(Melk.timeSync(date, calendar: calendar)), "7E 07 83 15 05 09 00 FF EF")
    }

    func testTimerReadBack() {
        let t = Melk.parseTimer(Data([0x7E, 0x08, 0x82, 0x06, 0x1E, 0x00, 0x00, 0x81, 0xEF]))
        XCTAssertEqual(t, MelkTimer(slot: .on, hour: 6, minute: 30, days: 0x01, enabled: true))
        XCTAssertNil(Melk.parseTimer(Data([0x7E, 0x07, 0x83, 0, 0, 0, 0, 0xFF, 0xEF])), "a time reply is not a timer")
        XCTAssertEqual(Melk.parseTimer(Data([0x7E, 0x08, 0x82, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0xEF]))?.hour, 23,
                       "a never-set timer (FF FF) is read, clamped — as the app takes any value")
        XCTAssertNil(Melk.parseTimer(Data([0x7E])))
    }

    func testCapabilitiesComeFromTheName() {
        let oc = MelkCapabilities(name: "MELK-OC21W")
        XCTAssertTrue(oc.hasScenes); XCTAssertTrue(oc.hasDeviceMic); XCTAssertTrue(oc.hasTimers); XCTAssertTrue(oc.hasWhite)
        let tx = MelkCapabilities(name: "MELK-TX10")
        XCTAssertFalse(tx.hasDeviceMic); XCTAssertFalse(tx.hasTimers); XCTAssertFalse(tx.hasScenes)
        XCTAssertTrue(MelkCapabilities(name: "MELK-ACT3").hasTemperature)
        XCTAssertFalse(MelkCapabilities(name: "MELK-CT").hasTemperature, "CT must come after the first model letter")
        XCTAssertTrue(Melk.isController(name: "MELK-OE1"))
        XCTAssertFalse(Melk.isController(name: "ELK-BLEDOM"))
    }

    func testTheCatalogHasEveryEffectOnce() {
        let ids = MelkCatalog.effects.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(ids), Set(0...212))
        XCTAssertEqual(MelkCatalog.scenes.map(\.id), Array(1...28))
        XCTAssertEqual(MelkCatalog.effect(named: "7-color jump")?.id, 193)
        XCTAssertEqual(MelkCatalog.effect(named: "193")?.name, "7-Color Jump")
        XCTAssertEqual(MelkCatalog.scene(named: "starry sky")?.id, 8)
        XCTAssertNil(MelkCatalog.effect(named: "disco ball"))
    }

    func testColorsFromHexAndNames() {
        XCTAssertEqual(MelkColor(text: "#FF8000"), MelkColor(r: 255, g: 128, b: 0))
        XCTAssertEqual(MelkColor(text: "00ff00"), MelkColor(r: 0, g: 255, b: 0))
        XCTAssertEqual(MelkColor(text: "purple"), MelkColor.presets.first { $0.name == "Purple" }?.color)
        XCTAssertNil(MelkColor(text: "#12345"))
        XCTAssertNil(MelkColor(text: "chartreuse"))
    }
}
