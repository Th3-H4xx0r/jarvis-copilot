import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The Health tab, drawn before it is installed: the battery card, the data
/// sources, and the whole tab on a realistic waking day.
@MainActor
final class HealthTabRenderTests: XCTestCase {
    private let wake = Date(timeIntervalSince1970: 1_789_993_020)   // a 07:37 wake
    private var bedtime: Date { wake.addingTimeInterval(-8 * 3600) }  // 23:37 the night before

    /// A day's battery, or today's: from bedtime, climbing through the night,
    /// then falling through the day.
    private func battery(window: Bool) -> HealthBattery {
        let night = (0..<16).map { i in
            HealthCurvePoint(at: bedtime.addingTimeInterval(Double(i + 1) * 1800), level: 40 + Double(i + 1) * 3.25)
        }
        let day = (1..<18).map { i -> HealthCurvePoint in
            let drop = Double(i) * 1.6 + (i > 9 ? Double(i - 9) * 1.4 : 0)
            return HealthCurvePoint(at: wake.addingTimeInterval(Double(i) * 1800), level: 92 - drop)
        }
        let curve = [HealthCurvePoint(at: bedtime, level: 40)] + night + day
        return HealthBattery(level: curve.last?.level, band: "Medium", wakeLevel: 92,
                             charged: 52, drained: window ? 40 : 38,
                             drains: window ? nil : ["stress": 11, "activity": 14],
                             biggestDrain: HealthDrain(start: wake.addingTimeInterval(14 * 1800),
                                                       end: wake.addingTimeInterval(15 * 1800), points: 3.1),
                             curve: curve, calibrating: nil, partial: false, noSleep: false,
                             recoveryFactor: 0.94, bedLevel: 40, bedAt: bedtime, wakeAt: wake)
    }

    func testTheBatteryCardRendersACurve() throws {
        try RenderHarness.write(BatteryCard(battery: battery(window: true), window: true,
                                            analysis: "A full night charged you to 92. Stress through the afternoon took 11.",
                                            lastRefreshed: Date(), isRefreshing: false, onRefresh: {}),
                                size: CGSize(width: 402, height: 470), name: "health-battery")
    }

    /// Measure from a card: the headline is the ring's live number, Stop in
    /// the corner; the other cards keep their Measure button, dimmed.
    func testACardMeasuringLive() throws {
        let store = RingHistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        store.update("2026-09-17") { day in
            day.heartRate = RingSeries(intervalMinutes: 30, values: (0..<30).map { 60 + Double($0 % 6) * 5 })
            day.spo2 = RingMinMax(min: Array(repeating: 96, count: 14), max: Array(repeating: 98, count: 14))
        }
        let sections = RingStatsSections(store: store, dayKey: "2026-09-17", capabilities: RingCapabilities()) { type in
            switch type {
            case .heartRate: return RingCardMeasure(state: .measuring("74 bpm"), start: {}, stop: {})
            case .spo2: return RingCardMeasure(state: .idle, enabled: false, start: {}, stop: {})
            default: return nil
            }
        }
        try RenderHarness.write(ScrollView { sections.padding(.top, 460) }.scrollDisabled(true),
                                size: CGSize(width: 402, height: 1320), name: "health-measuring")
    }

    /// The live number while measuring: "--", then each value the ring sends
    /// rolls in, then it lands as "Just now". Frames, not a guess.
    func testTheLiveNumberRolls() throws {
        final class Driver: ObservableObject {
            @Published var state: RingCardMeasure.State = .measuring(nil)
        }
        struct Card: View {
            @ObservedObject var driver: Driver
            var body: some View {
                RingMetricCard(title: "Heart rate", headline: RingStat(label: "Latest", value: "68 bpm"),
                               measure: RingCardMeasure(state: driver.state, start: {}, stop: {}),
                               emptyText: "", readout: { (_: Double) in nil }) { _, _ in EmptyView() }
                    .padding(.horizontal, 16)
            }
        }
        let driver = Driver()
        try RenderHarness.filmstrip(Card(driver: driver), size: CGSize(width: 402, height: 200), name: "health-measure-roll",
                                    changes: [{ driver.state = .measuring("72 bpm") },
                                              { driver.state = .measuring("78 bpm") },
                                              { driver.state = .result("78 bpm") }])
    }

    func testTheRingScreensMeasureList() throws {
        let noop = RingCardMeasure(state: .idle, start: {}, stop: {})
        let list = RingMeasureList(items: [
            .init(type: .heartRate, state: .measuring("74 bpm"), last: nil,
                  control: RingCardMeasure(state: .measuring("74 bpm"), start: {}, stop: {})),
            .init(type: .spo2, state: .idle, last: ("97%", Date().addingTimeInterval(-7200)),
                  control: RingCardMeasure(state: .idle, enabled: false, start: {}, stop: {})),
            .init(type: .hrv, state: .result("48 ms"), last: nil, control: noop),
            .init(type: .stress, state: .idle, last: nil, control: noop),
            .init(type: .temperature, state: .failed("Put the ring on first"), last: nil, control: noop),
        ])
        try RenderHarness.write(list.padding(.horizontal, 16), size: CGSize(width: 402, height: 420),
                                name: "ring-measure-list")
    }

    func testTheSettingsListDataSources() throws {
        let devices = [
            HealthRosterDevice(key: "ring-b6ce93c4", kind: "ring", name: "Colmi R12", linked: true,
                               lastSyncedAt: HealthClient.instant.string(from: Date().addingTimeInterval(-240))),
            HealthRosterDevice(key: "watch-0c1d2e3f", kind: "watch", name: "Apple Watch", linked: false,
                               lastSyncedAt: nil),
        ]
        try RenderHarness.write(HealthDataSources(devices: devices, onToggle: { _, _ in }),
                                size: CGSize(width: 402, height: 300), name: "health-sources")
    }

    func testTheHealthTabToday() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = HealthTabModel(directory: directory)
        var day = RingDay(date: "2026-09-17")
        // As the server sends today: anchored at the midnight before bedtime,
        // so the night is hours 23–31 and the waking day runs on past 31.
        day.heartRate = RingSeries(intervalMinutes: 30, values: Array(repeating: 0, count: 47)
                                   + (0..<16).map { 54 + Double($0 % 3) * 2 }
                                   + (0..<18).map { 72 + Double($0 % 5) * 4 })
        day.stress = RingSeries(intervalMinutes: 30, values: Array(repeating: 0, count: 63)
                                + (0..<18).map { 30 + Double($0 % 6) * 6 })
        day.stepSlots = (127..<162).map { RingStepSlot(slot: $0, steps: 180 + ($0 % 7) * 60, calories: 0, distanceMeters: 0) }
        day.sleep = [RingSleepSession(start: bedtime, end: wake, reportedStartMinute: 1417, stages: [
            RingSleepStage(stage: RingSleepStage.light, minutes: 40), RingSleepStage(stage: RingSleepStage.deep, minutes: 70),
            RingSleepStage(stage: RingSleepStage.light, minutes: 110), RingSleepStage(stage: RingSleepStage.rem, minutes: 45),
            RingSleepStage(stage: RingSleepStage.awake, minutes: 8), RingSleepStage(stage: RingSleepStage.light, minutes: 120),
            RingSleepStage(stage: RingSleepStage.rem, minutes: 87),
        ])]
        day.activity = RingActivity(steps: 9120, runningSteps: 0, calories: 310_000, distanceMeters: 6400, sportMinutes: 48)
        day.syncedAt = Date()
        model.seed(now: HealthNow(start: bedtime, end: wake.addingTimeInterval(9 * 3600), minutes: 1020,
                                  noWake: false, day: nil, battery: battery(window: true), wake: wake),
                   day: day)
        try RenderHarness.write(HealthTab(model: model).environment(AppRouter()),
                                size: CGSize(width: 402, height: 874), name: "health-tab", settle: 3)
    }
}
