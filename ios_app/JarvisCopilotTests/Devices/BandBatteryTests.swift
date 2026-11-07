import XCTest
@testable import JarvisCopilot

/// The band's battery log: charges, the drain a day, time left, and where the battery went.
@MainActor
final class BandBatteryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    private func sample(_ hours: Double, _ percent: Int, charging: Bool = false) -> BandBatteryLog.Sample {
        .init(date: at(hours), percent: percent, charging: charging)
    }

    func testAChargeIsFoundOnTheChargerAndAfterAGap() {
        let samples = [
            sample(0, 40), sample(1, 38),
            sample(1.5, 39, charging: true), sample(2, 70, charging: true), sample(2.5, 100, charging: true),
            sample(3, 100),
            // Away from the phone, then back higher: a charge it didn't see.
            sample(10, 90), sample(20, 96),
        ]
        let charges = BandBatteryReport.charges(samples)
        XCTAssertEqual(charges.count, 2)
        XCTAssertEqual(charges[0].from, 38)
        XCTAssertEqual(charges[0].to, 100)
        XCTAssertTrue(charges[0].observed)
        XCTAssertFalse(charges[0].ongoing)
        XCTAssertEqual(charges[0].duration, 3600, accuracy: 1)
        XCTAssertEqual(charges[1].from, 90)
        XCTAssertEqual(charges[1].to, 96)
        XCTAssertFalse(charges[1].observed)

        let report = BandBatteryReport(samples: samples, spans: [], now: at(21))
        XCTAssertEqual(report.lastCharge?.to, 96)
    }

    func testAChargeUnderWayIsntTheLastCharge() {
        let report = BandBatteryReport(samples: [sample(0, 30), sample(1, 31, charging: true)], spans: [], now: at(1))
        XCTAssertNil(report.lastCharge)
        XCTAssertTrue(report.charging)
        XCTAssertEqual(report.charges.first?.ongoing, true)
    }

    func testTheDrainADayCountsOnlyWhatWasFollowedAndGivesTimeLeft() {
        // 1 point an hour for 12 hours, then 12 hours unseen with the same fall: 24 a day.
        let samples = [sample(0, 100), sample(12, 88), sample(24, 76)]
        let report = BandBatteryReport(samples: samples, spans: [], now: at(24))
        XCTAssertEqual(report.perDay(since: at(-1)) ?? 0, 24, accuracy: 0.01)
        XCTAssertEqual(report.recentPerHour ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(report.timeLeft ?? 0, 76 * 3600, accuracy: 1)
        // Not enough followed yet.
        XCTAssertNil(BandBatteryReport(samples: [sample(0, 100), sample(1, 99)], spans: [], now: at(1)).perDay(since: at(-1)))
    }

    func testEachDayGetsItsShareOfADrainAcrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.startOfDay(for: at(48))
        let a = BandBatteryLog.Sample(date: midnight.addingTimeInterval(-3 * 3600), percent: 80, charging: false)
        let b = BandBatteryLog.Sample(date: midnight.addingTimeInterval(3600), percent: 72, charging: false)
        let report = BandBatteryReport(samples: [a, b], spans: [], now: midnight.addingTimeInterval(2 * 3600))
        let days = report.days(2, calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].points, 6, accuracy: 0.01)
        XCTAssertEqual(days[1].points, 2, accuracy: 0.01)
    }

    func testTheDrainIsSharedOverWhatTheBandWasDoing() {
        // 10 points over 10 hours: a 2-hour workout while linked, 4 hours linked, the rest alone.
        let spans = [
            BandBatteryLog.Span(kind: .linked, start: at(0), end: at(6)),
            BandBatteryLog.Span(kind: .workout, start: at(1), end: at(3)),
        ]
        let report = BandBatteryReport(samples: [sample(0, 90), sample(10, 80)], spans: spans, now: at(10))
        let uses = Dictionary(uniqueKeysWithValues: report.uses(since: at(-1)).map { ($0.kind?.rawValue ?? "alone", $0) })
        XCTAssertEqual(uses["workout"]?.points ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(uses["linked"]?.points ?? 0, 4, accuracy: 0.01)
        XCTAssertEqual(uses["alone"]?.points ?? 0, 4, accuracy: 0.01)
        XCTAssertEqual(uses["workout"]?.seconds ?? 0, 7200, accuracy: 1)
        XCTAssertNil(uses["reading"])
    }

    /// Who managed measuring is logged with what changed it, and the drain is measured per mode
    /// (the Nov 3 switch to Band couldn't be traced, nor its cost told apart).
    func testTheDrainIsMeasuredForEachWayOfManaging() {
        let log = BandBatteryLog(file: nil)
        var clock = t0
        log.now = { clock }
        log.note(.phoneManaged, detail: "app")
        log.record(percent: 90, charging: false)
        clock = at(24)
        log.record(percent: 80, charging: false)
        log.note(.bandManaged, detail: "jarvis")
        clock = at(48)
        log.record(percent: 55, charging: false)
        let report = log.report()
        XCTAssertEqual(report.perDay(managedBy: .phone, since: t0) ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(report.perDay(managedBy: .band, since: t0) ?? -1, 25, accuracy: 0.01)
        XCTAssertEqual(report.managedBy(at: at(30)), .band)
        XCTAssertNil(report.managedBy(at: at(-1)), "before the first change: unknown")
        XCTAssertEqual(log.events.last?.detail, "jarvis")
    }

    /// A log written before events had details still loads.
    func testALogFromBeforeEventDetailsLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("log.json")
        try Data(#"{"samples":[],"spans":[],"events":[{"kind":"sync","date":0}],"open":{}}"#.utf8).write(to: file)
        let log = BandBatteryLog(file: file)
        XCTAssertEqual(log.events.count, 1)
        XCTAssertNil(log.events.first?.detail)
    }

    /// Over 12 points a day across the last day followed → one alert naming the likely cause.
    func testTheDrainAlertNamesTheLikelyCause() {
        func report(_ samples: [BandBatteryLog.Sample], now: Double) -> BandBatteryReport {
            BandBatteryReport(samples: samples, spans: [], now: at(now))
        }
        let heavy = report([sample(0, 100), sample(12, 85), sample(24, 70)], now: 24)
        let band = BandDrainAlert.message(heavy, control: .band, autosOn: [])
        XCTAssertNotNil(band)
        XCTAssertTrue(band?.contains("Managed by Band") == true, band ?? "")
        let autos = BandDrainAlert.message(heavy, control: .phone, autosOn: ["auto_blood_pressure"])
        XCTAssertTrue(autos?.contains("blood pressure") == true, autos ?? "")
        XCTAssertNil(BandDrainAlert.message(report([sample(0, 100), sample(24, 92)], now: 24),
                                            control: .band, autosOn: []), "8 a day is fine")
        XCTAssertNil(BandDrainAlert.message(report([sample(16, 100), sample(24, 90)], now: 24),
                                            control: .band, autosOn: []), "8 h followed isn't a day")
    }

    func testTheLogKeepsChangesAndSpansAndSkipsRepeats() {
        let log = BandBatteryLog(file: nil)
        var clock = t0
        log.now = { clock }
        log.record(percent: 80, charging: false)
        clock = at(0.1)
        log.record(percent: 80, charging: false)   // unchanged, too soon: skipped
        log.set(.workout, true)
        log.set(.workout, true)                    // already on
        clock = at(0.6)
        log.record(percent: 80, charging: false)   // unchanged but 30 min on: kept
        log.set(.workout, false)
        log.note(.sync)
        XCTAssertEqual(log.samples.count, 2)
        XCTAssertEqual(log.spans.count, 1)
        XCTAssertEqual(log.spans.first?.end.timeIntervalSince(log.spans.first!.start) ?? 0, 0.5 * 3600, accuracy: 1)
        log.set(.sensing, true)
        clock = at(2)
        let report = log.report()
        XCTAssertEqual(report.seconds(.sensing, since: t0), 1.4 * 3600, accuracy: 1)
        XCTAssertEqual(report.count(.sync, since: t0), 1)
    }

    func testTheLogPersistsAndClosesWhatWasUnderWay() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("band-battery-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var clock = t0
        let log = BandBatteryLog(file: file)
        log.now = { clock }
        log.record(percent: 70, charging: false)
        log.set(.linked, true)
        log.set(.sensing, true)
        clock = at(1)
        log.record(percent: 69, charging: false)

        let reopened = BandBatteryLog(file: file)
        reopened.now = { self.at(5) }
        XCTAssertEqual(reopened.samples.map(\.percent), [70, 69])
        // The link ended when the app last wrote; sensing carries on.
        XCTAssertEqual(reopened.spans.first { $0.kind == .linked }?.end, at(1))
        XCTAssertEqual(reopened.report().seconds(.sensing, since: t0), 5 * 3600, accuracy: 1)
    }
}
