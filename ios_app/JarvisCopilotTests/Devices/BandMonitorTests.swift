import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The band's Health & Monitor settings: the calibration frames the Android SDK writes, their
/// replies, what the real E910 offers, and the screen (written to /tmp/ringshots).
@MainActor
final class BandMonitorTests: XCTestCase {
    private func hex(_ f: [UInt8]) -> String { f.map { String(format: "%02x", $0) }.joined() }

    func testTheCalibrationFramesAreTheSDKs() {
        XCTAssertEqual(hex(BandRequest.bloodPressureCalibration(.init(enabled: true, systolic: 121, diastolic: 79))),
                       "9101794f00" + String(repeating: "00", count: 15))
        XCTAssertTrue(hex(BandRequest.readBloodPressureCalibration()).hasPrefix("9102"))
        let component = BandRequest.bloodComponentCalibration(.init(enabled: true, uricAcid: 350, cholesterol: 4.6,
                                                                    triglycerides: 1.2, hdl: 1.4, ldl: 2.7))
        // 8A 02 01 on, uric 3500 (×10), TC 460, TG 120, HDL 140, LDL 270 (×100), little-endian.
        XCTAssertEqual(hex(Array(component.prefix(14))), "8a020101ac0dcc0178008c000e01")
        XCTAssertTrue(hex(BandRequest.readGlucoseMealCalibration()).hasPrefix("8903020101"))
    }

    func testTheMealReferencesGoInTwoFramesAndReadBack() throws {
        let c = BandGlucoseCalibration(enabled: true, meals: [
            .init(beforeMinute: 7 * 60 + 30, before: 5.2, afterMinute: 9 * 60, after: 7.4),
            .init(beforeMinute: 12 * 60, before: 5.0, afterMinute: 14 * 60, after: 6.9),
            .init(),
        ])
        let frames = BandRequest.glucoseMealCalibrationFrames(c)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(hex(Array(frames[0].prefix(5))), "8903010102")
        XCTAssertEqual(hex(Array(frames[1].prefix(5))), "8903010202")
        // on, breakfast 07:30 5.20 (0802 LE), 09:00 7.40 (e402) …
        XCTAssertEqual(hex(Array(frames[0][5..<14])), "01071e08020900e402")
        // … lunch's after-meal 6.90 (b202), then dinner left empty: 00ff 0000 00ff 0000.
        XCTAssertEqual(hex(Array(frames[1][5..<15])), "b20200ff000000ff0000")
        // The band's read reply carries the same 25 bytes from byte 6, split 14 / 11.
        let payload = Array(frames[0][5..<20]) + Array(frames[1][5..<15])
        let read1: [UInt8] = [0x89, 0x03, 0x02, 0x01, 0x01, 0x02] + Array(payload[0..<14])
        let read2: [UInt8] = [0x89, 0x03, 0x02, 0x01, 0x02, 0x02] + Array(payload[14..<25]) + [0, 0, 0]
        let back = try XCTUnwrap(BandDecode.glucoseMealCalibration([read2, read1]))
        XCTAssertEqual(back, c)
    }

    func testTheRepliesDecode() throws {
        let bp = try XCTUnwrap(BandDecode.bloodPressureCalibration(BandFakeLink.bytes("9101794f0102" + String(repeating: "00", count: 14))))
        XCTAssertEqual(bp, BandBPCalibration(enabled: true, systolic: 121, diastolic: 79))
        XCTAssertNil(BandDecode.bloodPressureCalibration(BandFakeLink.bytes("9100000000020000")), "byte 1 = 0 is a failure")
        let c = try XCTUnwrap(BandDecode.bloodComponentCalibration(
            BandFakeLink.bytes("8a02020101ac0dcc0178008c000e01" + String(repeating: "00", count: 5))))
        XCTAssertEqual(c.uricAcid, 350)
        XCTAssertEqual(c.ldl, 2.7, accuracy: 0.001)
        XCTAssertTrue(c.enabled)
    }

    func testTheNightSpO2WindowIsReadTheWayTheSDKReadsIt() throws {
        XCTAssertEqual(hex(Array(BandRequest.readBloodOxygenAuto().prefix(8))), "b300011600080000")
        // His band's reply to a set (22:00–07:00 on) — the read answers the same way, operation 1.
        let s = try XCTUnwrap(BandDecode.bloodOxygenAuto(BandFakeLink.bytes("b30100011600070001" + String(repeating: "00", count: 11))))
        XCTAssertEqual(s, BandOxygenSchedule(enabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0))
    }

    func testThePhoneAsksForTheMostOverdueReadingAndNoneWhenTheBandManages() {
        let defaults = UserDefaults(suiteName: "BandMeasureSchedulerTests")!
        defaults.removePersistentDomain(forName: "BandMeasureSchedulerTests")
        let scheduler = BandMeasureScheduler(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        scheduler.now = { now }
        XCTAssertEqual(scheduler.plan.control, .band)
        XCTAssertNil(scheduler.due(at: now), "the band manages itself: the phone asks for nothing")
        var plan = BandMeasurePlan()
        plan.control = .phone
        plan.intervals = ["heart_rate": 30, "spo2": 60, "blood_pressure": 0]
        // Heart rate is 10 min overdue, SpO2 50 min; blood pressure is off.
        scheduler.seedForTests(plan, lastRuns: ["heart_rate": now.addingTimeInterval(-40 * 60),
                                                "spo2": now.addingTimeInterval(-110 * 60),
                                                "blood_pressure": .distantPast])
        XCTAssertEqual(scheduler.due(at: now), .bloodOxygen)
        XCTAssertNil(scheduler.next(.bloodPressure), "off: never")
        XCTAssertEqual(scheduler.next(.heartRate), now, "overdue: now")
        scheduler.setInterval(240, for: .bloodOxygen)
        XCTAssertEqual(scheduler.due(at: now), .heartRate)
        XCTAssertEqual(BandMeasurePlan.label(120), "Every 2 h")
        XCTAssertFalse(BandMeasurePlan.autoSwitches.contains("auto_ppg"), "the pulse switch is the night window's")
    }

    /// His 8:15 PM run: heart rate "not worn" (worn), then nothing for its whole 15 minutes. And
    /// his 2026-10-13 log: a failing blood pressure tried at 3, 6, 12, 24… minutes — 7 readings an hour.
    func testAFailedReadingIsTriedOnceMoreThenWaitsForItsInterval() {
        let defaults = UserDefaults(suiteName: "BandMeasureRetryTests")!
        defaults.removePersistentDomain(forName: "BandMeasureRetryTests")
        let scheduler = BandMeasureScheduler(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = start
        scheduler.now = { clock }
        var plan = BandMeasurePlan()
        plan.control = .phone
        plan.intervals = ["heart_rate": 15]
        scheduler.seedForTests(plan, lastRuns: ["heart_rate": start.addingTimeInterval(-15 * 60)])
        XCTAssertEqual(scheduler.due(at: clock), .heartRate)
        scheduler.finished(.heartRate, done: false)
        XCTAssertNil(scheduler.due(at: clock.addingTimeInterval(61)), "a failure waits 3 minutes, not 15")
        clock = clock.addingTimeInterval(181)
        XCTAssertEqual(scheduler.due(at: clock), .heartRate, "then it's tried again")
        scheduler.finished(.heartRate, done: false)
        XCTAssertNil(scheduler.due(at: start.addingTimeInterval(15 * 60 - 1)), "a second failure waits for the next interval")
        XCTAssertEqual(scheduler.due(at: start.addingTimeInterval(15 * 60)), .heartRate, "which counts from when it was due")
        clock = start.addingTimeInterval(15 * 60 + 40)
        scheduler.finished(.heartRate, done: true)
        XCTAssertNil(scheduler.due(at: start.addingTimeInterval(30 * 60 - 1)), "a value: its interval again")
        XCTAssertEqual(scheduler.due(at: start.addingTimeInterval(30 * 60)), .heartRate, "on the cadence, not 40 s later")
        // Back to back the band said "not worn": the next waits a minute after the last ended.
        var two = plan
        two.intervals = ["heart_rate": 15, "spo2": 15]
        scheduler.seedForTests(two)
        scheduler.finished(.bloodOxygen, done: true)
        XCTAssertNil(scheduler.due(at: clock.addingTimeInterval(30)))
    }

    /// A reading more than an interval late starts its cadence afresh instead of catching up.
    func testALateReadingStartsItsIntervalAfresh() {
        let defaults = UserDefaults(suiteName: "BandMeasureLateTests")!
        defaults.removePersistentDomain(forName: "BandMeasureLateTests")
        let scheduler = BandMeasureScheduler(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = start
        scheduler.now = { clock }
        var plan = BandMeasurePlan()
        plan.control = .phone
        plan.intervals = ["blood_pressure": 60]
        scheduler.seedForTests(plan, lastRuns: ["blood_pressure": start.addingTimeInterval(-3 * 3600)])
        scheduler.finished(.bloodPressure, done: true)
        XCTAssertEqual(scheduler.lastRuns["blood_pressure"], clock)
        clock = start.addingTimeInterval(3600 + 50)
        scheduler.finished(.bloodPressure, done: true)
        XCTAssertEqual(scheduler.lastRuns["blood_pressure"], start.addingTimeInterval(3600))
    }

    /// Plans saved before the night window and HRV keep their control and intervals.
    func testAnOlderSavedPlanStillLoads() throws {
        let old = #"{"control":"phone","intervals":{"heart_rate":15,"blood_pressure":60},"bandSwitches":{"auto_heart_rate":true}}"#
        let plan = try JSONDecoder().decode(BandMeasurePlan.self, from: Data(old.utf8))
        XCTAssertEqual(plan.control, .phone)
        XCTAssertEqual(plan.interval(.heartRate), 15)
        XCTAssertEqual(plan.interval(BandMeasurePlan.hrv), 60, "HRV takes its default")
        XCTAssertTrue(plan.nightTracking)
        XCTAssertEqual(plan.nightStart, 21 * 60)
        XCTAssertEqual(plan.nightEnd, 11 * 60)
        XCTAssertEqual(plan.bandSwitches, ["auto_heart_rate": true])
    }

    /// Managed by phone, the band's every-minute pulse and HRV run only overnight (9 PM–11 AM by
    /// default) and, by day, through one 5-minute record on HRV's interval.
    func testTheBandsPulseAndHRVRunOvernightAndForOneRecordOnHRVsInterval() {
        let defaults = UserDefaults(suiteName: "BandMeasureSensingTests")!
        defaults.removePersistentDomain(forName: "BandMeasureSensingTests")
        let scheduler = BandMeasureScheduler(defaults: defaults)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        scheduler.calendar = utc
        func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
            utc.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: h, minute: m, second: s))!
        }
        var clock = at(14, 2, 30)
        scheduler.now = { clock }
        var plan = BandMeasurePlan()
        plan.control = .phone
        plan.intervals = [BandMeasurePlan.hrv: 60]
        scheduler.seedForTests(plan, lastRuns: [BandMeasurePlan.hrv: at(13, 0)])

        let on = ["auto_ppg": true, "auto_hrv": true], off = ["auto_ppg": false, "auto_hrv": false]
        XCTAssertEqual(scheduler.sensing(at: at(23, 30)), on, "overnight")
        XCTAssertEqual(scheduler.sensing(at: at(3, 0)), on, "across midnight")
        XCTAssertEqual(scheduler.sensing(at: at(10, 59)), on)
        XCTAssertEqual(scheduler.sensing(at: at(11, 0)), off, "the day")
        XCTAssertEqual(scheduler.sensing(at: at(20, 59)), off)

        // 14:02:30, an hour after the last: on through the 14:05–14:10 record, off 45 s after it.
        XCTAssertTrue(scheduler.hrvDue(at: clock))
        scheduler.startHrvIfDue()
        XCTAssertEqual(scheduler.hrvUntil, at(14, 10, 45))
        XCTAssertEqual(scheduler.sensing(at: at(14, 9)), on)
        XCTAssertEqual(scheduler.sensing(at: at(14, 10, 45)), off)
        XCTAssertFalse(scheduler.hrvDue(at: at(14, 30)))
        XCTAssertTrue(scheduler.hrvDue(at: at(15, 0)), "the next on its hour, from when it was due")
        // Overnight the band's HRV is on anyway: no window.
        clock = at(22, 0)
        XCTAssertFalse(scheduler.hrvDue(at: clock))
        // Off: never.
        plan.intervals = [BandMeasurePlan.hrv: 0]
        scheduler.seedForTests(plan)
        XCTAssertFalse(scheduler.hrvDue(at: at(15, 0)))
        // Sleep tracking off: the band's sensing stays off all night too.
        plan.nightTracking = false
        scheduler.seedForTests(plan)
        XCTAssertEqual(scheduler.sensing(at: at(2, 0)), off)
        // Managed by the band: the phone never asks.
        plan.control = .band
        plan.intervals = [BandMeasurePlan.hrv: 60]
        scheduler.seedForTests(plan)
        XCTAssertFalse(scheduler.hrvDue(at: at(15, 0)))
    }

    /// His 2026-10-13 day: every blood pressure / glucose / blood components reading twice — the
    /// phone's (05:13:24) and the band's 5-minute record of it (05:10:00).
    func testTheBandsRecordOfAPhoneReadingIsNotASecondReading() {
        let slot = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 300))
        func glucose(_ t: Date, _ outcome: String = "done") -> RingMeasurementRecord {
            RingMeasurementRecord(type: "blood_glucose", time: t, outcome: outcome, value: nil, systolic: nil,
                                  diastolic: nil, celsius: nil, extra: outcome == "done" ? ["blood_glucose_mmol_l": 4.6] : nil)
        }
        let copy = glucose(slot)
        XCTAssertTrue(BandDayMapper.takenByPhone(copy, in: [glucose(slot.addingTimeInterval(204))]))
        XCTAssertTrue(BandDayMapper.takenByPhone(copy, in: [glucose(slot.addingTimeInterval(305))]),
                      "the band's clock ran ~30 s behind: 06:50:05 went in the 06:45 record")
        XCTAssertFalse(BandDayMapper.takenByPhone(copy, in: [glucose(slot.addingTimeInterval(81), "not_worn")]),
                       "the phone got no value: the record's is the reading")
        XCTAssertFalse(BandDayMapper.takenByPhone(copy, in: [glucose(slot.addingTimeInterval(300))]),
                       "the next record's own reading is another one")
        XCTAssertFalse(BandDayMapper.takenByPhone(copy, in: [glucose(slot.addingTimeInterval(-600))]))
        XCTAssertFalse(BandDayMapper.takenByPhone(copy, in: [copy]))
    }

    /// His 2026-10-14 day: a band day (~38 KB) uploaded after every reading, ~12 times an hour.
    func testChangedDaysGoUpAtMostEveryHalfHourOrAtOnceWhileSomeoneLooks() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var sent: [Set<String>] = []
        var succeed = true
        let uploads = DayUploadThrottle(every: 1800, now: { clock }) { keys in
            sent.append(keys)
            return succeed
        }
        uploads.changed(["2026-10-14"], urgent: false)
        await Task.yield()
        XCTAssertEqual(sent, [["2026-10-14"]], "the first change goes up at once")

        clock = clock.addingTimeInterval(15 * 60)
        uploads.changed(["2026-10-14"], urgent: false)
        uploads.changed(["2026-10-13"], urgent: false)
        XCTAssertEqual(sent.count, 1, "readings within the half hour are held")
        XCTAssertEqual(uploads.pending, ["2026-10-13", "2026-10-14"])
        XCTAssertEqual(uploads.due, Date(timeIntervalSince1970: 1_800_000_000 + 1800))

        clock = clock.addingTimeInterval(60)
        await uploads.flush()?.value
        XCTAssertEqual(sent.last, ["2026-10-13", "2026-10-14"], "the Health screen opening sends what is held")
        XCTAssertNil(uploads.due)

        clock = clock.addingTimeInterval(60)
        uploads.changed(["2026-10-14"], urgent: true)
        await Task.yield()
        XCTAssertEqual(sent.count, 3, "while a screen shows it, a reading goes up at once")

        succeed = false
        clock = clock.addingTimeInterval(1800)
        uploads.changed(["2026-10-14"], urgent: false)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(uploads.pending, ["2026-10-14"], "a failed upload is held for the next one")
    }

    func testEveryMonitoringMetricIsASwitchTheBandFramesKnow() {
        let names = Set(BandSettings.switches.map(\.name))
        for (metric, name) in BandDevice.monitorSwitches {
            XCTAssertTrue(names.contains(name), "\(metric) → \(name)")
        }
    }

    // MARK: The real E910

    private func readyE910() async throws -> (BandSession, BandFakeLink) {
        let link = BandFakeLink()
        let session = BandSession()
        session.attach(link)
        link.transport = session.transport
        link.script(BandOp.password, BandRuntimeTests.handshake)
        link.script(BandOp.syncTime, ["a5010000000000000000000000000000000000"])
        link.script(BandOp.profile, ["a3010000000000000000000000000000000000"])
        link.script(BandOp.battery, [BandRuntimeTests.battery])
        link.script(BandOp.product, BandRuntimeTests.product)
        try await session.runSetup(profile: nil)
        return (session, link)
    }

    func testTheE910TakesAMealGlucoseReferenceAndTheOtherTwo() async throws {
        let (session, link) = try await readyE910()
        XCTAssertEqual(session.glucoseCalibrationKind, .meals, "its glucose tag is 4")
        XCTAssertTrue(session.calibratesBloodComponents, "its blood-component tag is 2")
        XCTAssertTrue(session.calibratesBloodPressure)
        XCTAssertNotNil(session.settings?.isOn("auto_hrv"))
        XCTAssertNotNil(session.settings?.isOn("auto_blood_glucose"))
        XCTAssertNil(session.settings?.isOn("met"), "the E910 has no MET switch")
        link.script(BandOp.bloodPressureCalibration, ["9101794f0102" + String(repeating: "00", count: 14)])
        link.script(BandOp.bloodComponent, ["8a02020100" + String(repeating: "00", count: 15)])
        link.script(BandOp.glucoseStress, ["89030201010200" + String(repeating: "00", count: 13),
                                           "8903020102020000000000000000000000000000"])
        await session.refreshCalibrations()
        XCTAssertEqual(session.bpCalibration?.systolic, 121)
        XCTAssertEqual(session.componentCalibration?.enabled, false)
        XCTAssertEqual(session.glucoseCalibration?.enabled, false)
    }

    func testTheSettingsRender() async throws {
        let (session, link) = try await readyE910()
        link.script(BandOp.bloodPressureCalibration, ["9101794f0102" + String(repeating: "00", count: 14)])
        await session.refreshCalibrations()
        let view = NavigationStack {
            ScrollView { BandMonitorSettings(session: session, scheduler: BandMeasureScheduler(defaults: UserDefaults(suiteName: "BandMonitorTests")!)) { _, _ in }.padding(.vertical, 12) }
        }
        try RenderHarness.write(view.environment(AppRouter()), size: CGSize(width: 402, height: 1700),
                                name: "band-monitor-settings", settle: 1)
        try RenderHarness.write(NavigationStack { BandGlucoseCalibrationEditor(session: session) }
            .environment(AppRouter()), size: CGSize(width: 402, height: 1500), name: "band-glucose-calibration", settle: 1)
    }
}
