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
        XCTAssertFalse(BandMeasurePlan.autoSwitches.contains("auto_ppg"), "sleep stays the band's")
    }

    /// His 8:15 PM run: heart rate "not worn" (worn), then nothing for its whole 15 minutes.
    func testAFailedReadingIsTriedAgainSoonAndReadingsWaitForTheSensor() {
        let defaults = UserDefaults(suiteName: "BandMeasureRetryTests")!
        defaults.removePersistentDomain(forName: "BandMeasureRetryTests")
        let scheduler = BandMeasureScheduler(defaults: defaults)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        scheduler.now = { clock }
        var plan = BandMeasurePlan()
        plan.control = .phone
        plan.intervals = ["heart_rate": 15]
        scheduler.seedForTests(plan)
        XCTAssertEqual(scheduler.due(at: clock), .heartRate)
        scheduler.finished(.heartRate, done: false)
        XCTAssertNil(scheduler.due(at: clock.addingTimeInterval(61)), "a failure waits 3 minutes, not 15")
        clock = clock.addingTimeInterval(181)
        XCTAssertEqual(scheduler.due(at: clock), .heartRate, "then it's tried again")
        scheduler.finished(.heartRate, done: false)
        XCTAssertNil(scheduler.due(at: clock.addingTimeInterval(200)), "a second failure waits 6")
        XCTAssertEqual(scheduler.due(at: clock.addingTimeInterval(361)), .heartRate)
        clock = clock.addingTimeInterval(361)
        scheduler.finished(.heartRate, done: true)
        XCTAssertNil(scheduler.due(at: clock.addingTimeInterval(14 * 60)), "a value: its interval again")
        XCTAssertEqual(scheduler.due(at: clock.addingTimeInterval(15 * 60 + 1)), .heartRate)
        // Back to back the band said "not worn": the next waits a minute after the last ended.
        var two = plan
        two.intervals = ["heart_rate": 15, "spo2": 15]
        scheduler.seedForTests(two)
        scheduler.finished(.bloodOxygen, done: true)
        XCTAssertNil(scheduler.due(at: clock.addingTimeInterval(30)))
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
