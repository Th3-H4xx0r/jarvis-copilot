import SwiftUI
import XCTest
@testable import JarvisCopilot

/// A metric's history: what the server sends, how the numbers read, and how
/// the screen looks for each kind of chart.
@MainActor
final class HealthHistoryTests: XCTestCase {

    func testTheServersHistoryDecodes() throws {
        let json = """
        {"metric":"heart_rate","range":"W","title":"Heart rate","kind":"bpm","start":"2026-09-12","end":"2026-09-18",
         "buckets":[{"start":"2026-09-17","end":"2026-09-17","value":80.7,"low":51.0,"high":128.0,"days":1},
                    {"start":"2026-09-18","end":"2026-09-18","value":null,"low":null,"high":null,"days":0}],
         "headline":{"label":"Range","value":77.0,"low":51.0,"high":128.0,"kind":"bpm"},
         "stats":[{"label":"Average","value":77.0,"kind":"bpm"},{"label":"Days measured","value":1,"kind":"count"}],
         "previous":{"average":null,"days":0},"highlight":"Jarvis Health has 2 days of history so far.",
         "days_so_far":2}
        """
        let history = try HealthClient.decodeForTests(HealthHistory.self, json: json)
        XCTAssertEqual(history.buckets.first?.high, 128)
        XCTAssertNil(history.buckets.last?.value, "an unmeasured day is a gap")
        XCTAssertEqual(history.daysSoFar, 2)
        XCTAssertFalse(history.isEmpty)
    }

    func testNumbersReadTheWayTheCardsWriteThem() {
        XCTAssertEqual(HealthFormat.string(7520, kind: "steps"), 7520.formatted())
        XCTAssertEqual(HealthFormat.string(72.4, kind: "bpm"), "72 bpm")
        XCTAssertEqual(HealthFormat.string(452, kind: "minutes"), "7h 32m")
        XCTAssertEqual(HealthFormat.string(480, kind: "minutes"), "8h")
        XCTAssertEqual(HealthFormat.string(5100, kind: "meters"), "5.10 km")
        XCTAssertEqual(HealthFormat.string(nil, kind: "bpm"), "—")
        XCTAssertEqual(HealthFormat.range(52, 141, kind: "bpm"), "52–141 bpm")
    }

    // MARK: Renders

    private let end = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21

    private func history(_ metric: HealthMetric, range: HealthRange, kind: String,
                         bucket: (Int) -> HealthHistory.Bucket?) -> HealthHistory {
        let count = ["W": 7, "M": 30, "6M": 26, "Y": 12][range.rawValue]!
        let buckets = (0..<count).map { index -> HealthHistory.Bucket in
            let offset = count - 1 - index
            let start: Date
            switch range {
            case .halfYear: start = Calendar.current.date(byAdding: .weekOfYear, value: -offset, to: end)!
            case .year: start = Calendar.current.date(byAdding: .month, value: -offset, to: end)!
            default: start = Calendar.current.date(byAdding: .day, value: -offset, to: end)!
            }
            let key = RingDates.dayKey(start)
            let endKey: String
            switch range {
            case .halfYear: endKey = RingDates.dayKey(Calendar.current.date(byAdding: .day, value: 6, to: start)!)
            case .year: endKey = RingDates.dayKey(Calendar.current.date(byAdding: .day, value: 27, to: start)!)
            default: endKey = key
            }
            var b = bucket(index) ?? HealthHistory.Bucket(start: key, end: endKey, value: nil, low: nil, high: nil,
                                                           days: 0, stages: nil)
            b.start = key
            b.end = endKey
            return b
        }
        let values = buckets.compactMap(\.value)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return HealthHistory(
            metric: metric.rawValue, range: range.rawValue, title: metric.title, kind: kind,
            start: buckets.first!.start, end: buckets.last!.end, buckets: buckets,
            headline: .init(label: metric.style == .range ? "Range" : "Average", value: average,
                            low: buckets.compactMap(\.low).min(), high: buckets.compactMap(\.high).max(), kind: kind),
            stats: [.init(label: "Average", value: average, kind: kind), .init(label: "Lowest", value: values.min(), kind: kind),
                    .init(label: "Highest", value: values.max(), kind: kind),
                    .init(label: "Days measured", value: Double(values.count), kind: "count")],
            previous: .init(average: average.map { $0 - 3 }, days: 5),
            highlight: "Your \(metric.title.lowercased()) over the last 7 days was a little higher than the 7 days before.",
            daysSoFar: 40)
    }

    private func render(_ metric: HealthMetric, _ range: HealthRange, _ history: HealthHistory, name: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = HealthHistoryModel(metric: metric, directory: directory)
        model.seed(history, for: range)
        let tab = HealthTabModel(directory: directory)
        let view = NavigationStack {
            HealthHistoryView(metric: metric, tab: tab, selection: .today, model: model, initialRange: range)
        }
        try RenderHarness.write(view.environment(AppRouter()), size: CGSize(width: 402, height: 1300), name: name, settle: 3)
    }

    // MARK: The band's readings

    private static let uricBar = HealthReferenceBar(label: "Uric acid", kind: "uric_acid", field: "value", segments: [
        .init(status: "low", from: 0, to: 200), .init(status: "normal", from: 200, to: 420),
        .init(status: "high", from: 420, to: 1000)])

    func testAReadingsHistoryDecodesItsReferenceAndReadings() throws {
        let json = """
        {"metric":"uric_acid","range":"W","title":"Uric acid","kind":"uric_acid","start":"2026-09-29","end":"2026-10-05",
         "buckets":[{"start":"2026-10-05","end":"2026-10-05","value":301.2,"low":null,"high":null,"days":1}],
         "headline":{"label":"Average","value":301.2,"low":null,"high":null,"kind":"uric_acid"},
         "stats":[],"previous":{"average":null,"days":0},"highlight":"","days_so_far":3,
         "readings":[{"metric":"uric_acid","at":"2026-10-05T02:14:47Z","value":339.4}],
         "reference":[{"label":"Uric acid","kind":"uric_acid","field":"value",
                       "segments":[{"status":"low","from":0,"to":200},{"status":"normal","from":200,"to":420},
                                   {"status":"high","from":420,"to":1000}]}]}
        """
        let history = try HealthClient.decodeForTests(HealthHistory.self, json: json)
        XCTAssertEqual(history.readings?.first?.value, 339.4)
        XCTAssertEqual(history.reference?.first?.segments.count, 3)
        XCTAssertNotEqual(history.readings?.first?.date, .distantPast)
    }

    func testARangeBarPlacesAndJudgesAValue() {
        let bar = Self.uricBar
        XCTAssertEqual(bar.status(of: 150), "low")
        XCTAssertEqual(bar.status(of: 301), "normal")
        XCTAssertEqual(bar.status(of: 420), "high", "a threshold belongs to the segment it starts")
        XCTAssertEqual(bar.status(of: 1500), "high", "past the end is still the last segment")
        XCTAssertEqual(bar.position(of: 500), 0.5, accuracy: 0.001)
        XCTAssertEqual(bar.position(of: -10), 0)
        XCTAssertEqual(bar.position(of: 2000), 1)
    }

    func testUricAcidWeekShowsItsRangeBarAndReadings() throws {
        var h = history(.uricAcid, range: .week, kind: "uric_acid") { i in
            i < 3 ? nil : .init(start: "", end: "", value: 160 + Double(i) * 30, low: nil, high: nil, days: 1, stages: nil)
        }
        h.reference = [Self.uricBar]
        h.readings = [.init(metric: "uric_acid", at: "2026-10-05T02:14:47Z", value: 339.4),
                      .init(metric: "uric_acid", at: "2026-10-04T18:02:11Z", value: 160.5)]
        try render(.uricAcid, .week, h, name: "history-uric-acid")
    }

    // MARK: A reading's day

    private static func glucoseBars() -> [HealthReferenceBar] {
        [HealthReferenceBar(label: "Fasting / before a meal", kind: "glucose", field: "value", segments: [
            .init(status: "low", from: 2, to: 3.9), .init(status: "normal", from: 3.9, to: 5.6),
            .init(status: "elevated", from: 5.6, to: 7), .init(status: "high", from: 7, to: 15)]),
         HealthReferenceBar(label: "1 h after a meal", kind: "glucose", field: "value", segments: [
            .init(status: "low", from: 2, to: 3.9), .init(status: "normal", from: 3.9, to: 9.4),
            .init(status: "high", from: 9.4, to: 15)]),
         HealthReferenceBar(label: "2 h after a meal", kind: "glucose", field: "value", segments: [
            .init(status: "low", from: 2, to: 3.9), .init(status: "normal", from: 3.9, to: 7.8),
            .init(status: "elevated", from: 7.8, to: 11.1), .init(status: "high", from: 11.1, to: 15)])]
    }

    /// The band's glucose every half hour, as its daily record keeps it: a night run, a gap, a day.
    private static func glucoseDay(_ day: Date) -> HealthHistory {
        let format = ISO8601DateFormatter()
        let minutes = Array(stride(from: 30, through: 210, by: 30)) + Array(stride(from: 300, through: 990, by: 30))
        let readings = minutes.reversed().map { m -> HealthVitalReading in
            let wave = m < 450 ? 4.2 + 0.1 * sin(Double(m) / 40) : 6.2 + 1.2 * sin(Double(m - 450) / 90)
            return HealthVitalReading(metric: "blood_glucose", at: format.string(from: day.addingTimeInterval(Double(m) * 60)),
                                      value: (wave * 100).rounded() / 100)
        }
        let values = readings.map(\.value)
        let key = RingDates.dayKey(day)
        return HealthHistory(
            metric: "blood_glucose", range: "D", title: "Blood glucose", kind: "glucose", start: key, end: key,
            buckets: [.init(start: key, end: key, value: values.reduce(0, +) / Double(values.count), low: nil, high: nil,
                            days: 1, stages: nil)],
            headline: .init(label: "Average", value: values.reduce(0, +) / Double(values.count), low: nil, high: nil,
                            kind: "glucose"),
            stats: [], previous: .init(average: nil, days: 0),
            highlight: "Your average blood glucose over the day was 5.6 mmol/L. A wrist-band estimate, not a diagnosis.",
            daysSoFar: 4, readings: readings, reference: glucoseBars())
    }

    func testAOneReadingAxisHasRoomAroundIt() throws {
        let one = try XCTUnwrap(HealthChartScale.padded([102.6]))
        XCTAssertLessThan(one.lowerBound, 95)
        XCTAssertGreaterThan(one.upperBound, 110)
        let spread = try XCTUnwrap(HealthChartScale.padded([72, 136]))
        XCTAssertLessThan(spread.lowerBound, 72)
        XCTAssertGreaterThan(spread.upperBound, 136)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(HealthChartScale.padded([0.2])).lowerBound, 0)
        XCTAssertNil(HealthChartScale.padded([]))
    }

    func testVitalsOfferADay() {
        XCTAssertTrue(HealthMetric.bloodGlucose.ranges.contains(.day))
        XCTAssertTrue(HealthMetric.bloodPressure.ranges.contains(.day))
    }

    func testGlucoseDayDrawsTheReadingsOnTheClock() throws {
        UserDefaults.standard.setValue(GlucoseUnit.mgdL.rawValue, forKey: GlucoseUnit.key)
        defer { UserDefaults.standard.removeObject(forKey: GlucoseUnit.key) }
        let day = Calendar.current.startOfDay(for: Date())
        let model = HealthVitalDayModel(metric: .bloodGlucose, day: day)
        model.seed(Self.glucoseDay(day))
        let view = NavigationStack { ScrollView { HealthVitalDayView(metric: .bloodGlucose, day: day, model: model) } }
        try RenderHarness.write(view.environment(AppRouter()), size: CGSize(width: 402, height: 1900),
                                name: "history-glucose-day", settle: 2)
    }

    func testGlucoseWeekShowsItsHeadlineAndThreeScales() throws {
        UserDefaults.standard.setValue(GlucoseUnit.mgdL.rawValue, forKey: GlucoseUnit.key)
        defer { UserDefaults.standard.removeObject(forKey: GlucoseUnit.key) }
        var h = history(.bloodGlucose, range: .week, kind: "glucose") { i in
            i < 6 ? nil : .init(start: "", end: "", value: 5.7, low: nil, high: nil, days: 1, stages: nil)
        }
        h.reference = Self.glucoseBars()
        h.readings = Self.glucoseDay(Calendar.current.startOfDay(for: Date())).readings
        try render(.bloodGlucose, .week, h, name: "history-glucose-week")
    }

    func testBloodPressureWeekBarsBothHalves() throws {
        var h = history(.bloodPressure, range: .week, kind: "mmhg") { i in
            .init(start: "", end: "", value: 118 + Double(i % 3) * 6, low: 76 + Double(i % 2) * 5, high: nil, days: 1, stages: nil)
        }
        h.reference = [
            HealthReferenceBar(label: "Systolic", kind: "mmhg", field: "value", segments: [
                .init(status: "low", from: 70, to: 90), .init(status: "normal", from: 90, to: 120),
                .init(status: "elevated", from: 120, to: 130), .init(status: "high", from: 130, to: 200)]),
            HealthReferenceBar(label: "Diastolic", kind: "mmhg", field: "low", segments: [
                .init(status: "low", from: 40, to: 60), .init(status: "normal", from: 60, to: 80),
                .init(status: "high", from: 80, to: 120)])]
        h.readings = [.init(metric: "blood_pressure", at: "2026-10-05T02:15:29Z", value: 124, diastolic: 81)]
        try render(.bloodPressure, .week, h, name: "history-blood-pressure")
    }

    func testHeartRateWeekDrawsRanges() throws {
        let h = history(.heartRate, range: .week, kind: "bpm") { i in
            i == 2 ? nil : .init(start: "", end: "", value: 68 + Double(i % 3) * 5, low: 50 + Double(i % 2) * 4,
                                 high: 118 + Double(i % 4) * 9, days: 1, stages: nil)
        }
        try render(.heartRate, .week, h, name: "history-heart-week")
    }

    func testSleepWeekStacksStages() throws {
        let h = history(.sleep, range: .week, kind: "minutes") { i in
            let asleep = 380 + Double(i % 4) * 30
            return .init(start: "", end: "", value: asleep, low: nil, high: nil, days: 1,
                         stages: .init(deep: asleep * 0.18, light: asleep * 0.58, rem: asleep * 0.24, awake: 14))
        }
        try render(.sleep, .week, h, name: "history-sleep-week")
    }

    func testStepsMonthBars() throws {
        let h = history(.steps, range: .month, kind: "steps") { i in
            i % 9 == 4 ? nil : .init(start: "", end: "", value: 4000 + Double((i * 1370) % 7000), low: nil, high: nil,
                                     days: 1, stages: nil)
        }
        try render(.steps, .month, h, name: "history-steps-month")
    }

    func testBatterySixMonthsRanges() throws {
        let h = history(.battery, range: .halfYear, kind: "level") { i in
            i < 20 ? nil : .init(start: "", end: "", value: 55 + Double(i % 3) * 6, low: 18 + Double(i % 4) * 5,
                                 high: 78 + Double(i % 5) * 4, days: 6, stages: nil)
        }
        try render(.battery, .halfYear, h, name: "history-battery-6m")
    }

    func testSleepDebtWeekShowsTheNightsGoalRings() throws {
        let asleep: [Double?] = [462, 395, nil, 350, 505, 330, 490]
        var h = history(.sleepDebt, range: .week, kind: "minutes") { i in
            asleep[i].map { .init(start: "", end: "", value: Double(i * 55), low: nil, high: nil, days: 1, stages: nil,
                                  goalProgress: $0 / 480) }
        }
        h.goal = .init(value: 480, kind: "minutes", met: 2, measured: 6)
        try render(.sleepDebt, .week, h, name: "history-sleepdebt-goals")
    }

    func testStepsMonthShowsACalendarOfGoalRings() throws {
        var h = history(.steps, range: .month, kind: "steps") { i in
            i % 9 == 4 ? nil : {
                let steps = 4000 + Double((i * 1370) % 7500)
                return .init(start: "", end: "", value: steps, low: nil, high: nil, days: 1, stages: nil,
                             goalProgress: steps / 10_000)
            }()
        }
        h.goal = .init(value: 10_000, kind: "steps", met: 6, measured: 27)
        try render(.steps, .month, h, name: "history-steps-goals")
    }

    private func workout(_ sport: Int, _ name: String, daysAgo: Int, minutes: Int, hr: Int, kcal: Double) -> RingWorkout {
        let start = end.addingTimeInterval(Double(-daysAgo * 86_400) - 3600 * 5)
        return RingWorkout(sport: sport, sportName: name, start: start, end: start.addingTimeInterval(Double(minutes * 60)),
                           activeSeconds: minutes * 60, steps: minutes * 140, distanceMeters: Double(minutes * 160),
                           distanceSource: "gps", kilocalories: kcal, heartRateAverage: hr, heartRateMax: hr + 25,
                           heartRates: [], zoneSeconds: [0, 300, 900, 300, 0])
    }

    func testExerciseWeekChartsMinutesAndListsTheWorkouts() throws {
        let minutes: [Double?] = [30, 0, 45, 0, 62, 25, 40]
        var h = history(.exercise, range: .week, kind: "minutes") { i in
            minutes[i].map { .init(start: "", end: "", value: $0, low: nil, high: nil, days: 1, stages: nil) }
        }
        h.workouts = [workout(7, "Run", daysAgo: 0, minutes: 40, hr: 148, kcal: 380),
                      workout(88, "Strength", daysAgo: 1, minutes: 25, hr: 118, kcal: 160),
                      workout(9, "Cycle", daysAgo: 2, minutes: 62, hr: 132, kcal: 520)]
        try render(.exercise, .week, h, name: "history-exercise")
    }

    func testTheWorkoutsCardInvitesAStartWhenEmpty() throws {
        try RenderHarness.write(HealthWorkoutsCard(workouts: [], onStart: {}, showAll: {}).padding(.horizontal, 16),
                                size: CGSize(width: 402, height: 220), name: "workouts-empty")
    }

    func testAnEmptyRangeSaysSo() throws {
        let h = history(.hrv, range: .year, kind: "ms") { _ in nil }
        try render(.hrv, .year, h, name: "history-empty-year")
    }
}
