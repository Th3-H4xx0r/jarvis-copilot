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
        try RenderHarness.write(view.environment(AppRouter()), size: CGSize(width: 402, height: 874), name: name, settle: 3)
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

    func testAnEmptyRangeSaysSo() throws {
        let h = history(.hrv, range: .year, kind: "ms") { _ in nil }
        try render(.hrv, .year, h, name: "history-empty-year")
    }
}
