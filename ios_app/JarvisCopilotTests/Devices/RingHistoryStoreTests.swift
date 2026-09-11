import XCTest
@testable import JarvisCopilot

@MainActor
final class RingHistoryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RingHistoryStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testUpdatesPersistAcrossStoreInstances() {
        let store = RingHistoryStore(directory: directory)
        store.update("2026-09-11") { day in
            day.activity = RingActivity(steps: 4200, runningSteps: 300, calories: 150_000, distanceMeters: 3100, sportMinutes: 25)
            day.mergeStepSlots([RingStepSlot(slot: 40, steps: 1200, calories: 250, distanceMeters: 900)])
        }
        XCTAssertEqual(store.revision, 1)

        let reloaded = RingHistoryStore(directory: directory).day("2026-09-11")
        XCTAssertEqual(reloaded.activity?.steps, 4200)
        XCTAssertEqual(reloaded.stepSlots.map(\.slot), [40])
    }

    func testAnUnchangedUpdateDoesNotWrite() {
        let store = RingHistoryStore(directory: directory)
        store.update("2026-09-11") { _ in }
        XCTAssertEqual(store.revision, 0)
    }

    func testMergesReplaceBySlotMinuteAndNight() {
        var day = RingDay(date: "2026-09-11")
        day.mergeStepSlots([RingStepSlot(slot: 1, steps: 10, calories: 0, distanceMeters: 0),
                            RingStepSlot(slot: 2, steps: 20, calories: 0, distanceMeters: 0)])
        day.mergeStepSlots([RingStepSlot(slot: 2, steps: 25, calories: 0, distanceMeters: 0)])
        XCTAssertEqual(day.stepSlots.map(\.steps), [10, 25])

        let merged = RingDay.merged([RingTimedValue(minute: 600, value: 70)],
                                    [RingTimedValue(minute: 600, value: 72), RingTimedValue(minute: 30, value: 65)])
        XCTAssertEqual(merged, [RingTimedValue(minute: 30, value: 65), RingTimedValue(minute: 600, value: 72)])

        let end = Date(timeIntervalSince1970: 1_789_000_000)
        day.mergeSleep(RingSleepSession(start: end.addingTimeInterval(-3600), end: end, reportedStartMinute: 0,
                                        stages: [RingSleepStage(stage: 3, minutes: 60)]))
        day.mergeSleep(RingSleepSession(start: end.addingTimeInterval(-7200), end: end.addingTimeInterval(120),
                                        reportedStartMinute: 0, stages: [RingSleepStage(stage: 2, minutes: 122)]))
        XCTAssertEqual(day.sleep.count, 1)
        XCTAssertEqual(day.sleep.first?.stages.first?.stage, 2)
    }

    func testOlderFilesWithMissingFieldsStillDecode() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"date":"2026-09-10","manualHeartRate":[{"minute":5,"value":61}]}"#.utf8)
            .write(to: directory.appendingPathComponent("2026-09-10.json"))
        let day = RingHistoryStore(directory: directory).day("2026-09-10")
        XCTAssertEqual(day.manualHeartRate.first?.value, 61)
        XCTAssertTrue(day.stepSlots.isEmpty)
        XCTAssertNil(day.heartRate)
    }

    func testSummaryCombinesEverySource() {
        var day = RingDay(date: "2026-09-11")
        day.stepSlots = [RingStepSlot(slot: 1, steps: 100, calories: 2000, distanceMeters: 70),
                         RingStepSlot(slot: 2, steps: 50, calories: 1000, distanceMeters: 35)]
        day.heartRate = RingSeries(intervalMinutes: 5, values: [0, 60, 80])
        day.manualHeartRate = [RingTimedValue(minute: 600, value: 70)]
        day.sleep = [RingSleepSession(start: Date(), end: Date(), reportedStartMinute: 0,
                                      stages: [RingSleepStage(stage: 2, minutes: 200), RingSleepStage(stage: 3, minutes: 90),
                                               RingSleepStage(stage: 5, minutes: 15)])]
        day.spo2 = RingMinMax(min: [95] + [Int](repeating: 0, count: 23), max: [99] + [Int](repeating: 0, count: 23))
        day.temperature = RingSeries(intervalMinutes: 30, values: [36.5, 0, 36.7])

        let s = day.summary
        XCTAssertEqual(s.steps, 150)
        XCTAssertEqual(s.kilocalories, 3)
        XCTAssertEqual(s.heartRateMin, 60)
        XCTAssertEqual(s.heartRateMax, 80)
        XCTAssertEqual(s.heartRateAvg, 70)
        XCTAssertEqual(s.heartRateLatest, 70)
        XCTAssertEqual(s.sleepMinutes, 290)
        XCTAssertEqual(s.deepMinutes, 90)
        XCTAssertEqual(s.awakeMinutes, 15)
        XCTAssertEqual(s.spo2Min, 95)
        XCTAssertEqual(s.spo2Avg, 97)
        XCTAssertEqual(s.temperatureAvg, 36.6)
        XCTAssertEqual(s.temperatureLatest, 36.7)
    }

    func testPruneRemovesDaysPastTheWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let store = RingHistoryStore(directory: directory)
        store.update("2025-01-01") { $0.syncedAt = now }
        store.update("2026-09-10") { $0.syncedAt = now }

        store.prune(keepDays: 365, now: now, calendar: calendar)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(files, ["2026-09-10.json"])
    }
}
