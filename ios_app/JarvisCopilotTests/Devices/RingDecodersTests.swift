import XCTest
@testable import JarvisCopilot

/// Fixtures follow the SDK's response classes byte for byte (payload offsets).
final class RingDecodersTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func padded(_ bytes: [UInt8], to count: Int = 14) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: max(0, count - bytes.count))
    }

    func testCapabilityBlocksDecodeTheRingFlags() {
        var a = [UInt8](repeating: 0, count: 14)
        a[0] = 1
        a[3] = 0b0000_0010
        a[8] = 1
        a[10] = 0b0100_0000
        a[11] = 0b0000_0001
        a[13] = 0b0011_0000
        var b = [UInt8](repeating: 0, count: 14)
        b[1] = 0b1000_0101
        b[2] = 0b0100_1001
        b[6] = 0b1000_0000
        b[7] = 0b0000_1000
        b[8] = 0b1000_0000
        let caps = RingCapabilities(blockA: a, blockB: b)

        XCTAssertTrue(caps.temperature)
        XCTAssertTrue(caps.bloodOxygen)
        XCTAssertTrue(caps.newSleepProtocol)
        XCTAssertTrue(caps.manualBloodOxygen)
        XCTAssertTrue(caps.manualHeartRate)
        XCTAssertTrue(caps.stress)
        XCTAssertTrue(caps.hrv)
        XCTAssertFalse(caps.bloodPressure)
        XCTAssertFalse(caps.bloodSugar)
        XCTAssertTrue(caps.touch)
        XCTAssertTrue(caps.wearingCalibration)
        XCTAssertTrue(caps.gesture)
        XCTAssertTrue(caps.realTimeHeartRate)
        XCTAssertTrue(caps.intervalTemperature)
        XCTAssertTrue(caps.doNotDisturb)
        XCTAssertFalse(caps.noScreen)
        XCTAssertEqual(caps.touchModes, [.off, .music, .photo, .heartRate])
        XCTAssertEqual(caps.supportedMeasurements, [.heartRate, .spo2, .hrv, .stress, .temperature])
        XCTAssertTrue(caps.allFlags.contains { $0.name == "Real-time heart rate" && $0.on })
        XCTAssertFalse(RingCapabilities().isKnown)
    }

    func testTouchOnlyRingsReadTheSecondModeSet() {
        var b = [UInt8](repeating: 0, count: 14)
        b[1] = 0b0000_0001
        b[2] = 0b0000_0001
        b[5] = 0b0000_0110
        XCTAssertEqual(RingCapabilities(blockA: nil, blockB: b).touchModes, [.off, .video, .pageTurn])
    }

    func testBatteryAndTodayTotals() {
        XCTAssertEqual(RingDecode.battery(padded([0x55, 0x01])), RingBattery(percent: 85, charging: true))
        let totals = RingDecode.activity([0x00, 0x30, 0x39, 0x00, 0x07, 0xD0, 0x03, 0xD0, 0x90, 0x00, 0x23, 0x28, 0x00, 0x2D])
        XCTAssertEqual(totals, RingActivity(steps: 12345, runningSteps: 2000, calories: 250_000,
                                            distanceMeters: 9000, sportMinutes: 45))
        XCTAssertEqual(totals?.kilocalories, 250)
    }

    func testStepDetailHeaderScalesCaloriesAndRecordsCarryTheirDate() {
        let header = padded([0xF0, 0x00, 0x01])
        let first = padded([0x26, 0x09, 0x11, 40, 0, 2, 0x19, 0x00, 0xB0, 0x04, 0x84, 0x03])
        let last = padded([0x26, 0x09, 0x11, 41, 1, 2, 0x05, 0x00, 0x10, 0x00, 0x08, 0x00])

        XCTAssertFalse(RingDecode.isSlotReplyLast(header, first: true))
        XCTAssertFalse(RingDecode.isSlotReplyLast(first, first: false))
        XCTAssertTrue(RingDecode.isSlotReplyLast(last, first: false))
        XCTAssertTrue(RingDecode.isSlotReplyLast(padded([0xFF]), first: true))

        let slots = RingDecode.stepDetail([header, first, last])
        XCTAssertEqual(slots, [
            RingDatedStepSlot(dayKey: "2026-09-11", slot: RingStepSlot(slot: 40, steps: 1200, calories: 250, distanceMeters: 900)),
            RingDatedStepSlot(dayKey: "2026-09-11", slot: RingStepSlot(slot: 41, steps: 16, calories: 50, distanceMeters: 8)),
        ])
        XCTAssertTrue(RingDecode.stepDetail([padded([0xFF])]).isEmpty)
    }

    func testLegacySleepKeepsTheSevenQualityBytesPerSlot() {
        let record = [0x26, 0x09, 0x11, 12, 0, 1, 1, 2, 3, 4, 5, 6, 7, 0] as [UInt8]
        XCTAssertEqual(RingDecode.legacySleep([padded([0xF0]), record]), ["2026-09-11": [12: [1, 2, 3, 4, 5, 6, 7]]])
    }

    func testLegacyHeartRateArraySpansPackets() {
        let header = padded([0x00, 0x03, 0x05])
        let first = [0x01, 0x00, 0x00, 0x00, 0x00] + (60...68).map { UInt8($0) }
        let second = [0x02] + (70...82).map { UInt8($0) }

        var count = 0
        XCTAssertFalse(RingDecode.isDaySeriesLast(header, count: &count))
        XCTAssertFalse(RingDecode.isDaySeriesLast(first, count: &count))
        XCTAssertTrue(RingDecode.isDaySeriesLast(second, count: &count))

        let series = RingDecode.heartRateHistory([header, second, first])
        XCTAssertEqual(series?.intervalMinutes, 5)
        XCTAssertEqual(series?.values, (60...68).map(Double.init) + (70...82).map(Double.init))
        XCTAssertEqual(series?.readings.first?.minute, 0)
        XCTAssertEqual(series?.readings.last?.minute, 21 * 5)
    }

    func testHRVSeriesSkipsTheDayOffsetInPacketOne() {
        let header = padded([0x00, 0x02, 0x1E])
        let first = [0x01, 0x00] + (30...41).map { UInt8($0) }
        var count = 0
        XCTAssertFalse(RingDecode.isDaySeriesLast(header, count: &count))
        XCTAssertTrue(RingDecode.isDaySeriesLast(first, count: &count))
        XCTAssertEqual(RingDecode.hrvOrStress([header, first]), RingSeries(intervalMinutes: 30, values: (30...41).map(Double.init)))
        XCTAssertNil(RingDecode.hrvOrStress([padded([0xFF])]))
    }

    func testIntervalPacketsReadBytesOrHundredths() {
        let narrow = RingDecode.intervalPacket([0, 5, 2, 1, 70, 71, 0, 72], wide: false)
        XCTAssertEqual(narrow?.dayOffset, 0)
        XCTAssertEqual(narrow?.intervalMinutes, 5)
        XCTAssertEqual(narrow?.count, 2)
        XCTAssertEqual(narrow?.index, 1)
        XCTAssertEqual(narrow?.values, [70, 71, 0, 72])

        let wide = RingDecode.intervalPacket([1, 30, 1, 0, 0x6C, 0x0E, 0x70, 0x0E], wide: true)
        XCTAssertEqual(wide?.values, [36.92, 36.96])
    }

    func testSleepBlocksDeriveStartFromStageDurations() {
        let now = date(2026, 9, 11, 10)
        let day0: [UInt8] = [0, 14, 0x46, 0x05, 0xA4, 0x01, 2, 150, 3, 100, 4, 90, 5, 20, 2, 150]
        let day1: [UInt8] = [1, 8, 0x28, 0x05, 0x90, 0x01, 3, 200, 2, 250]
        let sessions = RingDecode.sleep([2] + day0 + day1, now: now, calendar: calendar)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].dayOffset, 0)
        XCTAssertEqual(sessions[0].session.end, date(2026, 9, 11, 7))
        XCTAssertEqual(sessions[0].session.start, date(2026, 9, 10, 22, 30))
        XCTAssertEqual(sessions[0].session.reportedStartMinute, 1350)
        XCTAssertEqual(sessions[0].session.minutes(of: RingSleepStage.deep), 100)
        XCTAssertEqual(sessions[0].session.asleepMinutes, 490)
        XCTAssertEqual(sessions[1].dayOffset, 1)
        XCTAssertEqual(sessions[1].session.end, date(2026, 9, 10, 6, 40))
        XCTAssertEqual(sessions[1].session.start, date(2026, 9, 9, 23, 10))
        XCTAssertTrue(RingDecode.sleep([0], now: now, calendar: calendar).isEmpty)
    }

    func testNapsAreRunsOfAsleepPairs() {
        let now = date(2026, 9, 11, 18)
        let block: [UInt8] = [0, 10, 0x0C, 0x03, 0x84, 0x03, 1, 20, 0, 30, 1, 15]
        let naps = RingDecode.naps([1] + block, now: now, calendar: calendar)
        XCTAssertEqual(naps.first?.naps, [
            RingNap(start: date(2026, 9, 11, 13), end: date(2026, 9, 11, 13, 20)),
            RingNap(start: date(2026, 9, 11, 13, 50), end: date(2026, 9, 11, 14, 5)),
        ])
    }

    func testManualListsDropEmptyAndOutOfDayReadings() {
        let list = RingDecode.manualList([1, 0x58, 0x02, 72, 0xDC, 0x05, 80, 0x62, 0x02, 0])
        XCTAssertEqual(list?.dayOffset, 1)
        XCTAssertEqual(list?.values, [RingTimedValue(minute: 600, value: 72)])
    }

    func testHourlyMinMaxRecordsSplitOddAndEvenBytes() {
        var record = [UInt8](repeating: 0, count: 49)
        record[0] = 2
        record[1] = 99
        record[2] = 95
        record[3] = 98
        record[4] = 94
        let other = [UInt8](repeating: 0, count: 49)
        let decoded = RingDecode.hourlyMinMax(record + other)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].dayOffset, 2)
        XCTAssertEqual(Array(decoded[0].value.max.prefix(2)), [99, 98])
        XCTAssertEqual(Array(decoded[0].value.min.prefix(2)), [95, 94])
        XCTAssertEqual(decoded[0].value.max.count, 24)
        XCTAssertEqual(decoded[0].value.min.count, 24)
    }

    func testBloodPressureRecordsAreLocalTimeAndEndOnFF() {
        let zone = TimeZone(secondsFromGMT: 3600)!
        let ts: UInt32 = 1_700_003_600
        let record = padded([UInt8(ts & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8((ts >> 16) & 0xFF), UInt8(ts >> 24), 80, 120])
        XCTAssertEqual(RingDecode.bloodPressureRecord(record, timeZone: zone),
                       RingBloodPressureReading(time: Date(timeIntervalSince1970: 1_700_000_000), systolic: 120, diastolic: 80))
        XCTAssertTrue(RingDecode.isBloodPressureEnd(padded([0xFF, 0xFF, 0xFF, 0xFF])))
    }

    func testMeasurementReadings() {
        let notWorn = RingDecode.measurement(padded([0x01, 0x01, 0x00]))
        XCTAssertEqual(notWorn?.errorCode, 1)
        let bp = RingDecode.measurement(padded([0x02, 0x00, 0x48, 0x78, 0x50]))
        XCTAssertEqual(bp?.systolic, 120)
        XCTAssertEqual(bp?.diastolic, 80)
        XCTAssertEqual(RingDecode.measurement(padded([0x0B, 0x00, 165]))?.celsius, 36.5)
    }

    func testSettingsReplies() {
        XCTAssertEqual(RingDecode.heartRateMonitor(padded([0x01, 0x01, 0x0A, 0x00, 0x32, 0xB4, 0x01, 0x00])),
                       RingHeartRateMonitor(enabled: true, intervalMinutes: 10, start: 5, lowWarning: 50,
                                            highWarning: 180, mainSwitch: 1, maxInterval: 60))
        XCTAssertNil(RingDecode.heartRateMonitor(padded([0x02, 0x01])))
        XCTAssertEqual(RingDecode.spo2Monitor(padded([0x01, 0x01, 0x3C])), RingSpO2Monitor(enabled: true, intervalMinutes: 60))
        XCTAssertEqual(RingDecode.stressMonitor(padded([0x01, 0x00])), RingStressMonitor(enabled: false))
        XCTAssertEqual(RingDecode.hrvMonitor(padded([0x01, 0x01, 0x0A, 0x60])),
                       RingHRVMonitor(enabled: true, intervalSupported: true, intervalMinutes: 60))
        XCTAssertEqual(RingDecode.hrvMonitor(padded([0x01, 0x00, 0x00, 0x1E])),
                       RingHRVMonitor(enabled: false, intervalSupported: false, intervalMinutes: 30))
        XCTAssertEqual(RingDecode.temperatureMonitor(padded([0x03, 0x01, 0x01, 0x1E, 0x05, 0x0A, 0x0A, 0xB9])),
                       RingTemperatureMonitor(enabled: true, intervalMinutes: 30, start: 5, remindIntervalMinutes: 10,
                                              alertFlags: 10, customAlertCelsius: 38.5))
        XCTAssertEqual(RingDecode.touch(padded([0x01, 0x00, 0x01, 0x05, 0x01])),
                       RingTouchSettings(isTouch: true, mode: 1, sleepTime: 5, touchSleep: true, strength: 0))
        XCTAssertEqual(RingDecode.touch(padded([0x01, 0x01, 0x05, 0x02]))?.touchMode, .photo)
        XCTAssertEqual(RingDecode.touch(padded([0x01, 0x01, 0x05, 0x02]))?.strength, 2)
        XCTAssertEqual(RingDecode.dnd(padded([0x01, 0x01, 22, 0, 7, 0, 0])),
                       RingDND(enabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0, manual: false))
        XCTAssertEqual(RingDecode.temperatureUnit(padded([0x01, 0x01, 0x02])), RingTemperatureUnit(enabled: true, celsius: false))
        XCTAssertEqual(RingDecode.goals([0x01, 0x10, 0x27, 0x00, 0xE0, 0x93, 0x04, 0x88, 0x13, 0x00, 0x5A, 0x00, 0xE0, 0x01]),
                       RingGoals(steps: 10000, calories: 300_000, distanceMeters: 5000, sportMinutes: 90, sleepMinutes: 480))
        XCTAssertEqual(RingDecode.profile(padded([0x01, 0x00, 0x01, 0x01, 0x1E, 0xA5, 0x3C, 0x78, 0x50, 0xA0, 0x02])),
                       RingProfile(use24Hour: true, metric: false, sex: 1, age: 30, heightCm: 165, weightKg: 60,
                                   systolic: 120, diastolic: 80, heartRateWarning: 160, open: 2))
        XCTAssertEqual(RingDecode.wearHand(padded([0x03, 0x01, 0x01, 0x05, 0x0A, 0x01, 0x16, 0x00, 0x07, 0x00])),
                       RingWearHand(enabled: true, left: true, screenLight: 5, maxLight: 10, dndAllDay: false,
                                    startMinute: 1320, endMinute: 420))
        XCTAssertEqual(RingDecode.sedentary(padded([0x09, 0x30, 0x18, 0x00, 0x7F, 0x3C])),
                       RingSedentary(startHour: 9, startMinute: 30, endHour: 18, endMinute: 0, weekMask: 127, cycleMinutes: 60))
    }

    func testDeviceEvents() {
        XCTAssertEqual(RingDecode.deviceEvent(padded([12, 80, 1])), .battery(RingBattery(percent: 80, charging: true)))
        XCTAssertEqual(RingDecode.deviceEvent(padded([18, 0x00, 0x10, 0x00, 0x00, 0x27, 0x10, 0x00, 0x03, 0xE8])),
                       .liveActivity(RingActivity(steps: 4096, runningSteps: 0, calories: 10000, distanceMeters: 1000, sportMinutes: 0)))
        XCTAssertEqual(RingDecode.deviceEvent(padded([45, 3])), .touchKey(3))
        XCTAssertEqual(RingDecode.deviceEvent(padded([55, 71])), .instantHeartRate(71))
        XCTAssertEqual(RingDecode.deviceEvent(padded([61, 0x6D, 0x01])), .liveTemperature(36.5))
        XCTAssertEqual(RingDecode.deviceEvent(padded([62])), .phoneStillTimeRequest)
        XCTAssertEqual(RingDecode.deviceEvent(padded([64, 97])), .instantSpO2(97))
        XCTAssertEqual(RingDecode.deviceEvent(padded([1])), .dataUpdated(.heartRate))
        XCTAssertEqual(RingDecode.deviceEvent(padded([39])), .dataUpdated(.temperature))
        XCTAssertEqual(RingDecode.deviceEvent([99, 1, 2]), .other(type: 99, payload: [99, 1, 2]))
        let calibration = RingDecode.calibration(padded([1, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        XCTAssertEqual(calibration.dataType, 1)
        XCTAssertEqual(calibration.result, 1)
    }

    func testDayKeysRoundTrip() {
        let now = date(2026, 9, 11, 9)
        XCTAssertEqual(RingDates.dayKey(RingDates.midnight(daysAgo: 1, now: now, calendar: calendar), calendar: calendar), "2026-09-10")
        XCTAssertEqual(RingDates.daysAgo(key: "2026-09-08", now: now, calendar: calendar), 3)
        XCTAssertNil(RingDates.date(forKey: "2026-13-01", calendar: calendar))
    }
}
