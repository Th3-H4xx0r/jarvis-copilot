import XCTest
@testable import JarvisCopilot

/// A day's resting heart rate: the night's settled rate, else the day's
/// quietest stretch.
final class RestingHeartRateTests: XCTestCase {
    private let key = "2026-09-17"
    private var midnight: Date { RingDates.date(forKey: key)! }

    private func day(_ values: [Double], interval: Int = 30, sleepMinutes: Int? = nil) -> RingDay {
        var day = RingDay(date: key)
        day.heartRate = RingSeries(intervalMinutes: interval, values: values)
        if let sleepMinutes {
            day.sleep = [RingSleepSession(start: midnight, end: midnight.addingTimeInterval(Double(sleepMinutes) * 60),
                                          reportedStartMinute: 0,
                                          stages: [RingSleepStage(stage: RingSleepStage.light, minutes: sleepMinutes)])]
        }
        return day
    }

    func testTheNightsThreeLowestSettleIt() {
        // Half-hourly: asleep until 07:00 (readings 0–13), awake after.
        var values = [Double](repeating: 0, count: 48)
        values[2] = 54; values[4] = 51; values[6] = 58; values[8] = 49; values[10] = 72
        values[20] = 41   // mid-afternoon dip: awake, so it doesn't count
        let resting = RestingHeartRate.forDay(day(values, sleepMinutes: 420))
        XCTAssertEqual(resting?.bpm, 51, "the mean of 49, 51 and 54")
        XCTAssertEqual(resting?.at, midnight.addingTimeInterval(420 * 60), "filed at the night's end")
    }

    func testWithNoSleepTheQuietestStretchStandsIn() {
        // Every ten minutes: a long quiet spell, and one impossible dip.
        var values = (0..<60).map { 70 + Double($0 % 7) }
        values[20] = 20          // a misread, thrown out
        values[30] = 55
        values[31] = 54
        values[32] = 56
        let resting = RestingHeartRate.forDay(day(values, interval: 10))
        XCTAssertEqual(resting?.bpm, 55)
        XCTAssertNotNil(resting?.at)
    }

    func testTooFewReadingsSayNothing() {
        XCTAssertNil(RestingHeartRate.forDay(day([62, 0, 0])))
        XCTAssertNil(RestingHeartRate.forDay(RingDay(date: key)))
        // A night with barely any readings falls back to the day's own.
        var sparse = day([0, 0, 58, 0, 0, 0, 61, 0, 59, 0, 60, 0, 57, 0, 62, 0], interval: 30, sleepMinutes: 60)
        sparse.sleep[0] = RingSleepSession(start: midnight, end: midnight.addingTimeInterval(3600), reportedStartMinute: 0,
                                           stages: [RingSleepStage(stage: RingSleepStage.light, minutes: 60)])
        XCTAssertEqual(RestingHeartRate.forDay(sparse)?.bpm, 59)
    }

    func testTheHealthExportUsesTheSameNumber() {
        var values = [Double](repeating: 0, count: 48)
        values[2] = 54; values[4] = 51; values[6] = 58; values[8] = 49
        let subject = day(values, sleepMinutes: 420)
        let samples = AppleHealthPlan.samples(.restingHeartRate, day: subject)
        XCTAssertEqual(samples.count, 1)
        if case .quantity(_, _, let value) = samples[0].value {
            XCTAssertEqual(Int(value), RestingHeartRate.forDay(subject)?.bpm)
        } else {
            XCTFail("a quantity")
        }
    }
}
