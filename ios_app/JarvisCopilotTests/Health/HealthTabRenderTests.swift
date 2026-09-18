import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The Health tab, drawn before it is installed: the battery card, the data
/// sources, and the whole tab on a realistic waking day.
@MainActor
final class HealthTabRenderTests: XCTestCase {
    private let wake = Date(timeIntervalSince1970: 1_789_993_020)   // a 07:37 wake

    private func battery(window: Bool) -> HealthBattery {
        let curve = (0..<18).map { i -> HealthCurvePoint in
            let drop = Double(i) * 1.6 + (i > 9 ? Double(i - 9) * 1.4 : 0)
            return HealthCurvePoint(at: wake.addingTimeInterval(Double(i) * 1800), level: 92 - drop)
        }
        return HealthBattery(level: curve.last?.level, band: "Medium", wakeLevel: 92,
                             charged: window ? nil : 52, drained: window ? 40 : 38,
                             drains: window ? nil : ["stress": 11, "activity": 14],
                             biggestDrain: HealthDrain(start: wake.addingTimeInterval(14 * 1800),
                                                       end: wake.addingTimeInterval(15 * 1800), points: 3.1),
                             curve: curve, calibrating: nil, partial: false, noSleep: false,
                             recoveryFactor: window ? nil : 0.94)
    }

    func testTheBatteryCardRendersACurve() throws {
        try RenderHarness.write(BatteryCard(battery: battery(window: false),
                                            analysis: "A full night charged you to 92. Stress through the afternoon took 11.",
                                            lastRefreshed: Date(), isRefreshing: false, onRefresh: {}),
                                size: CGSize(width: 402, height: 470), name: "health-battery")
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

    func testTheHealthTabSinceWake() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = HealthTabModel(directory: directory)
        var day = RingDay(date: "2026-09-17")
        day.heartRate = RingSeries(intervalMinutes: 30, values: Array(repeating: 0, count: 15)
                                   + (0..<18).map { 72 + Double($0 % 5) * 4 })
        day.stress = RingSeries(intervalMinutes: 30, values: Array(repeating: 0, count: 15)
                                + (0..<18).map { 30 + Double($0 % 6) * 6 })
        day.stepSlots = (31..<66).map { RingStepSlot(slot: $0, steps: 180 + ($0 % 7) * 60, calories: 0, distanceMeters: 0) }
        day.activity = RingActivity(steps: 9120, runningSteps: 0, calories: 310_000, distanceMeters: 6400, sportMinutes: 48)
        day.syncedAt = Date()
        model.seed(now: HealthNow(start: wake, end: wake.addingTimeInterval(9 * 3600), minutes: 540,
                                  noWake: false, day: nil, battery: battery(window: true)),
                   day: day)
        try RenderHarness.write(HealthTab(model: model).environment(AppRouter()),
                                size: CGSize(width: 402, height: 874), name: "health-tab", settle: 3)
    }
}
