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
        try RenderHarness.write(BatteryCard(battery: battery(window: true),
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

    private var sleepDebt: HealthSleepDebt {
        let slept: [Int?] = [462, 395, nil, 350, 505, 330, 467]
        var running = 0
        let nights = slept.enumerated().map { index, asleep -> HealthSleepDebt.Night in
            if let asleep { running = max(0, running + 480 - asleep) }
            let date = RingDates.dayKey(wake.addingTimeInterval(Double(index - 6) * 86_400))
            let band = running >= 600 ? "High" : running >= 300 ? "Medium" : running >= 60 ? "Low" : "None"
            return HealthSleepDebt.Night(date: date, asleep: asleep, debt: running, band: band)
        }
        return HealthSleepDebt(goal: 480, debt: running, band: nights.last!.band, nights: nights,
                               average: 418, shortNights: 4, measured: 6)
    }

    func testTheSleepDebtCard() throws {
        try RenderHarness.write(SleepDebtCard(debt: sleepDebt).padding(.horizontal, 16),
                                size: CGSize(width: 402, height: 520), name: "health-sleep-debt")
    }

    /// Scrubbing the battery: the digits roll and the ring sweeps to the level
    /// under the finger, changing colour as it crosses a band.
    func testTheBatteryGaugeSweeps() throws {
        final class Driver: ObservableObject {
            @Published var level = 81.0
            @Published var caption = "High"
            @Published var highlighted = false
        }
        struct Gauge: View {
            @ObservedObject var driver: Driver
            var body: some View {
                BatteryGauge(level: driver.level, band: BatteryCard.band(for: driver.level),
                             caption: driver.caption, highlighted: driver.highlighted)
                    .padding(20)
            }
        }
        let driver = Driver()
        try RenderHarness.filmstrip(Gauge(driver: driver), size: CGSize(width: 320, height: 110), name: "health-battery-sweep",
                                    changes: [{ driver.level = 46; driver.caption = "2:00 AM · Low"; driver.highlighted = true },
                                              { driver.level = 94.5; driver.caption = "9:30 AM · asleep" },
                                              { driver.level = 81; driver.caption = "High"; driver.highlighted = false }])
    }

    /// The measuring metric's symbol beats; the others stay still.
    func testTheSymbolPulsesWhileMeasuring() throws {
        final class Driver: ObservableObject { @Published var pulsing = false }
        struct Symbols: View {
            @ObservedObject var driver: Driver
            var body: some View {
                HStack(spacing: 28) {
                    RingMetricSymbol(name: "heart.fill", tint: RingMeasurementType.heartRate.tint,
                                     pulsing: driver.pulsing, size: 26)
                    RingMetricSymbol(name: "lungs.fill", tint: RingMeasurementType.spo2.tint, size: 26)
                }
                .padding(20)
            }
        }
        let driver = Driver()
        try RenderHarness.filmstrip(Symbols(driver: driver), size: CGSize(width: 160, height: 80), name: "health-symbol-pulse",
                                    changes: [{ driver.pulsing = true }],
                                    times: [0, 0.15, 0.3, 0.45, 0.6, 0.8, 1.0, 1.2])
    }

    /// The step ring fills from empty and the count rolls down to what is
    /// left, the moment the card is seen.
    func testTheStepGoalRingFillsWhenSeen() throws {
        final class Driver: ObservableObject { @Published var revealed = false }
        struct Ring: View {
            @ObservedObject var driver: Driver
            var body: some View {
                HStack(spacing: 24) {
                    RingGoalRing(value: 7_520, goal: 10_000, revealed: driver.revealed)
                    RingGoalRing(value: 12_400, goal: 10_000, revealed: driver.revealed)
                }
                .padding(20)
            }
        }
        let driver = Driver()
        try RenderHarness.filmstrip(Ring(driver: driver), size: CGSize(width: 200, height: 110), name: "health-step-ring",
                                    changes: [{ driver.revealed = true }],
                                    times: [0, 0.15, 0.3, 0.5, 0.75, 1.1, 1.5])
    }

    /// A card seen for the first time: numbers roll up from zero and the
    /// line draws in from the left; the card itself stays still.
    func testACardRollsUpWhenFirstSeen() throws {
        final class Driver: ObservableObject { @Published var shown = false }
        struct Page: View {
            @ObservedObject var driver: Driver
            let store: RingHistoryStore
            var body: some View {
                VStack {
                    if driver.shown {
                        RingStatsSections(store: store, dayKey: "2026-09-17", capabilities: RingCapabilities(),
                                          stepGoal: 10_000)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: 1400, alignment: .top)
                .frame(height: 250, alignment: .top)
                .clipped()
            }
        }
        let store = RingHistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        store.update("2026-09-17") { day in
            day.stepSlots = (28..<80).map { RingStepSlot(slot: $0, steps: 100 + ($0 % 5) * 90, calories: 0, distanceMeters: 0) }
            day.activity = RingActivity(steps: 7520, runningSteps: 0, calories: 280_000, distanceMeters: 5100, sportMinutes: 31)
        }
        let driver = Driver()
        try RenderHarness.filmstrip(Page(driver: driver, store: store), size: CGSize(width: 402, height: 250),
                                    name: "health-card-rollup", changes: [{ driver.shown = true }],
                                    times: [0.05, 0.2, 0.35, 0.55, 0.8, 1.2])
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
                                  noWake: false, day: nil, battery: battery(window: true), wake: wake,
                                  date: RingDates.dayKey(wake), sleepDebt: sleepDebt),
                   day: day)
        try RenderHarness.write(HealthTab(model: model).environment(AppRouter()),
                                size: CGSize(width: 402, height: 874), name: "health-tab", settle: 3)
    }
}
