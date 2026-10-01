import XCTest
@testable import JarvisCopilot

/// X5 history records folded into the shared day model, so the R12's charts, Health tab and
/// server payload read the X5 without knowing it is a different ring.
@MainActor
final class X5DayMapperTests: XCTestCase {

    private var directory: URL!
    private var store: RingHistoryStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("X5DayMapperTests-\(UUID().uuidString)")
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

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private func apply(_ batch: X5Batch) -> Set<String> {
        X5DayMapper.apply(batch, to: store, calendar: utc)
    }

    func testDayTotalsBecomeTheDaysActivity() {
        let total = X5DayTotal(daysAgo: 0, day: DateComponents(year: 2024, month: 8, day: 27), steps: 46,
                               exerciseSeconds: 17, distanceMeters: 30, calories100: 147)
        XCTAssertEqual(apply(X5Batch(totals: [total])), ["2024-08-27"])
        let activity = store.day("2024-08-27").activity
        XCTAssertEqual(activity?.steps, 46)
        // Small calories, like the R12: 1.47 kcal.
        XCTAssertEqual(activity?.calories, 1470)
        XCTAssertEqual(activity?.distanceMeters, 30)
        XCTAssertEqual(activity?.sportMinutes, 0)
    }

    func testStepBlocksFillFifteenMinuteSlotsMinuteByMinute() {
        let early = X5StepBlock(id: 2, start: date(2024, 8, 8, 23, 43, 19), steps: 13, calories100: 25,
                                distanceMeters: 10, perMinute: [13, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let late = X5StepBlock(id: 0, start: date(2024, 8, 8, 23, 58, 19), steps: 29, calories100: 37,
                               distanceMeters: 0, perMinute: [10, 19, 0, 0, 0, 0, 0, 0, 0, 0])
        _ = apply(X5Batch(blocks: [early, late]))
        let slots = store.day("2024-08-08").stepSlots
        XCTAssertEqual(slots.first { $0.slot == 94 }?.steps, 13)
        XCTAssertEqual(slots.first { $0.slot == 95 }?.steps, 29)
        XCTAssertEqual(slots.first { $0.slot == 95 }?.calories, 370)
    }

    func testABlockCrossingASlotBoundarySplitsBySteps() {
        // 10:10 … 10:19: minutes 0–4 are in slot 40 (10:00–10:14), 5–9 in slot 41.
        let block = X5StepBlock(id: 1, start: date(2024, 8, 9, 10, 10, 0), steps: 100, calories100: 100,
                                distanceMeters: 80, perMinute: [10, 10, 10, 10, 10, 10, 10, 10, 10, 10])
        _ = apply(X5Batch(blocks: [block]))
        let slots = store.day("2024-08-09").stepSlots
        XCTAssertEqual(slots.first { $0.slot == 40 }?.steps, 50)
        XCTAssertEqual(slots.first { $0.slot == 41 }?.steps, 50)
        XCTAssertEqual((slots.first { $0.slot == 40 }?.distanceMeters ?? 0) + (slots.first { $0.slot == 41 }?.distanceMeters ?? 0), 80)
    }

    func testFiveSecondHeartRateAveragesIntoMinutes() {
        let block = X5HRBlock(id: 1, start: date(2024, 8, 8, 22, 58, 12),
                              bpm: [76, 73, 74, 77, 80, 81, 80, 79, 78, 79, 76, 75, 75, 76, 76])
        _ = apply(X5Batch(hr: [block]))
        let series = store.day("2024-08-08").heartRate
        XCTAssertEqual(series?.intervalMinutes, 1)
        XCTAssertEqual(series?.values[1378] ?? 0, 77.7, accuracy: 0.01)
        XCTAssertEqual(series?.values[1379] ?? 0, 75.6, accuracy: 0.01)
    }

    func testSleepChunksStitchIntoOneNightKeyedToTheDayItEnds() {
        let first = X5SleepChunk(id: 0, start: date(2024, 8, 23, 23, 0),
                                 codes: [Int](repeating: 2, count: 60) + [Int](repeating: 1, count: 60))
        let second = X5SleepChunk(id: 1, start: date(2024, 8, 24, 1, 0),
                                  codes: [Int](repeating: 3, count: 30) + [Int](repeating: 5, count: 30))
        _ = apply(X5Batch(sleep: [second, first]))
        let nights = store.day("2024-08-24").sleep
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights.first?.start, date(2024, 8, 23, 23, 0))
        XCTAssertEqual(nights.first?.end, date(2024, 8, 24, 2, 0))
        XCTAssertEqual(nights.first?.minutes(of: RingSleepStage.light), 60)
        XCTAssertEqual(nights.first?.minutes(of: RingSleepStage.deep), 60)
        XCTAssertEqual(nights.first?.minutes(of: RingSleepStage.rem), 30)
        XCTAssertEqual(nights.first?.minutes(of: RingSleepStage.awake), 30)
        XCTAssertTrue(store.day("2024-08-23").sleep.isEmpty)
    }

    /// Review finding #1: the cursor re-reads the newest chunk, which grew since; the stored night
    /// must be extended, not replaced by the chunk alone (or doubled).
    func testARereadChunkExtendsTheStoredNight() {
        let first = [X5SleepChunk(id: 0, start: date(2024, 8, 23, 23, 0), codes: [Int](repeating: 2, count: 120)),
                     X5SleepChunk(id: 1, start: date(2024, 8, 24, 1, 0), codes: [Int](repeating: 1, count: 120)),
                     X5SleepChunk(id: 2, start: date(2024, 8, 24, 3, 0), codes: [Int](repeating: 2, count: 120)),
                     X5SleepChunk(id: 3, start: date(2024, 8, 24, 5, 0), codes: [Int](repeating: 3, count: 90))]
        _ = apply(X5Batch(sleep: first))
        XCTAssertEqual(store.day("2024-08-24").sleep.first?.end, date(2024, 8, 24, 6, 30))
        // The same last chunk again, grown by half an hour.
        _ = apply(X5Batch(sleep: [X5SleepChunk(id: 3, start: date(2024, 8, 24, 5, 0), codes: [Int](repeating: 3, count: 120))]))
        let nights = store.day("2024-08-24").sleep
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights.first?.start, date(2024, 8, 23, 23, 0))
        XCTAssertEqual(nights.first?.end, date(2024, 8, 24, 7, 0))
        XCTAssertEqual(nights.first.map { $0.stages.reduce(0) { $0 + $1.minutes } }, 480)
        // And the same chunk once more, unchanged: still one night of the same length.
        _ = apply(X5Batch(sleep: [X5SleepChunk(id: 3, start: date(2024, 8, 24, 5, 0), codes: [Int](repeating: 3, count: 120))]))
        XCTAssertEqual(store.day("2024-08-24").sleep.count, 1)
        XCTAssertEqual(store.day("2024-08-24").sleep.first.map { $0.stages.reduce(0) { $0 + $1.minutes } }, 480)
    }

    func testAnAfternoonSleepIsANap() {
        let nap = X5SleepChunk(id: 4, start: date(2024, 8, 24, 14, 0), codes: [Int](repeating: 2, count: 40))
        _ = apply(X5Batch(sleep: [nap]))
        let day = store.day("2024-08-24")
        XCTAssertTrue(day.sleep.isEmpty)
        XCTAssertEqual(day.naps.first?.start, date(2024, 8, 24, 14, 0))
        XCTAssertEqual(day.naps.first?.end, date(2024, 8, 24, 14, 40))
    }

    func testHRVStressAndBloodPressure() {
        let reading = X5HRV(id: 0, date: date(2024, 8, 9, 0, 59, 30), hrv: 64, heartRate: 77, stress: 30,
                            systolic: 117, diastolic: 62, vascularAging: 0)
        _ = apply(X5Batch(hrv: [reading]))
        let day = store.day("2024-08-09")
        XCTAssertEqual(day.hrv?.intervalMinutes, 5)
        XCTAssertEqual(day.hrv?.values[11], 64)
        XCTAssertEqual(day.stress?.values[11], 30)
        XCTAssertEqual(day.bloodPressure.map { [$0.systolic, $0.diastolic] }, [[117, 62]])
    }

    func testSpotReadingsTemperatureAndOxygen() {
        _ = apply(X5Batch(singleHR: [X5Reading(id: 0, date: date(2024, 8, 27, 9, 1, 30), value: 70),
                                     X5Reading(id: 1, date: date(2024, 8, 27, 9, 30), value: 25)],
                          temperature: [X5Reading(id: 0, date: date(2024, 8, 27, 8, 56, 59), value: 34.6)],
                          spo2: [X5Reading(id: 0, date: date(2024, 8, 27, 9, 0, 19), value: 98),
                                 X5Reading(id: 1, date: date(2024, 8, 27, 9, 40), value: 93),
                                 X5Reading(id: 2, date: date(2024, 8, 27, 9, 50), value: 40)],
                          manualSpO2: [X5Reading(id: 0, date: date(2024, 8, 27, 10, 0), value: 97)]))
        let day = store.day("2024-08-27")
        // An impossible 25 bpm is dropped.
        XCTAssertEqual(day.manualHeartRate.map(\.value), [70])
        XCTAssertEqual(day.manualHeartRate.first?.minute, 541)
        XCTAssertEqual(day.temperature?.values[107] ?? 0, 34.6, accuracy: 0.001)
        XCTAssertEqual(day.spo2?.min[9], 93)
        XCTAssertEqual(day.spo2?.max[9], 98)
        XCTAssertEqual(day.manualSpO2.map(\.value), [97])
    }

    func testApplyingTheSameBatchTwiceChangesNothing() {
        let batch = X5Batch(blocks: [X5StepBlock(id: 1, start: date(2024, 8, 9, 10, 10, 0), steps: 20, calories100: 10,
                                                 distanceMeters: 10, perMinute: [10, 10, 0, 0, 0, 0, 0, 0, 0, 0])],
                            hr: [X5HRBlock(id: 1, start: date(2024, 8, 9, 10, 0, 0), bpm: [70, 71, 72, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])],
                            singleHR: [X5Reading(id: 0, date: date(2024, 8, 9, 11, 0), value: 66)])
        _ = apply(batch)
        let once = store.day("2024-08-09")
        _ = apply(batch)
        var twice = store.day("2024-08-09")
        twice.syncedAt = once.syncedAt
        XCTAssertEqual(once, twice)
    }
}
