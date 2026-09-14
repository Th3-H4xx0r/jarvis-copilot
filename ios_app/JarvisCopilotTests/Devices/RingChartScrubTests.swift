import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The ring cards' scrubbing: what the headline shows for a finger at a given time.
@MainActor
final class RingChartScrubTests: XCTestCase {

    // MARK: Lookups

    func testTheNearestReadingWinsWithinTolerance() {
        let readings = [RingTimedValue(minute: 600, value: 60), RingTimedValue(minute: 630, value: 72)]
        XCTAssertEqual(RingChartScrub.nearest(readings, hour: 10.4, toleranceMinutes: 15)?.value, 72) // 10:24 → 10:30
        XCTAssertEqual(RingChartScrub.nearest(readings, hour: 10.1, toleranceMinutes: 15)?.value, 60) // 10:06 → 10:00
    }

    func testAGapShowsNoReadingRatherThanOneFromHoursAway() {
        let readings = [RingTimedValue(minute: 600, value: 60)]
        XCTAssertNil(RingChartScrub.nearest(readings, hour: 14, toleranceMinutes: 15))
        XCTAssertNil(RingChartScrub.nearest([], hour: 10, toleranceMinutes: 15))
    }

    func testStepsReportTheSlotAndTheRunningTotal() {
        let slots = [RingStepSlot(slot: 36, steps: 400, calories: 0, distanceMeters: 0),   // 9:00
                     RingStepSlot(slot: 37, steps: 250, calories: 0, distanceMeters: 0),   // 9:15
                     RingStepSlot(slot: 60, steps: 900, calories: 0, distanceMeters: 0)]   // 15:00
        let at = RingChartScrub.steps(slots, hour: 9.3)   // 9:18
        XCTAssertEqual(at.slot, 37)
        XCTAssertEqual(at.steps, 250)
        XCTAssertEqual(at.soFar, 650)
        let quiet = RingChartScrub.steps(slots, hour: 12)
        XCTAssertEqual(quiet.steps, 0)
        XCTAssertEqual(quiet.soFar, 650)
        XCTAssertEqual(RingChartScrub.steps(slots, hour: 24).slot, 95, "the end of the axis is the last slot")
    }

    func testTheSleepStageUnderTheFingerAndItsBounds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let night = RingSleepSession(start: start, end: start.addingTimeInterval(90 * 60), reportedStartMinute: 0,
                                     stages: [RingSleepStage(stage: RingSleepStage.light, minutes: 30),
                                              RingSleepStage(stage: RingSleepStage.deep, minutes: 60)])
        let deep = RingChartScrub.stage(in: night, at: start.addingTimeInterval(45 * 60))
        XCTAssertEqual(deep?.stage, RingSleepStage.deep)
        XCTAssertEqual(deep?.start, start.addingTimeInterval(30 * 60))
        XCTAssertEqual(deep?.end, start.addingTimeInterval(90 * 60))
        XCTAssertNil(RingChartScrub.stage(in: night, at: start.addingTimeInterval(-60)))
    }

    func testTheHourlyBandSkipsHoursWithoutData() {
        let spo2 = RingMinMax(min: [0, 94, 96], max: [0, 98, 96])
        XCTAssertNil(RingChartScrub.hourRange(spo2, hour: 0.5))
        XCTAssertEqual(RingChartScrub.hourRange(spo2, hour: 1.7)?.low, 94)
        XCTAssertEqual(RingChartScrub.hourRange(spo2, hour: 1.7)?.high, 98)
        XCTAssertNil(RingChartScrub.hourRange(spo2, hour: 5))
        XCTAssertNil(RingChartScrub.hourRange(nil, hour: 1))
    }

    // MARK: Cards render

    /// The ring page's stat cards with a full day in them: they lay out, and with
    /// `RING_SNAPSHOT_DIR` set the render is written out to look at.
    func testTheStatCardsRenderADay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RingChartScrub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RingHistoryStore(directory: directory)
        let key = "2026-09-13"
        store.update(key) { day in
            day.activity = RingActivity(steps: 8432, runningSteps: 1200, calories: 312_000, distanceMeters: 6100, sportMinutes: 48)
            day.mergeStepSlots((28..<80).map { RingStepSlot(slot: $0, steps: ($0 * 37) % 400, calories: 0, distanceMeters: 0) })
            day.heartRate = RingSeries(intervalMinutes: 5, values: (0..<288).map { 58 + Double(($0 * 13) % 40) })
            day.hrv = RingSeries(intervalMinutes: 30, values: (0..<48).map { 30 + Double(($0 * 7) % 25) })
            day.spo2 = RingMinMax(min: (0..<24).map { 93 + $0 % 3 }, max: (0..<24).map { 97 + $0 % 3 })
            let start = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0,
                                              of: Date(timeIntervalSince1970: 1_789_300_000))!
            day.mergeSleep(RingSleepSession(start: start, end: start.addingTimeInterval(7 * 3600), reportedStartMinute: 1380,
                                            stages: [RingSleepStage(stage: RingSleepStage.light, minutes: 90),
                                                     RingSleepStage(stage: RingSleepStage.deep, minutes: 80),
                                                     RingSleepStage(stage: RingSleepStage.rem, minutes: 60),
                                                     RingSleepStage(stage: RingSleepStage.light, minutes: 150),
                                                     RingSleepStage(stage: RingSleepStage.awake, minutes: 40)]))
        }

        let size = CGSize(width: 402, height: 2400)
        let host = UIHostingController(rootView:
            ScrollView {
                RingStatsSections(store: store, dayKey: key, capabilities: RingCapabilities())
                    .padding(.vertical, 20)
            }
            .preferredColorScheme(.dark)
            .background(JcTheme.bg))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let image = UIGraphicsImageRenderer(size: size).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        window.isHidden = true
        XCTAssertEqual(image.size, size)

        if let out = ProcessInfo.processInfo.environment["RING_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: url.appendingPathComponent("ring-stat-cards.png"))
        }
    }
}
