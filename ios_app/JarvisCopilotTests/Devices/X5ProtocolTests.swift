import XCTest
@testable import JarvisCopilot

/// Request frames for the X5 touch ring. Every expected frame below was printed by the
/// vendor's own SDK (run offline as an oracle), checksum included.
final class X5ProtocolTests: XCTestCase {

    private func bytes(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    private func assertFrame(_ request: RingRequest, _ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = bytes(hex)
        XCTAssertEqual([UInt8](request.bytes), expected, file: file, line: line)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testGoalFramesMatchTheVendorSDK() {
        assertFrame(.x5GetGoal, "4B 00 00 00 00 00 00 00 00 00 00 00 00 00 00 4B")
        assertFrame(.x5SetGoal(8000), "0B 40 1F 00 00 00 00 00 00 00 00 00 00 00 00 6A")
    }

    func testHIDFramesMatchTheVendorSDK() {
        assertFrame(.x5GetHID, "1C 00 00 00 00 00 00 00 00 00 00 00 00 00 00 1C")
        assertFrame(.x5SetHID(enabled: true, mode: .keys, awakeSeconds: 0),
                    "1C 01 01 00 00 00 01 00 00 00 00 00 00 00 00 1F")
        assertFrame(.x5SetHID(enabled: true, mode: .shortVideo, awakeSeconds: 0),
                    "1C 01 01 01 00 00 01 00 00 00 00 00 00 00 00 20")
        assertFrame(.x5SetHID(enabled: true, mode: .music, awakeSeconds: 0),
                    "1C 01 01 02 00 00 01 00 00 00 00 00 00 00 00 21")
        assertFrame(.x5SetHID(enabled: true, mode: .camera, awakeSeconds: 0),
                    "1C 01 01 03 00 00 01 00 00 00 00 00 00 00 00 22")
        assertFrame(.x5SetHID(enabled: false, mode: .keys, awakeSeconds: 0),
                    "1C 01 00 00 00 00 01 00 00 00 00 00 00 00 00 1E")
        assertFrame(.x5GetHIDDelay, "1C 03 00 00 00 00 00 00 00 00 00 00 00 00 00 1F")
        // The delay is little-endian (高位在后): 300 s = 2C 01.
        assertFrame(.x5SetHIDDelay(300), "1C 02 2C 01 00 00 00 00 00 00 00 00 00 00 00 4B")
    }

    func testHIDAwakeTimeTravelsLittleEndianInTheSetFrame() {
        let payload = Array(RingRequest.x5SetHID(enabled: true, mode: .keys, awakeSeconds: 300).payload.prefix(6))
        XCTAssertEqual(payload, [0x01, 0x01, 0x00, 0x2C, 0x01, 0x01])
    }

    func testMeasurementAndLiveFramesMatchTheVendorSDK() {
        assertFrame(.x5PPG(1), "78 01 00 00 00 00 00 00 00 00 00 00 00 00 00 79")
        assertFrame(.x5PPG(2, status: 50), "78 02 32 00 00 00 00 00 00 00 00 00 00 00 00 AC")
        assertFrame(.x5Live(true), "09 01 00 00 00 00 00 00 00 00 00 00 00 00 00 0A")
        assertFrame(.x5Measure(2, start: true, seconds: 30), "28 02 01 00 1E 00 00 00 00 00 00 00 00 00 00 49")
        assertFrame(.x5Measure(3, start: true, seconds: 30), "28 03 01 00 1E 00 00 00 00 00 00 00 00 00 00 4A")
        assertFrame(.x5MeasureStatus, "28 80 00 00 00 00 00 00 00 00 00 00 00 00 00 A8")
    }

    func testHistoryFramesMatchTheVendorSDK() {
        assertFrame(.x5History(.singleHR, after: nil), "55 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55")
        assertFrame(.x5History(.manualSpO2, after: nil), "60 00 00 00 00 00 00 00 00 00 00 00 00 00 00 60")
        assertFrame(.x5History(.workouts, after: nil), "5C 00 00 00 00 00 00 00 00 00 00 00 00 00 00 5C")
    }

    func testHistoryCursorTravelsAsBCD() {
        let request = RingRequest.x5History(.sleep, after: date(2024, 8, 23, 13, 36, 0), calendar: utc)
        XCTAssertEqual(request.cmd, 0x53)
        XCTAssertEqual(Array(request.payload.prefix(9)), [0x00, 0x00, 0x00, 0x24, 0x08, 0x23, 0x13, 0x36, 0x00])
        XCTAssertEqual(RingRequest.x5HistoryNext(.hrv).payload.first, 0x02)
        XCTAssertEqual(RingRequest.x5HistoryNext(.hrv).cmd, 0x56)
        XCTAssertEqual(RingRequest.x5HistoryDelete(.hrv).payload.first, 0x99)
    }

    func testWorkoutFramesMatchTheVendorSDK() {
        assertFrame(.x5Workout(5, sport: .run), "19 05 00 00 00 00 00 00 00 00 00 00 00 00 00 1E")
        assertFrame(.x5Workout(1, sport: .meditation, level: 1, minutes: 10),
                    "19 01 06 01 0A 00 00 00 00 00 00 00 00 00 00 2B")
    }

    func testMaintenanceFramesMatchTheVendorSDK() {
        assertFrame(.x5ClearAll, "61 00 00 00 00 00 00 00 00 00 00 00 00 00 00 61")
        assertFrame(.x5Power(off: false), "12 00 00 00 00 00 00 00 00 00 00 00 00 00 00 12")
        assertFrame(.x5Restart, "2E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 2E")
        assertFrame(.x5Unbind, "87 00 00 00 00 00 00 00 00 00 00 00 00 00 00 87")
    }

    func testMonitoringFrameMatchesTheVendorSDK() {
        let monitoring = X5Monitoring(on: true, startHour: 0, startMinute: 0, endHour: 23, endMinute: 59,
                                      weekdays: 0x7F, intervalMinutes: 5, type: .hrv)
        assertFrame(.x5SetMonitoring(monitoring), "2A 02 00 00 23 59 7F 05 00 04 00 00 00 00 00 30")
        XCTAssertEqual(RingRequest.x5GetMonitoring(.spo2).payload.first, 0x02)
        XCTAssertEqual(RingRequest.x5GetMonitoring(.spo2).cmd, 0x2B)
    }

    func testSetTimeIsBCD() {
        let request = RingRequest.x5SetTime(date(2024, 8, 10, 13, 14, 59), calendar: utc)
        XCTAssertEqual(request.cmd, 0x01)
        XCTAssertEqual(Array(request.payload.prefix(6)), [0x24, 0x08, 0x10, 0x13, 0x14, 0x59])
    }

    func testProfileFrameCarriesSexAgeHeightWeightStride() {
        let request = RingRequest.x5SetProfile(male: false, age: 37, heightCm: 170, weightKg: 50, strideCm: 59)
        XCTAssertEqual(request.cmd, 0x02)
        XCTAssertEqual(Array(request.payload.prefix(5)), [0x00, 37, 170, 50, 59])
    }

    func testEntryLengthsMatchTheRepliesTheSDKParses() {
        let lengths: [X5HistoryKind: Int] = [.dayTotals: 27, .stepBlocks: 25, .sleep: 130, .continuousHR: 24,
                                              .singleHR: 10, .hrv: 15, .temperature: 11, .autoSpO2: 10,
                                              .manualSpO2: 10, .workouts: 25]
        for kind in X5HistoryKind.allCases {
            XCTAssertEqual(kind.entryLength, lengths[kind], "\(kind)")
        }
    }

    func testNameMatcherAcceptsX5AndRejectsOtherWearables() {
        XCTAssertTrue(X5Protocol.isX5Name("X5_7A21"))
        XCTAssertTrue(X5Protocol.isX5Name("x5 ring"))
        XCTAssertTrue(X5Protocol.isX5Name("X5"))
        XCTAssertFalse(X5Protocol.isX5Name("R12_7E04"))
        XCTAssertFalse(X5Protocol.isX5Name("JBL GO 3"))
        XCTAssertFalse(X5Protocol.isX5Name("X50"))
    }
}
