import XCTest
@testable import JarvisCopilot

/// The band's 5-minute records and sleep folded into the shared day model, so the ring charts,
/// the Health tab and the server payload read the band without knowing it is not a ring. The
/// inputs are decoded from the same SDK-verified frames BandCodecTests uses.
@MainActor
final class BandDayMapperTests: XCTestCase {

    private var directory: URL!
    private var store: RingHistoryStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BandDayMapperTests-\(UUID().uuidString)")
        store = RingHistoryStore(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func frames(_ hex: [String]) -> [[UInt8]] {
        hex.map { h in
            var out: [UInt8] = []
            var i = h.startIndex
            while i < h.endIndex {
                let j = h.index(i, offsetBy: 2)
                out.append(UInt8(h[i..<j], radix: 16)!)
                i = j
            }
            return out
        }
    }

    private var now: Date { date(2026, 10, 4, 9, 0) }

    /// 08:30 (420 steps, HR 72/74/–/78/80, BP 118/76, SpO₂ 97/98/–/96/97, stress 30, 36.2 °C)
    /// and 08:35 (pulse 61…65) — the SDK's parse is quoted in BandCodecTests.testDailyRecords.
    private var morning: [BandDailyRecord] {
        BandDecode.daily(frames(["df01000008000409000000000014000000b1040a", "df02000104081eb20a01a40023013648440001b4",
                                 "df030002050000000000b505484a004e50b80276", "df0400034cb9056162006061c1051e00000000c3",
                                 "df0500040463016a010000000000000000000000", "df06000008000209000000000014000000b1040a",
                                 "df070001040823b20a00000002000000000000b4", "df080002053d3e3f4041b5050000000000000000",
                                 "dfffff0100000000000000000000000000000000"]), day: 0, calendar: utc, now: now)
    }

    /// 23:55 the night before, HRV 23 and 28 (BandCodecTests.testDailyRecordWithHRVGlucoseAndBloodLipids).
    private var lateNight: [BandDailyRecord] {
        BandDecode.daily(frames(["df01000009000809000000000014000000b1040a", "df020001031737b20a000c0004000902580001b4",
                                 "df030002050000000000b5053a39380037b30601", "df0400030203000000b6050e0f00100eb7330050",
                                 "df050004524f5150534e505251464b48004a4749", "df06000548464a00000000000000000000000000",
                                 "df07000600000000000000000000000000000000", "df08000700be021e02bf05090a0b0000c20a1601",
                                 "df0900080c0179005400f4010000000000000000", "dfffff0100000000000000000000000000000000"]),
                         day: 1, calendar: utc, now: now)
    }

    /// Two segments ending 01:10 and 06:30 (BandCodecTests.testPreciseSleepTwoSegmentsThreeBitCurve).
    private var night: [BandSleep] {
        BandDecode.sleep(frames(["e0070200a13f00a3220a03170a0a04010a00463c", "e006020032281e00020000001e0050000a007800",
                                 "e005020014000a00050001a403004d00a5100020", "e0040200002000000000000000400020008000a1",
                                 "e00302003b00a3220a0402000a04061e0050555a", "e00202004b5800040000005a0096001e000e0128",
                                 "e0010200000000090001a403005f02a50c002000", "e000020000000000400020002000000000000000"]),
                         calendar: utc, now: now)
    }

    func testRecordsFillTheDay() {
        XCTAssertEqual(morning.count, 2)
        let day = BandDayMapper.day(RingDay(date: "2026-10-04"), records: morning, sleep: [], date: now, calendar: utc)
        XCTAssertEqual(day.date, "2026-10-04")
        // 08:30 is minute 510, slot 34 (08:30–08:44); 08:35 had no steps.
        XCTAssertEqual(day.stepSlots, [RingStepSlot(slot: 34, steps: 420, calories: 18500, distanceMeters: 310)])
        XCTAssertEqual(day.activity?.steps, 420)
        XCTAssertEqual(day.activity?.distanceMeters, 310)
        XCTAssertEqual(day.activity?.sportMinutes, 5)
        // Heart rate minute by minute: 08:30 72, 08:31 74, 08:32 none, …, 08:35 61 (pulse).
        let hr = day.heartRate!
        XCTAssertEqual(hr.intervalMinutes, 1)
        XCTAssertEqual(Array(hr.values[510...519]), [72, 74, 0, 78, 80, 61, 62, 63, 64, 65])
        XCTAssertEqual(day.bloodPressure, [RingBloodPressureReading(time: date(2026, 10, 4, 8, 30), systolic: 118, diastolic: 76)])
        XCTAssertEqual(day.spo2?.min[8], 96)
        XCTAssertEqual(day.spo2?.max[8], 98)
        XCTAssertEqual(day.stress?.values[102], 30)
        XCTAssertEqual(day.temperature?.values[102] ?? 0, 36.2, accuracy: 0.001)
        let summary = day.summary
        XCTAssertEqual(summary.steps, 420)
        XCTAssertEqual(summary.heartRateMin, 61)
        XCTAssertEqual(summary.heartRateMax, 80)
        XCTAssertEqual(summary.bloodPressureSystolic, 118)
    }

    func testRecordsOfAnotherDayAreLeftOut() {
        let day = BandDayMapper.day(RingDay(date: "2026-10-04"), records: lateNight, sleep: [], date: now, calendar: utc)
        XCTAssertNil(day.heartRate)
        let before = BandDayMapper.day(RingDay(date: "2026-10-03"), records: lateNight, sleep: [],
                                       date: date(2026, 10, 3, 12, 0), calendar: utc)
        // 23:55 = minute 1435, the last 5-minute bucket; HRV is the mean of the record's minutes.
        XCTAssertEqual(before.hrv?.values[287] ?? 0, 25.5, accuracy: 0.001)
        XCTAssertEqual(Array(before.heartRate!.values[1435...1439]), [58, 57, 56, 0, 55])
    }

    func testSleepIsKeyedToTheDayItEnds() {
        let day = BandDayMapper.day(RingDay(date: "2026-10-04"), records: [], sleep: night, date: now, calendar: utc)
        XCTAssertEqual(day.sleep.count, 2)
        // 01:10 segment: 8 points over 120 minutes, 15 each — light, deep, REM, light, awake.
        let first = day.sleep[0]
        XCTAssertEqual(first.start, date(2026, 10, 3, 23, 10))
        XCTAssertEqual(first.stages, [RingSleepStage(stage: RingSleepStage.light, minutes: 30),
                                      RingSleepStage(stage: RingSleepStage.deep, minutes: 45),
                                      RingSleepStage(stage: RingSleepStage.rem, minutes: 15),
                                      RingSleepStage(stage: RingSleepStage.light, minutes: 15),
                                      RingSleepStage(stage: RingSleepStage.awake, minutes: 15)])
        XCTAssertEqual(first.reportedStartMinute, 23 * 60 + 10)
        // The longer night leads the summary: 6 points over 270 minutes, 45 each.
        let summary = day.summary
        XCTAssertEqual(summary.sleepMinutes, 270)
        XCTAssertEqual(summary.deepMinutes, 90)
        XCTAssertEqual(summary.remMinutes, 45)
        XCTAssertEqual(summary.lightMinutes, 135)
        // Nothing of it lands on the day before.
        let before = BandDayMapper.day(RingDay(date: "2026-10-03"), records: [], sleep: night,
                                       date: date(2026, 10, 3, 12, 0), calendar: utc)
        XCTAssertTrue(before.sleep.isEmpty)
    }

    func testAShortDaytimeSleepIsANap() {
        let nap = BandSleep(start: date(2026, 10, 4, 13, 0), end: date(2026, 10, 4, 13, 40), curve: [1, 1, 0, 1],
                            sleepType: 1, quality: 2, nightScore: 0, deepScore: 0, efficiencyScore: 0, fallAsleepScore: 0,
                            durationScore: 0, deepMinutes: 10, lightMinutes: 30, otherMinutes: 0, totalMinutes: 40,
                            firstDeepMinutes: 10, nightWakeMinutes: 0, nightDeepMean: 0, insomniaScore: 0, insomniaCount: 0)
        let day = BandDayMapper.day(RingDay(date: "2026-10-04"), records: [], sleep: [nap], date: now, calendar: utc)
        XCTAssertTrue(day.sleep.isEmpty)
        XCTAssertEqual(day.naps, [RingNap(start: nap.start, end: nap.end)])
    }

    func testApplyingTheSameRecordsTwiceChangesNothing() {
        let records = morning + lateNight
        let keys = BandDayMapper.apply(records: records, sleep: night, to: store, calendar: utc)
        XCTAssertEqual(keys, ["2026-10-03", "2026-10-04"])
        var first = store.day("2026-10-04")
        BandDayMapper.apply(records: records, sleep: night, to: store, calendar: utc)
        var second = store.day("2026-10-04")
        first.syncedAt = nil
        second.syncedAt = nil
        XCTAssertEqual(first, second)
        XCTAssertEqual(second.activity?.steps, 420)
        XCTAssertEqual(second.sleep.count, 2)
    }

    func testRunningTotalsOnlyMoveTheDayForward() {
        let day = BandDayMapper.day(RingDay(date: "2026-10-04"), records: morning, sleep: [], date: now, calendar: utc)
        // SDK type 9 {step 1234, calorie 300, distance 1000} read later in the morning.
        let ahead = BandDayMapper.steps(BandSteps(daysAgo: 0, steps: 1234, distanceMeters: 1000, calories: 300), into: day)
        XCTAssertEqual(ahead.activity?.steps, 1234)
        XCTAssertEqual(ahead.activity?.distanceMeters, 1000)
        let behind = BandDayMapper.steps(BandSteps(daysAgo: 0, steps: 100), into: ahead)
        XCTAssertEqual(behind.activity?.steps, 1234)
        // A later record sync keeps the larger running total.
        let resynced = BandDayMapper.day(ahead, records: morning, sleep: [], date: now, calendar: utc)
        XCTAssertEqual(resynced.activity?.steps, 1234)
    }

    /// The band's history carries its automatic blood pressure, glucose and blood fats: each
    /// becomes the day's reading (for Jarvis Health), once however many syncs bring it.
    func testTheHistorysReadingsBecomeTheDaysReadingsOnce() {
        let today = RingDay(date: "2026-10-04"), yesterday = RingDay(date: "2026-10-03")
        var morningDay = BandDayMapper.day(today, records: morning, sleep: [], date: date(2026, 10, 4, 8, 30), calendar: utc)
        morningDay = BandDayMapper.day(morningDay, records: morning, sleep: [], date: date(2026, 10, 4, 8, 30), calendar: utc)
        let pressures = morningDay.measurements.filter { $0.type == "blood_pressure" }
        XCTAssertEqual(pressures.count, 1, "a second sync replaces it")
        XCTAssertEqual(pressures.first?.systolic, 118)
        XCTAssertEqual(pressures.first?.diastolic, 76)

        let night = BandDayMapper.day(yesterday, records: lateNight, sleep: [], date: date(2026, 10, 3, 23, 55), calendar: utc)
        let glucose = night.measurements.first { $0.type == "blood_glucose" }
        XCTAssertEqual(glucose?.extra?["blood_glucose_mmol_l"] ?? 0, 5.42, accuracy: 0.01)
        XCTAssertNotNil(night.measurements.first { $0.type == "blood_component" }?.extra?["cholesterol_mmol_l"])
    }
}
