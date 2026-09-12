import XCTest
@testable import JarvisCopilot

/// Byte layouts recovered from QRing's SDK — a regression here means the ring stops
/// understanding us.
final class RingProtocolTests: XCTestCase {

    func testCommandFramesArePaddedAndChecksummed() {
        let battery = [UInt8](RingProtocol.frame(0x03))
        XCTAssertEqual(battery.count, 16)
        XCTAssertEqual(battery.first, 0x03)
        XCTAssertEqual(Array(battery[1..<15]), [UInt8](repeating: 0, count: 14))
        XCTAssertEqual(battery.last, 0x03)

        let find = [UInt8](RingProtocol.frame(0x50, [0x55, 0xAA]))
        XCTAssertEqual(Array(find.prefix(3)), [0x50, 0x55, 0xAA])
        XCTAssertEqual(find[15], 0x4F)
    }

    func testAPayloadLongerThanFourteenBytesIsTruncated() {
        let bytes = [UInt8](RingProtocol.frame(0x01, Array(1...20)))
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(bytes[14], 14)
    }

    /// `0x5A` is the accelerometer poll added by the JarvisCopilot firmware patch: a bare
    /// command frame out, `x y z` int16 LE back.
    func testAccelerometerRequestAndReply() {
        let req = [UInt8](RingProtocol.frame(RingOp.accelerometer))
        XCTAssertEqual(req.count, 16)
        XCTAssertEqual(req[0], 0x5A)
        XCTAssertEqual(req[15], 0x5A)
        // 7, -7, 1007 — the emulator's slot-7 sample
        let sample = RingDecode.accelerometer([0x07, 0x00, 0xF9, 0xFF, 0xEF, 0x03])
        XCTAssertEqual(sample?.x, 7)
        XCTAssertEqual(sample?.y, -7)
        XCTAssertEqual(sample?.z, 1007)
        XCTAssertNil(RingDecode.accelerometer([1, 2, 3]))
        XCTAssertEqual(RingRequest.readAccelerometer.cmd, 0x5A)

        // Stock path: subtype 3 of the 0xA1 telemetry burst, big-endian int16 per axis.
        // payload = frame after the cmd byte: [3][x_hi][x_lo][y_hi][y_lo][z_hi][z_lo]
        let tel = RingDecode.accelFromTelemetry([3, 0x00, 0x07, 0xFF, 0xF9, 0x03, 0xEF])
        XCTAssertEqual(tel?.x, 7)
        XCTAssertEqual(tel?.y, -7)
        XCTAssertEqual(tel?.z, 1007)
        XCTAssertNil(RingDecode.accelFromTelemetry([1, 0, 0]))     // wrong subtype
        XCTAssertEqual(RingOp.calibration, 0xA1)
    }

    func testCRC16IsModbus() {
        XCTAssertEqual(RingProtocol.crc16(Array("123456789".utf8)), 0x4B37)
        XCTAssertEqual(RingProtocol.crc16([UInt8]()), 0xFFFF)
    }

    func testBigDataFramesCarryLengthAndCRCLittleEndian() {
        let payload: [UInt8] = [0xFF, 0x01]
        let crc = RingProtocol.crc16(payload)
        XCTAssertEqual([UInt8](RingProtocol.bigDataFrame(0x27, payload)),
                       [0xBC, 0x27, 0x02, 0x00, UInt8(crc & 0xFF), UInt8(crc >> 8), 0xFF, 0x01])
        XCTAssertEqual([UInt8](RingProtocol.bigDataFrame(0x2E, [])), [0xBC, 0x2E, 0x00, 0x00, 0xFF, 0xFF])
    }

    func testParseCommandSplitsTheErrorFlagAndChecksum() {
        var bytes = [UInt8](RingProtocol.frame(0x03, [0x55, 0x01]))
        bytes[0] = 0x83
        bytes[15] = RingProtocol.checksum(bytes.prefix(15))
        let parsed = RingProtocol.parseCommand(Data(bytes))
        XCTAssertEqual(parsed?.inbound,
                       .command(cmd: 0x03, isError: true, payload: [0x55, 0x01] + [UInt8](repeating: 0, count: 12)))
        XCTAssertEqual(parsed?.checksumValid, true)

        bytes[15] &+= 1
        XCTAssertEqual(RingProtocol.parseCommand(Data(bytes))?.checksumValid, false)
    }

    func testHighOpcodesAreNotReadAsErrors() {
        let parsed = RingProtocol.parseCommand(RingProtocol.frame(0xA1, [1]))
        XCTAssertEqual(parsed?.inbound.cmd, 0xA1)
        XCTAssertEqual(parsed?.inbound.isError, false)
    }

    func testAssemblerRebuildsAFrameSplitAcrossNotifications() {
        let payload = [UInt8](0..<40)
        var assembler = RingBigDataAssembler()
        var got: [(inbound: RingInbound, crcValid: Bool)] = []
        for chunk in RingProtocol.chunks(RingProtocol.bigDataFrame(0x75, payload), size: 20) {
            got += assembler.append(chunk)
        }
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.inbound, .bigData(cmd: 0x75, payload: payload))
        XCTAssertEqual(got.first?.crcValid, true)
    }

    func testAssemblerEmitsBackToBackFramesAndDropsNoise() {
        var assembler = RingBigDataAssembler()
        XCTAssertTrue(assembler.append(Data([0x01, 0x02, 0x03])).isEmpty)

        let two = RingProtocol.bigDataFrame(0x28, [1, 2, 3]) + RingProtocol.bigDataFrame(0x49, [])
        XCTAssertEqual(assembler.append(two).map(\.inbound),
                       [.bigData(cmd: 0x28, payload: [1, 2, 3]), .bigData(cmd: 0x49, payload: [])])
    }

    func testAStalePartialFrameIsDroppedWhenANewFrameStarts() {
        var assembler = RingBigDataAssembler()
        let start = Date()
        let interrupted = [UInt8](RingProtocol.bigDataFrame(0x75, [UInt8](0..<30))).prefix(12)
        XCTAssertTrue(assembler.append(Data(interrupted), now: start).isEmpty)

        let fresh = RingProtocol.bigDataFrame(0x28, [9])
        XCTAssertEqual(assembler.append(fresh, now: start.addingTimeInterval(10)).map(\.inbound),
                       [.bigData(cmd: 0x28, payload: [9])])
    }

    func testRingNamesMatchTheRSeriesAndQRingsBuiltInList() {
        for name in ["R12_7E04", "R02_ABCD", "R10", "RING1", "Hello Ring 2"] {
            XCTAssertTrue(RingProtocol.isRingName(name), name)
        }
        for name in ["VSITOO-S1-Pro", "Rover", "R1", "ESF551", ""] {
            XCTAssertFalse(RingProtocol.isRingName(name), name)
        }
    }

    func testSetTimeIsBCDWithLanguage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 14, minute: 7, second: 5))!
        let request = RingRequest.setTime(date, calendar: calendar)
        XCTAssertEqual(request.cmd, 0x01)
        XCTAssertEqual(request.payload, [0x26, 0x09, 0x11, 0x14, 0x07, 0x05, 0x01])
    }

    func testRequestBuildersMatchTheSDKLayouts() {
        XCTAssertEqual(RingRequest.stepDetail(dayOffset: 2).payload, [0x02, 0x0F, 0x00, 0x5F, 0x01])
        XCTAssertEqual(RingRequest.writeHRVMonitor(enabled: true, intervalMinutes: 60).payload,
                       [0x02, 0x01, 0x0A, 0x60, 0, 0, 0])
        XCTAssertEqual(RingRequest.writeHRVMonitor(enabled: false, intervalMinutes: 30).payload,
                       [0x02, 0x00, 0x0A, 30, 0, 0, 0])
        XCTAssertEqual(RingRequest.writeGoals(RingGoals(steps: 0x012345, calories: 300_000, distanceMeters: 5000,
                                                        sportMinutes: 90, sleepMinutes: 480)).payload,
                       [0x02, 0x45, 0x23, 0x01, 0xE0, 0x93, 0x04, 0x88, 0x13, 0x00, 0x5A, 0x00, 0xE0, 0x01])
        XCTAssertEqual(RingRequest.startMeasurement(.heartRate).payload, [0x01, 0x00])
        XCTAssertEqual(RingRequest.startMeasurement(.spo2).payload, [0x03, 0x25])
        XCTAssertEqual(RingRequest.stopMeasurement(.heartRate, value: 72).payload, [0x01, 72, 0])
        XCTAssertEqual(RingRequest.factoryReset.cmd, 0xFF)
        XCTAssertEqual(RingRequest.factoryReset.payload, [0x66, 0x66])
        XCTAssertEqual(RingRequest.findRing.payload, [0x55, 0xAA])
        XCTAssertEqual(RingRequest.heartRateHistory(timestamp: 0x12345678).payload, [0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(RingRequest.phoneStillTime(inUse: true, counter: 0x0102).payload, [0x02, 0x01, 0x02, 0x01])
        XCTAssertEqual(RingRequest.bigSleep(all: true), RingRequest(channel: .bigData, cmd: 0x27, payload: [0xFF, 0x01]))
        XCTAssertEqual(RingRequest.bigIntervalTemperature(dayOffset: 3, packet: 1).payload, [3, 1])
        XCTAssertEqual(RingRequest.writeTemperatureMonitor(RingTemperatureMonitor(
            enabled: true, intervalMinutes: 30, start: 5, remindIntervalMinutes: 10,
            alertFlags: 0b1010, customAlertCelsius: 38.5)).payload,
                       [0x03, 0x02, 0x01, 30, 5, 10, 0x0A, 185])
        XCTAssertEqual(RingRequest.writeSedentary(RingSedentary(startHour: 9, startMinute: 30, endHour: 18,
                                                                endMinute: 0, weekMask: 0x7F, cycleMinutes: 60)).payload,
                       [0x09, 0x30, 0x18, 0x00, 0x7F, 60])
        XCTAssertEqual(RingRequest.writeDND(RingDND(enabled: false, startHour: 22, startMinute: 0,
                                                    endHour: 7, endMinute: 30, manual: false)).payload,
                       [0x02, 0x02, 22, 0, 7, 30])
        XCTAssertEqual(RingRequest.writeProfile(RingProfile(use24Hour: true, metric: true, sex: 0, age: 30,
                                                            heightCm: 180, weightKg: 75, systolic: 120, diastolic: 90,
                                                            heartRateWarning: 160, open: 2)).payload,
                       [0x02, 0, 0, 0, 30, 180, 75, 120, 90, 160, 2])
        XCTAssertEqual(RingRequest.writeHeartRateMonitor(RingHeartRateMonitor(
            enabled: false, intervalMinutes: 10, start: 5, lowWarning: 50, highWarning: 180,
            mainSwitch: 1, maxInterval: 60)).payload,
                       [0x02, 0x02, 10, 5, 50, 180, 1])
    }
}
