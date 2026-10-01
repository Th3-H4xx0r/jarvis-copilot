import XCTest
@testable import JarvisCopilot

/// Decoding every X5 reply. The expected values are what the vendor's own SDK parsed out of
/// the same bytes (its sheet's worked examples), run offline as an oracle.
final class X5DecodersTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    /// The bytes after the opcode, as `X5Frames` hands them on. A 16-byte frame drops its checksum.
    private func payload(_ hex: String, frame: Bool = false) -> [UInt8] {
        let bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        if frame {
            let padded = bytes + [UInt8](repeating: 0, count: max(0, 15 - bytes.count))
            return Array(padded[1..<15])
        }
        return Array(bytes.dropFirst())
    }

    func testTimeAndProfile() {
        XCTAssertEqual(X5Decode.time(payload("41 24 08 08 08 10 47 06 F4", frame: true), calendar: utc),
                       date(2024, 8, 8, 8, 10, 47))
        let profile = X5Decode.profile(payload("42 00 25 AA 32 3B 30 30 30 30 30 30", frame: true))
        XCTAssertEqual(profile, X5Profile(male: false, age: 37, heightCm: 170, weightKg: 50, strideCm: 59,
                                          mac: "30:30:30:30:30:30"))
    }

    func testBatteryFirmwareMac() {
        let battery = X5Decode.battery(payload("13 50 01 0F A0", frame: true))
        XCTAssertEqual(battery?.battery, RingBattery(percent: 80, charging: true))
        XCTAssertEqual(battery?.millivolts, 4000)
        XCTAssertEqual(X5Decode.firmware(payload("27 01 02 03 04 24 08 27", frame: true))?.version, "1.2.3.4")
        XCTAssertEqual(X5Decode.mac(payload("22 11 22 33 44 55 66", frame: true)), "11:22:33:44:55:66")
    }

    func testMonitoringSchedule() {
        XCTAssertEqual(X5Decode.monitoring(payload("2B 02 00 00 23 59 7F 05 00 02", frame: true)),
                       X5Monitoring(on: true, startHour: 0, startMinute: 0, endHour: 23, endMinute: 59,
                                    weekdays: 0x7F, intervalMinutes: 5, type: .spo2))
    }

    func testLivePacket() {
        let live = X5Decode.live(payload("09 66 00 00 00 19 01 00 00 05 00 00 00 25 00 00 00 00 00 00 00 00 5A 01 00 00 00 00 00 00 00 00"))
        XCTAssertEqual(live?.steps, 102)
        XCTAssertEqual(live?.kcal ?? 0, 2.81, accuracy: 0.001)
        XCTAssertEqual(live?.km ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(live?.exerciseMinutes, 37)
        XCTAssertEqual(live?.heartRate, 0)
        XCTAssertEqual(live?.celsius ?? 0, 34.6, accuracy: 0.001)
        XCTAssertEqual(live?.spo2, 0)
        let worn = X5Decode.live(payload("09 66 00 00 00 19 01 00 00 05 00 00 00 25 00 00 00 00 00 00 00 48 5A 01 61 00 00 00 00 00 00 00"))
        XCTAssertEqual(worn?.heartRate, 72)
        XCTAssertEqual(worn?.spo2, 97)
    }

    func testDayTotals() {
        let total = X5Decode.dayTotal(payload("51 00 24 08 27 2E 00 00 00 11 00 00 00 03 00 00 00 93 00 00 00 00 00 00 00 00 00"))
        XCTAssertEqual(total?.daysAgo, 0)
        XCTAssertEqual(total?.day, DateComponents(year: 2024, month: 8, day: 27))
        XCTAssertEqual(total?.steps, 46)
        XCTAssertEqual(total?.exerciseSeconds, 17)
        XCTAssertEqual(total?.distanceMeters, 30)
        XCTAssertEqual(total?.calories100, 147)
    }

    func testStepBlocks() {
        let first = X5Decode.stepBlock(payload("52 00 00 24 08 08 23 58 19 1D 00 25 00 00 00 0A 13 00 00 00 00 00 00 00 00"), calendar: utc)
        XCTAssertEqual(first?.start, date(2024, 8, 8, 23, 58, 19))
        XCTAssertEqual(first?.steps, 29)
        XCTAssertEqual(first?.calories100, 37)
        XCTAssertEqual(first?.distanceMeters, 0)
        XCTAssertEqual(first?.perMinute, [10, 19, 0, 0, 0, 0, 0, 0, 0, 0])
        let second = X5Decode.stepBlock(payload("52 02 00 24 08 08 23 43 19 0D 00 19 00 01 00 0D 00 00 00 00 00 00 00 00 00"), calendar: utc)
        XCTAssertEqual(second?.id, 2)
        XCTAssertEqual(second?.distanceMeters, 10)
    }

    func testSleepChunk() {
        var hex = "53 00 00 24 08 23 13 36 00 36"
        for i in 0..<120 { hex += i < 4 ? " 05" : (i < 54 ? " 02" : " 00") }
        let chunk = X5Decode.sleep(payload(hex), calendar: utc)
        XCTAssertEqual(chunk?.start, date(2024, 8, 23, 13, 36, 0))
        XCTAssertEqual(chunk?.codes.count, 54)
        XCTAssertEqual(chunk?.codes.prefix(5).map { $0 }, [5, 5, 5, 5, 2])
    }

    func testContinuousHeartRate() {
        let partial = X5Decode.continuousHR(payload("54 00 00 24 08 08 22 59 27 4C 4E 00 00 00 00 00 00 00 00 00 00 00 00 00"), calendar: utc)
        XCTAssertEqual(partial?.start, date(2024, 8, 8, 22, 59, 27))
        XCTAssertEqual(partial?.bpm, [76, 78] + [Int](repeating: 0, count: 13))
        let full = X5Decode.continuousHR(payload("54 01 00 24 08 08 22 58 12 4C 49 4A 4D 50 51 50 4F 4E 4F 4C 4B 4B 4C 4C"), calendar: utc)
        XCTAssertEqual(full?.bpm, [76, 73, 74, 77, 80, 81, 80, 79, 78, 79, 76, 75, 75, 76, 76])
    }

    func testSingleReadings() {
        let hr = X5Decode.reading(payload("55 00 00 24 08 27 09 01 30 46"), calendar: utc)
        XCTAssertEqual(hr?.date, date(2024, 8, 27, 9, 1, 30))
        XCTAssertEqual(hr?.value, 70)
        XCTAssertEqual(X5Decode.reading(payload("66 00 00 24 08 09 00 00 23 61"), calendar: utc)?.value, 97)
        XCTAssertEqual(X5Decode.reading(payload("66 01 00 24 08 27 09 00 19 62"), calendar: utc)?.value, 98)
        XCTAssertEqual(X5Decode.reading(payload("60 00 00 24 08 09 00 00 23 61"), calendar: utc)?.value, 97)
    }

    func testHRVCarriesHeartRateStressAndBloodPressure() {
        let a = X5Decode.hrv(payload("56 00 00 24 08 09 00 59 30 40 00 4D 1E 75 3E"), calendar: utc)
        XCTAssertEqual(a?.date, date(2024, 8, 9, 0, 59, 30))
        XCTAssertEqual(a.map { [$0.hrv, $0.heartRate, $0.stress, $0.systolic, $0.diastolic] }, [64, 77, 30, 117, 62])
        let b = X5Decode.hrv(payload("56 01 00 24 08 08 22 59 30 32 00 4E 38 76 3F"), calendar: utc)
        XCTAssertEqual(b.map { [$0.hrv, $0.heartRate, $0.stress, $0.systolic, $0.diastolic] }, [50, 78, 56, 118, 63])
    }

    func testTemperatureDropsImplausibleReadings() {
        let warm = X5Decode.temperature(payload("62 00 00 24 08 09 00 59 59 5A 01"), calendar: utc)
        XCTAssertEqual(warm?.value ?? 0, 34.6, accuracy: 0.001)
        XCTAssertNil(X5Decode.temperature(payload("62 0A 00 24 08 27 08 56 59 D9 00"), calendar: utc))
    }

    func testWorkoutRecordFloatsAreIEEE() {
        let w = X5Decode.workout(payload("5C 00 00 24 09 03 10 36 47 00 8A 43 00 75 00 00 00 54 2A 0E 40 80 E3 6B 3D"), calendar: utc)
        XCTAssertEqual(w?.start, date(2024, 9, 3, 10, 36, 47))
        XCTAssertEqual(w?.sport, 0)
        XCTAssertEqual(w?.heartRate, 138)
        XCTAssertEqual(w?.seconds, 67)
        XCTAssertEqual(w?.steps, 117)
        XCTAssertEqual(w?.kcal ?? 0, 2.2213, accuracy: 0.001)
        XCTAssertEqual(w?.km ?? 0, 0.05759, accuracy: 0.0001)
    }

    func testWorkoutTicks() {
        let tick = X5Decode.tick(payload("18 48 64 00 00 00 00 00 20 41 3C 00 00 00 00 00 80 3F 00 00 00"))
        XCTAssertEqual(tick?.heartRate, 72)
        XCTAssertEqual(tick?.steps, 100)
        XCTAssertEqual(tick?.kcal ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(tick?.seconds, 60)
        XCTAssertEqual(tick?.km ?? 0, 1, accuracy: 0.001)
        XCTAssertFalse(tick?.ended ?? true)
        let auto = X5Decode.tick(payload("18 FF 02", frame: true))
        XCTAssertEqual(auto?.ended, true)
        XCTAssertEqual(auto?.autoEnded, true)
        let prompt = X5Decode.tick(payload("18 AA 01", frame: true))
        XCTAssertEqual(prompt?.inactivityPrompt, 1)
        XCTAssertEqual(prompt?.ended, false)
    }

    func testGestureKeys() {
        let expected: [UInt8: X5Gesture] = [1: .swipeUp, 2: .swipeDown, 3: .swipeLeft, 4: .swipeRight, 5: .click,
                                            0x0B: .doubleClick, 0x0C: .longPress, 0x0E: .hold5s, 0x0F: .hold10s]
        for (key, gesture) in expected {
            XCTAssertEqual(X5Decode.gesture(payload("0A \(String(format: "%02X", key))", frame: true)), gesture)
        }
        XCTAssertNil(X5Decode.gesture(payload("0A 06", frame: true)))
    }

    func testHIDGoalSkinTempMeasureStatus() {
        XCTAssertEqual(X5Decode.hid(payload("1C 00 01 00 2C 01 01", frame: true)),
                       X5HIDState(enabled: true, mode: .keys, awakeSeconds: 300))
        XCTAssertEqual(X5Decode.hidDelay(payload("1C 03 2C 01", frame: true)), 300)
        XCTAssertTrue(X5Decode.isTouchTimeout(payload("1C 08", frame: true)))
        XCTAssertFalse(X5Decode.isTouchTimeout(payload("1C 00 01 00 2C 01 01", frame: true)))
        XCTAssertEqual(X5Decode.goal(payload("4B 40 1F", frame: true)), 8000)
        XCTAssertEqual(X5Decode.skinTemp(payload("14 48 01 03 28", frame: true)) ?? 0, 32.8, accuracy: 0.001)
        XCTAssertEqual(X5Decode.measureStatus(payload("28 80 01 02", frame: true)), 1)
    }

    func testWorkoutReplies() {
        let started = X5Decode.workoutReply(payload("19 01 24 09 03 15 51 47", frame: true), calendar: utc)
        XCTAssertTrue(started.ok)
        XCTAssertEqual(started.start, date(2024, 9, 3, 15, 51, 47))
        XCTAssertFalse(X5Decode.workoutReply(payload("19 00", frame: true), calendar: utc).ok)
    }

    func testGestureMapsOntoTheSharedInputs() {
        XCTAssertEqual(X5Gesture.click.input, .tap)
        XCTAssertEqual(X5Gesture.doubleClick.input, .doubleTap)
        XCTAssertEqual(X5Gesture.longPress.input, .longPress)
        XCTAssertEqual(X5Gesture.swipeLeft.input, .swipeLeft)
        XCTAssertEqual(X5Gesture.hold10s.input, .holdTenSeconds)
        XCTAssertEqual(Set(X5Gesture.allCases.map(\.input)).count, 9)
        XCTAssertEqual(Set(X5Gesture.allCases.map(\.input)), Set(RingInput.x5))
    }

    /// The R12's inputs screen must not grow the X5's swipes and holds.
    func testR12InputListsAreUnchanged() {
        XCTAssertEqual(RingInput.available(touchSurface: false), [.tap, .doublePress, .triplePress, .shake])
        XCTAssertEqual(RingInput.available(touchSurface: true),
                       [.tap, .doublePress, .triplePress, .swipeForward, .swipeBack, .volumeUp, .volumeDown,
                        .longPress, .doubleTap, .shake])
    }
}
