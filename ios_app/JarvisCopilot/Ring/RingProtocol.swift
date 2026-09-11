import CoreBluetooth
import Foundation

/// Wire format for Colmi R-series smart rings, as driven by the QRing app's Oudmon BLE SDK.
///
/// Recovered from QRing 1.0.1.179 — see `ios_app/RING_PROTOCOL.md`. The ring has two
/// channels: a UART-style command service carrying fixed 16-byte frames, and a "large
/// data" service carrying variable-length `0xBC` frames for history (sleep, interval
/// series, manual readings).
enum RingProtocol {
    static let commandService = CBUUID(string: "6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E")
    static let commandWrite = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let commandNotify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let bigDataService = CBUUID(string: "DE5BF728-D711-4E47-AF26-65E3012A5DC7")
    static let bigDataWrite = CBUUID(string: "DE5BF72A-D711-4E47-AF26-65E3012A5DC7")
    static let bigDataNotify = CBUUID(string: "DE5BF729-D711-4E47-AF26-65E3012A5DC7")
    static let deviceInfoService = CBUUID(string: "180A")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let hardwareRevision = CBUUID(string: "2A27")

    static let frameLength = 16
    static let payloadLength = 14
    static let errorFlag: UInt8 = 0x80
    static let bigDataMagic: UInt8 = 0xBC
    static let bigDataHeaderLength = 6
    /// The SDK's floor for a large-data write chunk; the ring can announce more (`0x2F`).
    static let minimumChunk = 20

    /// QRing's built-in ring names besides the `R01`…`R99` series. Its live list comes from
    /// QRing's server, which is why `R12` is missing from the app's fallback.
    static let knownNames = ["VK-5098", "MERLIN", "Hello Ring", "RING1", "boAtring"]

    static func isRingName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        if bytes.count >= 3, bytes[0] == UInt8(ascii: "R"),
           (48...57).contains(bytes[1]), (48...57).contains(bytes[2]) {
            return true
        }
        return knownNames.contains { name.hasPrefix($0) }
    }

    /// Sum of the bytes, low byte. Covers bytes 0…14 of a command frame.
    static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 &+ Int($1) })
    }

    /// CRC-16/MODBUS (init 0xFFFF, reflected polynomial 0xA001) — the SDK's `CRC16.calcCrc16`.
    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    /// A command frame: opcode, 14 payload bytes (zero padded, anything longer dropped), checksum.
    static func frame(_ cmd: UInt8, _ payload: [UInt8] = []) -> Data {
        var bytes = [UInt8](repeating: 0, count: frameLength)
        bytes[0] = cmd
        for (i, byte) in payload.prefix(payloadLength).enumerated() { bytes[i + 1] = byte }
        bytes[frameLength - 1] = checksum(bytes.prefix(frameLength - 1))
        return Data(bytes)
    }

    /// A large-data frame: `BC cmd len16LE crc16LE payload`. An empty payload carries CRC `FFFF`.
    static func bigDataFrame(_ cmd: UInt8, _ payload: [UInt8]) -> Data {
        var out: [UInt8] = [bigDataMagic, cmd]
        if payload.isEmpty {
            out += [0x00, 0x00, 0xFF, 0xFF]
        } else {
            let length = UInt16(truncatingIfNeeded: payload.count)
            let crc = crc16(payload)
            out += [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(crc & 0xFF), UInt8(crc >> 8)]
            out += payload
        }
        return Data(out)
    }

    static func chunks(_ data: Data, size: Int) -> [Data] {
        let step = max(1, size)
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: step).map {
            Data(bytes[$0..<min($0 + step, bytes.count)])
        }
    }

    static func bcd(_ value: Int) -> UInt8 {
        let v = max(0, min(99, value))
        return UInt8((v / 10) << 4 | (v % 10))
    }

    static func fromBCD(_ byte: UInt8) -> Int {
        Int(byte >> 4) * 10 + Int(byte & 0x0F)
    }

    /// Splits a command notification into opcode, error flag and payload (bytes 1…14, the
    /// checksum dropped — what the SDK hands its parsers). Opcodes that are themselves ≥ 0x80
    /// (calibration `A1`, factory reset `FF`, …) are kept whole rather than read as an error
    /// flag on a low opcode.
    static func parseCommand(_ data: Data) -> (inbound: RingInbound, checksumValid: Bool)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let head = bytes[0]
        let isHigh = RingOp.highOpcodes.contains(head)
        let cmd = isHigh ? head : head & 0x7F
        let isError = !isHigh && head & errorFlag != 0
        let payload = Array(bytes[1..<(bytes.count - 1)])
        let valid = checksum(bytes.dropLast()) == bytes[bytes.count - 1]
        return (.command(cmd: cmd, isError: isError, payload: payload), valid)
    }
}

/// Opcodes this app sends or listens for.
enum RingOp {
    // Command channel
    static let setTime: UInt8 = 0x01
    static let camera: UInt8 = 0x02
    static let battery: UInt8 = 0x03
    static let wearHand: UInt8 = 0x05
    static let dnd: UInt8 = 0x06
    static let powerOff: UInt8 = 0x08
    static let profile: UInt8 = 0x0A
    static let bloodPressureHistory: UInt8 = 0x14
    static let heartRateHistory: UInt8 = 0x15
    static let heartRateMonitor: UInt8 = 0x16
    static let temperatureUnit: UInt8 = 0x19
    /// Turns the ring's input reporting on; it then sends `musicCommand` for every tap and swipe.
    static let musicSwitch: UInt8 = 0x1C
    static let musicCommand: UInt8 = 0x1D
    static let heartRateKeepAlive: UInt8 = 0x1E
    static let goals: UInt8 = 0x21
    static let findPhone: UInt8 = 0x22
    static let sedentaryWrite: UInt8 = 0x25
    static let sedentaryRead: UInt8 = 0x26
    static let spo2Monitor: UInt8 = 0x2C
    static let packageLength: UInt8 = 0x2F
    static let stressMonitor: UInt8 = 0x36
    static let stressHistory: UInt8 = 0x37
    static let hrvMonitor: UInt8 = 0x38
    static let hrvHistory: UInt8 = 0x39
    static let temperatureMonitor: UInt8 = 0x3A
    static let touch: UInt8 = 0x3B
    static let deviceSupport: UInt8 = 0x3C
    static let stepDetail: UInt8 = 0x43
    static let legacySleep: UInt8 = 0x44
    static let todayActivity: UInt8 = 0x48
    static let findRing: UInt8 = 0x50
    static let measure: UInt8 = 0x69
    static let stopMeasure: UInt8 = 0x6A
    static let ecgData: UInt8 = 0x6D
    /// Raw optical-sensor samples, pushed while a reading runs. The ring has no
    /// accelerometer or gyroscope stream — motion only reaches the phone as steps and sleep.
    static let ppgData: UInt8 = 0x6E
    static let deviceEvent: UInt8 = 0x73
    static let sportEvent: UInt8 = 0x78
    static let phoneStillTime: UInt8 = 0x7E
    static let calibration: UInt8 = 0xA1
    static let factoryReset: UInt8 = 0xFF

    /// Real opcodes at or above 0x80 — not an error flag on a low opcode.
    static let highOpcodes: Set<UInt8> = [0x93, calibration, 0xC9, 0xCA, factoryReset]

    // Large-data channel
    static let bigSleep: UInt8 = 0x27
    static let bigManualHeartRate: UInt8 = 0x28
    static let bigSpO2: UInt8 = 0x2A
    static let bigNaps: UInt8 = 0x3E
    static let bigBloodSugar: UInt8 = 0x47
    static let bigManualSpO2: UInt8 = 0x49
    static let bigIntervalSpO2: UInt8 = 0x5F
    static let bigIntervalHeartRate: UInt8 = 0x75
    static let bigIntervalTemperature: UInt8 = 0x77
}

enum RingChannel: String, Codable {
    case command, bigData
}

/// One decoded notification from either channel.
enum RingInbound: Equatable {
    /// `payload` is frame bytes 1…14 (checksum dropped).
    case command(cmd: UInt8, isError: Bool, payload: [UInt8])
    /// `payload` follows the 6-byte header, so SDK offset `data[6 + n]` is `payload[n]`.
    case bigData(cmd: UInt8, payload: [UInt8])

    var channel: RingChannel {
        if case .command = self { return .command }
        return .bigData
    }

    var cmd: UInt8 {
        switch self {
        case .command(let cmd, _, _), .bigData(let cmd, _): return cmd
        }
    }

    var payload: [UInt8] {
        switch self {
        case .command(_, _, let payload), .bigData(_, let payload): return payload
        }
    }

    var isError: Bool {
        if case .command(_, let isError, _) = self { return isError }
        return false
    }
}

/// Rebuilds large-data frames from notifications, which arrive in MTU-sized pieces.
struct RingBigDataAssembler {
    private var buffer: [UInt8] = []
    private var lastAppend = Date.distantPast
    /// A header claiming more than this is noise we resynchronised onto, not a frame.
    private static let maximumPayload = 32_768

    mutating func reset() {
        buffer.removeAll()
    }

    /// Feeds one notification and returns every frame it completes. A partial frame left
    /// over from an interrupted transfer is dropped when a new frame starts seconds later.
    mutating func append(_ chunk: Data, now: Date = Date()) -> [(inbound: RingInbound, crcValid: Bool)] {
        let bytes = [UInt8](chunk)
        if !buffer.isEmpty, bytes.first == RingProtocol.bigDataMagic, now.timeIntervalSince(lastAppend) > 3 {
            buffer.removeAll()
        }
        lastAppend = now
        buffer += bytes

        var out: [(inbound: RingInbound, crcValid: Bool)] = []
        while true {
            guard let start = buffer.firstIndex(of: RingProtocol.bigDataMagic) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= RingProtocol.bigDataHeaderLength else { break }
            let length = Int(buffer[2]) | Int(buffer[3]) << 8
            guard length <= Self.maximumPayload else {
                buffer.removeFirst()
                continue
            }
            let total = RingProtocol.bigDataHeaderLength + length
            guard buffer.count >= total else { break }
            let payload = Array(buffer[RingProtocol.bigDataHeaderLength..<total])
            let crc = UInt16(buffer[4]) | UInt16(buffer[5]) << 8
            let valid = payload.isEmpty ? crc == 0xFFFF : RingProtocol.crc16(payload) == crc
            out.append((.bigData(cmd: buffer[1], payload: payload), valid))
            buffer.removeFirst(total)
        }
        return out
    }
}

/// One outbound request on either channel.
struct RingRequest: Equatable {
    let channel: RingChannel
    let cmd: UInt8
    let payload: [UInt8]

    var bytes: Data {
        channel == .command ? RingProtocol.frame(cmd, payload) : RingProtocol.bigDataFrame(cmd, payload)
    }

    static func command(_ cmd: UInt8, _ payload: [UInt8] = []) -> RingRequest {
        RingRequest(channel: .command, cmd: cmd, payload: payload)
    }

    static func bigData(_ cmd: UInt8, _ payload: [UInt8] = []) -> RingRequest {
        RingRequest(channel: .bigData, cmd: cmd, payload: payload)
    }
}

// MARK: - Builders

private func u16LE(_ value: Int) -> [UInt8] {
    let v = max(0, min(0xFFFF, value))
    return [UInt8(v & 0xFF), UInt8(v >> 8)]
}

private func u24LE(_ value: Int) -> [UInt8] {
    let v = max(0, min(0xFF_FFFF, value))
    return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v >> 16)]
}

private func byte(_ value: Int) -> UInt8 {
    UInt8(clamping: value)
}

extension RingRequest {
    /// Clock sync. Its reply is the first capability block. `language` 1 = English.
    static func setTime(_ date: Date, language: UInt8 = 1, calendar: Calendar = .current) -> RingRequest {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return .command(RingOp.setTime, [
            RingProtocol.bcd((c.year ?? 2000) % 100), RingProtocol.bcd(c.month ?? 1), RingProtocol.bcd(c.day ?? 1),
            RingProtocol.bcd(c.hour ?? 0), RingProtocol.bcd(c.minute ?? 0), RingProtocol.bcd(c.second ?? 0),
            language,
        ])
    }

    static let battery = RingRequest.command(RingOp.battery)
    static let deviceSupport = RingRequest.command(RingOp.deviceSupport)
    static let todayActivity = RingRequest.command(RingOp.todayActivity)
    static let bloodPressureHistory = RingRequest.command(RingOp.bloodPressureHistory, [0, 0, 0, 0, 0x00, 0x32])

    /// 15-minute step slots for one day (0 = today, up to 29).
    static func stepDetail(dayOffset: Int) -> RingRequest {
        .command(RingOp.stepDetail, [byte(dayOffset), 0x0F, 0x00, 0x5F, 0x01])
    }

    static func legacySleep(dayOffset: Int) -> RingRequest {
        .command(RingOp.legacySleep, [byte(dayOffset), 0x0F, 0x00, 0x5F])
    }

    /// Legacy 5-minute heart-rate array; `timestamp` is the day's local midnight in local seconds.
    static func heartRateHistory(timestamp: UInt32) -> RingRequest {
        .command(RingOp.heartRateHistory, [
            UInt8(timestamp & 0xFF), UInt8((timestamp >> 8) & 0xFF),
            UInt8((timestamp >> 16) & 0xFF), UInt8(timestamp >> 24),
        ])
    }

    static func hrvHistory(dayOffset: Int) -> RingRequest {
        .command(RingOp.hrvHistory, [byte(dayOffset)])
    }

    static func stressHistory(dayOffset: Int) -> RingRequest {
        .command(RingOp.stressHistory, [byte(dayOffset)])
    }

    // Settings

    static let readHeartRateMonitor = RingRequest.command(RingOp.heartRateMonitor, [1])
    static func writeHeartRateMonitor(_ m: RingHeartRateMonitor) -> RingRequest {
        .command(RingOp.heartRateMonitor, [
            2, m.enabled ? 1 : 2, byte(m.intervalMinutes), byte(m.start),
            byte(m.lowWarning), byte(m.highWarning), byte(m.mainSwitch),
        ])
    }

    static let readSpO2Monitor = RingRequest.command(RingOp.spo2Monitor, [1])
    static func writeSpO2Monitor(enabled: Bool) -> RingRequest {
        .command(RingOp.spo2Monitor, [2, enabled ? 1 : 0])
    }

    static let readStressMonitor = RingRequest.command(RingOp.stressMonitor, [1])
    static func writeStressMonitor(enabled: Bool) -> RingRequest {
        .command(RingOp.stressMonitor, [2, enabled ? 1 : 0])
    }

    static let readHRVMonitor = RingRequest.command(RingOp.hrvMonitor, [1, 0, 0, 0, 0, 0, 0])
    /// 60 minutes travels as `0x60`; other intervals as plain minutes.
    static func writeHRVMonitor(enabled: Bool, intervalMinutes: Int) -> RingRequest {
        let code: UInt8 = intervalMinutes == 60 ? 0x60 : byte(intervalMinutes)
        return .command(RingOp.hrvMonitor, [2, enabled ? 1 : 0, 0x0A, code, 0, 0, 0])
    }

    static let readTemperatureMonitor = RingRequest.command(RingOp.temperatureMonitor, [3, 1])
    static func writeTemperatureMonitor(_ t: RingTemperatureMonitor) -> RingRequest {
        let custom = Int((t.customAlertCelsius * 10).rounded()) - 200
        return .command(RingOp.temperatureMonitor, [
            3, 2, t.enabled ? 1 : 0, byte(t.intervalMinutes), byte(t.start),
            byte(t.remindIntervalMinutes), byte(t.alertFlags), byte(custom),
        ])
    }

    static let readTouch = RingRequest.command(RingOp.touch, [1, 0])
    static let readGesture = RingRequest.command(RingOp.touch, [1, 1])
    static func writeTouch(appType: UInt8, sleepTime: Int) -> RingRequest {
        .command(RingOp.touch, [2, 0, appType, byte(sleepTime)])
    }
    static func writeGesture(appType: UInt8, strength: Int) -> RingRequest {
        .command(RingOp.touch, [2, 1, appType, byte(strength)])
    }

    static let readDND = RingRequest.command(RingOp.dnd, [1])
    static func writeDND(_ d: RingDND) -> RingRequest {
        .command(RingOp.dnd, [
            2, d.enabled ? 1 : 2, byte(d.startHour), byte(d.startMinute), byte(d.endHour), byte(d.endMinute),
        ])
    }

    static let readTemperatureUnit = RingRequest.command(RingOp.temperatureUnit, [1])
    static func writeTemperatureUnit(celsius: Bool) -> RingRequest {
        .command(RingOp.temperatureUnit, [2, 1, celsius ? 1 : 2])
    }

    static let readGoals = RingRequest.command(RingOp.goals, [1])
    /// Calories in the ring's small-calorie unit (kcal × 1000), distance in metres.
    static func writeGoals(_ g: RingGoals) -> RingRequest {
        .command(RingOp.goals, [2] + u24LE(g.steps) + u24LE(g.calories) + u24LE(g.distanceMeters)
            + u16LE(g.sportMinutes) + u16LE(g.sleepMinutes))
    }

    static let readProfile = RingRequest.command(RingOp.profile, [1])
    static func writeProfile(_ p: RingProfile) -> RingRequest {
        .command(RingOp.profile, [
            2, p.use24Hour ? 0 : 1, p.metric ? 0 : 1, byte(p.sex), byte(p.age), byte(p.heightCm), byte(p.weightKg),
            byte(p.systolic), byte(p.diastolic), byte(p.heartRateWarning), byte(p.open),
        ])
    }

    static let readWearHand = RingRequest.command(RingOp.wearHand, [3])
    static let readSedentary = RingRequest.command(RingOp.sedentaryRead)
    static func writeSedentary(_ s: RingSedentary) -> RingRequest {
        .command(RingOp.sedentaryWrite, [
            RingProtocol.bcd(s.startHour), RingProtocol.bcd(s.startMinute),
            RingProtocol.bcd(s.endHour), RingProtocol.bcd(s.endMinute),
            byte(s.weekMask), byte(s.cycleMinutes),
        ])
    }

    // Actions

    /// Ask the ring to report taps and swipes to the phone (its "music control" channel).
    static func inputReporting(_ on: Bool) -> RingRequest {
        .command(RingOp.musicSwitch, [2, on ? 1 : 2])
    }

    static let findRing = RingRequest.command(RingOp.findRing, [0x55, 0xAA])
    static let heartRateKeepAlive = RingRequest.command(RingOp.heartRateKeepAlive, [3])
    static let powerOff = RingRequest.command(RingOp.powerOff, [1])
    static let factoryReset = RingRequest.command(RingOp.factoryReset, [0x66, 0x66])

    /// On-demand measurement. The second byte is 0 for heart rate and blood pressure and
    /// `0x25` for everything else, as QRing sends it.
    static func startMeasurement(_ type: RingMeasurementType) -> RingRequest {
        .command(RingOp.measure, [type.rawValue, type.rawValue < 3 ? 0x00 : 0x25])
    }

    static func stopMeasurement(_ type: RingMeasurementType, value: Int = 0, extra: Int = 0) -> RingRequest {
        .command(RingOp.stopMeasure, [type.rawValue, byte(value), byte(extra)])
    }

    static func phoneStillTime(inUse: Bool, counter: Int) -> RingRequest {
        .command(RingOp.phoneStillTime, [2, inUse ? 1 : 0] + u16LE(counter & 0xFFFF))
    }

    /// Wearing calibration: `6` starts it, `2` cancels.
    static func calibration(mode: UInt8) -> RingRequest {
        .command(RingOp.calibration, [mode])
    }

    // Large data

    static func bigSleep(all: Bool) -> RingRequest {
        .bigData(RingOp.bigSleep, [all ? 0xFF : 0x00, 0x01])
    }

    static func bigManualHeartRate(all: Bool) -> RingRequest {
        .bigData(RingOp.bigManualHeartRate, [all ? 0xFF : 0x00])
    }

    static func bigManualSpO2(all: Bool) -> RingRequest {
        .bigData(RingOp.bigManualSpO2, [all ? 0xFF : 0x00])
    }

    static let bigSpO2 = RingRequest.bigData(RingOp.bigSpO2, [0])
    static let bigBloodSugar = RingRequest.bigData(RingOp.bigBloodSugar, [0])

    static func bigIntervalHeartRate(dayOffset: Int, packet: Int) -> RingRequest {
        .bigData(RingOp.bigIntervalHeartRate, [byte(dayOffset), byte(packet)])
    }

    static func bigIntervalSpO2(dayOffset: Int, packet: Int) -> RingRequest {
        .bigData(RingOp.bigIntervalSpO2, [byte(dayOffset), byte(packet)])
    }

    static func bigIntervalTemperature(dayOffset: Int, packet: Int) -> RingRequest {
        .bigData(RingOp.bigIntervalTemperature, [byte(dayOffset), byte(packet)])
    }
}
