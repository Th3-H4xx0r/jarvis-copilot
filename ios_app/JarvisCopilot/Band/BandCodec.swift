import Foundation

/// Every request the app writes, byte for byte what the vendor SDK writes for the same call.
/// Each is one 20-byte frame (zero padded) unless noted; settings and notification switches that
/// span two of the band's packages also have a `…Frames` form that returns both.
enum BandRequest {
    // MARK: Framing

    /// `bytes` zero-padded to a 20-byte frame. Longer commands (text alarms) are returned whole.
    static func frame(_ bytes: [UInt8]) -> [UInt8] {
        bytes.count >= BandProtocol.frameLength
            ? bytes : bytes + [UInt8](repeating: 0, count: BandProtocol.frameLength - bytes.count)
    }

    private static func byte(_ value: Int) -> UInt8 { UInt8(max(0, min(255, value))) }

    private static func be16(_ value: Int) -> [UInt8] {
        let v = max(0, min(0xFFFF, value))
        return [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    private static func le16(_ value: Int) -> [UInt8] {
        let v = max(0, min(0xFFFF, value))
        return [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    // MARK: Session

    /// `A1`: the PIN check, carrying the phone's clock (year big-endian) and its UTC offset in
    /// quarter hours (signed). Byte 12 is 01 — the SDK's 00 is only for an iOS pairing flow.
    static func password(at date: Date, calendar: Calendar) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let quarters = calendar.timeZone.secondsFromGMT(for: date) / 900
        return frame([BandOp.password, 0x00, 0x00, 0x00] + be16(c.year ?? 2000)
            + [byte(c.month ?? 1), byte(c.day ?? 1), byte(c.hour ?? 0), byte(c.minute ?? 0), byte(c.second ?? 0),
               0x00, 0x01, UInt8(bitPattern: Int8(clamping: quarters))])
    }

    static func battery() -> [UInt8] { frame([BandOp.battery, 0x00]) }
    static func productInfo() -> [UInt8] { frame([BandOp.product, 0x00]) }

    /// `A5`: wall-clock time in `calendar`'s zone, then 2 for a 24-hour clock or 1 for 12-hour.
    static func syncTime(_ date: Date, hour24: Bool, calendar: Calendar) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return frame([BandOp.syncTime] + be16(c.year ?? 2000)
            + [byte(c.month ?? 1), byte(c.day ?? 1), byte(c.hour ?? 0), byte(c.minute ?? 0), byte(c.second ?? 0),
               hour24 ? 2 : 1, 0x00])
    }

    static func readTime() -> [UInt8] { frame([BandOp.readTime, 0x00]) }

    /// `A3`: height, weight, age, sex (1 male), step goal and sleep goal (minutes), goals big-endian.
    static func profile(heightCm: Int, weightKg: Int, age: Int, male: Bool, stepGoal: Int, sleepGoalMinutes: Int) -> [UInt8] {
        frame([BandOp.profile, byte(heightCm), byte(weightKg), byte(age), male ? 1 : 0]
            + be16(stepGoal) + be16(sleepGoalMinutes))
    }

    // MARK: Settings

    static func readSettings() -> [UInt8] { frame([BandOp.settings, 0x02]) }

    /// Package 0 of the settings (units, clock, auto heart rate / BP / HRV, skin tone…) as a write.
    static func writeSettings(_ s: BandSettings) -> [UInt8] { asWrite(s.page1) }

    /// Package 1 (temperature unit, auto temperature / glucose / stress), when the band has it.
    static func writeSettingsPage2(_ s: BandSettings) -> [UInt8]? { s.page2.map(asWrite) }

    /// Both packages, as the SDK's unit setting sends them.
    static func writeSettingsFrames(_ s: BandSettings) -> [[UInt8]] {
        [writeSettings(s)] + (writeSettingsPage2(s).map { [$0] } ?? [])
    }

    private static func asWrite(_ page: [UInt8]) -> [UInt8] {
        var f = frame(page)
        f[0] = BandOp.settings
        f[1] = 0x01
        return f
    }

    /// Skin tone 1 (lightest) … 6 written over `settings` (byte 11; this band's skin-colour type 2).
    static func skinTone(_ level: Int, settings: BandSettings) -> [UInt8] {
        var s = settings
        s.skinTone = (1...6).contains(level) ? level : 0
        return writeSettings(s)
    }

    /// Over the E910's reported defaults — prefer `skinTone(_:settings:)` with the band's own read.
    static func skinTone(_ level: Int) -> [UInt8] { skinTone(level, settings: .e910Default) }

    // MARK: History

    /// `DF <package+1 LE> <day>`: day 0 today … 2 two days ago; package 1 reads from the start.
    static func readDaily(day: Int, package: Int) -> [UInt8] {
        frame([BandOp.daily] + le16(package + 1) + [byte(day), 0x00])
    }

    /// `E0 <day>`: precise sleep for day 0 today … 2.
    static func readSleep(day: Int) -> [UInt8] { frame([BandOp.sleep, byte(day)]) }

    /// `D3 01`: the CRCs of the band's stored workouts (three slots).
    static func readSportCRCs() -> [UInt8] { frame([BandOp.sportCRC, 0x01]) }

    /// `D4 <module-1>`: one stored workout, module 1…3.
    static func readSportRecords(module: Int = 1) -> [UInt8] { frame([BandOp.sportRecords, byte(module - 1)]) }

    /// `D8 <day>`: running steps, distance and energy (day 0 today … 4).
    static func readSteps(day: Int = 0) -> [UInt8] { frame([BandOp.steps, byte(day)]) }

    /// `A8 <day>`: the step count alone.
    static func readStepCount(day: Int = 0) -> [UInt8] { frame([BandOp.stepCount, byte(day)]) }

    // MARK: Measurements

    static func measure(_ type: BandMeasure, on: Bool) -> [UInt8] {
        switch type {
        case .heartRate: return frame([BandOp.heartRate, on ? 1 : 0])
        case .bloodPressure: return frame([BandOp.bloodPressure, on ? 1 : 0, 0x00])
        case .bloodOxygen: return frame([BandOp.bloodOxygen, on ? 1 : 2, 0x00])
        case .temperature: return frame([BandOp.temperature, 0x01, on ? 1 : 2])
        case .stress: return frame([BandOp.glucoseStress, 0x06, on ? 1 : 2])
        case .bloodGlucose: return frame([BandOp.glucoseStress, 0x01, on ? 1 : 2, 0x00])
        case .bloodComponent: return frame([BandOp.bloodComponent, 0x01, on ? 1 : 2, 0x00])
        case .bodyComposition: return frame([BandOp.ecgBody, 0x04, on ? 1 : 2])
        case .ecg: return frame([BandOp.ecgBody, 0x01, on ? 1 : 2, 0x01, 0x00])
        }
    }

    // MARK: Sport

    /// `DA 01 <mode LE> <op>`; mode 0 is a sport run by the app.
    static func sport(_ op: BandSportOp, mode: Int = 0) -> [UInt8] {
        frame([BandOp.sportControl, 0x01] + le16(mode) + [op.rawValue])
    }

    /// `DA 02 <mode LE> 02`: the live status (time, distance, heart rate, energy, pace) — the SDK
    /// polls it every 3 s while a sport runs.
    static func sportStatus(mode: Int = 0) -> [UInt8] {
        frame([BandOp.sportControl, 0x02] + le16(mode) + [0x02])
    }

    // MARK: Controls

    /// `B5 0A` starts the band buzzing, `B5 0B` stops it.
    static func find(on: Bool) -> [UInt8] { frame([BandOp.find, on ? 0x0A : 0x0B]) }

    /// `B6 01` opens the band's camera-remote screen, `B6 00` closes it.
    static func camera(_ on: Bool) -> [UInt8] { frame([BandOp.camera, on ? 1 : 0]) }

    /// `F1 80`: factory reset, which wipes the band's stored data. Only from a confirmed user action.
    static func clearData() -> [UInt8] { frame([BandOp.factoryReset, 0x80]) }

    /// `FF 55 01 73 40`: soft restart.
    static func reboot() -> [UInt8] { frame([BandOp.reboot, 0x55, 0x01, 0x73, 0x40]) }

    // MARK: Alarms

    static func readAlarms() -> [UInt8] { frame([BandOp.alarms, 0x03]) }

    /// `B9 02 01 01` + the alarm record. 22 bytes plus the label — longer than one frame.
    static func setAlarm(_ a: BandAlarm) -> [UInt8] { alarmCommand(a, op: 0x02, flag: 0x30) }

    /// `B9 01 01 01` + the same record (with 00 where a set has 30).
    static func deleteAlarm(_ a: BandAlarm) -> [UInt8] { alarmCommand(a, op: 0x01, flag: 0x00) }

    /// `A0 02 <crc LE> A1 <len> B1 08 id on days hh mm <flag> 00 00 B2 <n> label`. The SDK takes
    /// its CRC over the record as a hex string, each character as its digit value (a–f count 0)
    /// and the day mask unpadded — reproduced exactly, since the band checks it.
    private static func alarmCommand(_ a: BandAlarm, op: UInt8, flag: UInt8) -> [UInt8] {
        let label = Array(a.label.utf8.prefix(255))
        let mask = BandWeekday.mask(a.days)
        let record: [UInt8] = [0xB1, 0x08, byte(a.id), a.enabled ? 1 : 0, mask, byte(a.hour), byte(a.minute), flag, 0x00, 0x00,
                               0xB2, UInt8(label.count)] + label
        let block: [UInt8] = [0xA1, byte(record.count)] + record
        // The SDK's string: every byte as two hex digits except the day mask, which it leaves unpadded.
        var text = ""
        for (i, b) in block.enumerated() { text += i == 6 ? String(b, radix: 16) : String(format: "%02x", b) }
        let crc = digitCRC16(text)
        return [BandOp.alarms, op, 0x01, 0x01, 0xA0, 0x02, UInt8(crc & 0xFF), UInt8(crc >> 8)] + block
    }

    /// CRC-16/MODBUS (init FFFF, reflected 0xA001) over `text`'s characters coerced the way
    /// JavaScript's `255 & "c"` does: a digit is its value, anything else 0.
    static func digitCRC16(_ text: String) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for ch in text {
            let v = UInt16(ch.wholeNumberValue ?? 0) & 0xFF
            crc = (crc >> 8) ^ crcTable[Int((crc ^ v) & 0xFF)]
        }
        return crc
    }

    private static let crcTable: [UInt16] = (0..<256).map { i in
        var c = UInt16(i)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
        return c
    }

    // MARK: Reminders

    /// `E1 sh sm eh em interval on`.
    static func sedentary(_ s: BandSedentary) -> [UInt8] {
        frame([BandOp.sedentary, byte(s.startHour), byte(s.startMinute), byte(s.endHour), byte(s.endMinute),
               byte(s.intervalMinutes), s.enabled ? 1 : 0])
    }

    static func readSedentary() -> [UInt8] { frame([BandOp.sedentary, 0, 0, 0, 0, 0, 0x02]) }

    /// `AC max min 01|00`.
    static func heartRateAlarm(enabled: Bool, high: Int, low: Int) -> [UInt8] {
        frame([BandOp.heartRateAlarm, byte(high), byte(low), enabled ? 1 : 0])
    }

    static func readHeartRateAlarm() -> [UInt8] { frame([BandOp.heartRateAlarm, 0, 0, 0x02]) }

    /// `AA on sh sm eh em level`: raise-to-wake within a daily window, sensitivity 1…10. The
    /// window and level defaults are the app's choice; read the band's with `readRaiseToWake`.
    static func raiseToWake(_ on: Bool, start: (h: Int, m: Int) = (8, 0), end: (h: Int, m: Int) = (22, 0),
                            level: Int = 5) -> [UInt8] {
        frame([BandOp.raiseToWake, on ? 1 : 0, byte(start.h), byte(start.m), byte(end.h), byte(end.m),
               byte(max(1, min(10, level)))])
    }

    static func readRaiseToWake() -> [UInt8] { frame([BandOp.raiseToWake, 0x02]) }

    /// `B3 00 00 sh sm eh em on`: the automatic SpO₂ window.
    static func bloodOxygenAuto(enabled: Bool, start: (h: Int, m: Int), end: (h: Int, m: Int)) -> [UInt8] {
        frame([BandOp.bloodOxygenAuto, 0x00, 0x00, byte(start.h), byte(start.m), byte(end.h), byte(end.m),
               enabled ? 1 : 0])
    }

    static func readBloodOxygenAuto() -> [UInt8] { frame([BandOp.bloodOxygenAuto, 0x02]) }

    // MARK: Phone alerts

    /// Package 1 of the notification switches (calls … WeChat Work, then "others").
    static func alerts(_ a: BandAlertSwitches) -> [UInt8] { alertsFrames(a)[0] }

    /// Both packages, as the SDK sends them: `AD 01` + 17 app states + others (01 on / 02 off),
    /// then `AD 01` + the six newer apps, ending `…00 10`.
    static func alertsFrames(_ a: BandAlertSwitches) -> [[UInt8]] {
        let first = BandAlertSwitches.apps1.dropLast().map { a.states[$0] ?? 0 }
        let others: UInt8 = a.states["others"] == 1 ? 1 : 2
        var second = [BandOp.alerts, 0x01] + BandAlertSwitches.apps2.map { a.states[$0] ?? 0 }
        second = frame(second)
        second[19] = 0x10
        return [[BandOp.alerts, 0x01] + first + [others], second]
    }

    /// `AD 02`. Not in the SDK — the band pushes both packages during the handshake, each with
    /// byte 1 = 02, the read form its other settings use — so this read is unconfirmed.
    static func readAlerts() -> [UInt8] { frame([BandOp.alerts, 0x02]) }
}
