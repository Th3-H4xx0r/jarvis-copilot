import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The Habits page and a habit's page, drawn before they are installed.
@MainActor
final class HabitRenderTests: XCTestCase {
    /// Wednesday 2026-10-14, mid-afternoon.
    private let now = ISO8601DateFormatter().date(from: "2026-10-14T20:00:00Z")!
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HabitRenderTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func at(_ daysAgo: Double, hour: Double = 0) -> Date { now.addingTimeInterval(-daysAgo * 86_400 + hour * 3600) }

    /// A store holding two habits: one with a target and a daily limit and a
    /// month of scattered relapses (one day over), one quit two days ago.
    private func store() -> HabitStore {
        let store = HabitStore(directory: directory, sync: nil)
        store.sendsAtOnce = false
        let scroll = Habit(id: "scroll", name: "Doomscrolling", startedAt: at(40),
                           goal: HabitGoal(streakDays: 30, limit: HabitLimit(per: .day, count: 1)))
        let vape = Habit(id: "vape", name: "Vaping", startedAt: at(2.4),
                         goal: HabitGoal(streakDays: 7, limit: HabitLimit(per: .month, count: 5)))
        store.save(scroll)
        store.save(vape)
        for (days, hour) in [(35.0, 0.0), (21, -3), (13, 0), (11, -4), (11, -2), (11, -1), (8, 2), (5, -6), (3.2, 0)] {
            store.log(scroll, at: at(days, hour: hour))
        }
        store.log(vape, at: at(1.4))
        return store
    }

    func testTheHabitsPage() throws {
        let page = NavigationStack { HabitsView(store: store(), now: now) }
        try RenderHarness.write(page, size: CGSize(width: 402, height: 640), name: "habits-list")
    }

    func testAHabitsMonth() throws {
        let page = NavigationStack { HabitDetailView(habitID: "scroll", store: store(), now: now) }
        try RenderHarness.write(ScrollView { page.frame(height: 2100) }.scrollDisabled(true),
                                size: CGSize(width: 402, height: 2100), name: "habit-detail-month")
    }

    func testAHabitsWeek() throws {
        let page = NavigationStack { HabitDetailView(habitID: "scroll", store: store(), now: now, initialRange: .week) }
        try RenderHarness.write(ScrollView { page.frame(height: 1500) }.scrollDisabled(true),
                                size: CGSize(width: 402, height: 1500), name: "habit-detail-week")
    }
}
