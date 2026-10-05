import Foundation

// The band's stored history: 5-minute daily records (`DF`), precise sleep (`E0`) and the
// workouts it recorded itself (`D4`). Each decoder takes every frame of one read, in order.

/// One 5-minute daily record.
struct BandDailyRecord: Equatable, Codable {
    /// The slot's start, local time.
    var date: Date
    var minuteOfDay: Int
    /// Minute of day / 5, as the SDK numbers records; nil off the 5-minute grid.
    var slot: Int?
    var steps: Int
    /// The band's "amount of exercise" (movement) count.
    var exercise: Int
    var distanceMeters: Int
    /// As the band sends it (assumed small calories, like its workouts).
    var calories: Int
    var worn: Bool?
    /// One per minute of the slot, 0 = no reading. The band's pulse values, or its heart-rate
    /// values when every pulse value is 0 — the SDK's rule.
    var heartRates: [Int] = []
    var respiration: [Int] = []
    /// One per minute, from the record's RR values by the SDK's formula.
    var hrv: [Int] = []
    var systolic: Int?
    var diastolic: Int?
    var spo2: [Int] = []
    var stress: [Int] = []
    /// MET as sent (scale unknown).
    var met: [Int] = []
    var sleepStates: [Int] = []
    /// mmol/L.
    var bloodGlucose: Double?
    var bloodComponent: BandBloodComponent?
    var temperatureC: Double?
    var surfaceTemperatureC: Double?
}

/// One precise-sleep segment (a night can have several when the wearer got up).
struct BandSleep: Equatable, Codable {
    var start: Date
    var end: Date
    /// One point per minute: 0 deep, 1 light, 2 REM, 3 insomnia, 4 awake.
    var curve: [Int]
    /// 2 = the 2-bit "ZhongKe" curve; anything else the 3-bit one.
    var sleepType: Int
    /// 0…4 (the HBand app shows 1–5 stars).
    var quality: Int
    var nightScore: Int
    var deepScore: Int
    var efficiencyScore: Int
    var fallAsleepScore: Int
    var durationScore: Int
    var deepMinutes: Int
    var lightMinutes: Int
    var otherMinutes: Int
    var totalMinutes: Int
    var firstDeepMinutes: Int
    /// Time up during the night.
    var nightWakeMinutes: Int
    var nightDeepMean: Int
    var insomniaScore: Int
    var insomniaCount: Int

    /// Awake runs between the first and last asleep minute.
    var wakeCount: Int {
        guard let first = curve.firstIndex(where: { $0 != 4 && $0 != 3 }),
              let last = curve.lastIndex(where: { $0 != 4 && $0 != 3 }), first < last else { return 0 }
        var count = 0, awake = false
        for v in curve[first...last] {
            let isAwake = v == 4 || v == 3
            if isAwake && !awake { count += 1 }
            awake = isAwake
        }
        return count
    }
}

struct BandSportMinute: Equatable, Codable {
    var heartRate: Int
    var movement: Int
    var steps: Int
    var calories: Int
    var distanceMeters: Int
    var paused: Bool
}

/// A workout the band stored (`D4`), with its minute-by-minute data.
struct BandSportRecord: Equatable, Codable {
    /// Storage slot 1…3.
    var module: Int
    var start: Date?
    var end: Date?
    /// The band's sport type (1 outdoor run, 2 outdoor walk, … as the HBand SDK numbers them).
    var sportType: Int
    var steps: Int
    var distanceMeters: Int
    /// Small calories.
    var calories: Int
    var movement: Int
    var recordCount: Int
    var pauseCount: Int
    var pauseSeconds: Int
    var crc: Int
    var minutes: [BandSportMinute]

    var json: [String: Any] {
        let iso = ISO8601DateFormatter()
        var out: [String: Any] = ["module": module, "sport_type": sportType, "steps": steps, "distance_m": distanceMeters,
                                  "kcal": Double(calories) / 1000, "pause_count": pauseCount, "pause_s": pauseSeconds,
                                  "crc": crc, "minutes": minutes.count]
        if let start { out["start"] = iso.string(from: start) }
        if let end { out["end"] = iso.string(from: end) }
        if let start, let end { out["duration_s"] = max(0, Int(end.timeIntervalSince(start))) }
        let hr = minutes.map(\.heartRate).filter { (30...250).contains($0) }
        if !hr.isEmpty {
            out["heart_rate_avg"] = hr.reduce(0, +) / hr.count
            out["heart_rate_max"] = hr.max()
        }
        return out
    }
}

extension BandDecode {
    // MARK: Daily records

    /// The records of one `DF` read. Frames: `DF <packet LE> <sub>` + 16 bytes. Sub 0 opens a
    /// record and carries total packets (LE, bytes 4–5), the last sub index (byte 6) and the
    /// frame length (byte 13); the record is bytes 4… of sub 0 through sub `last`, a run of
    /// `tag len value` the SDK walks, skipping tags it does not know. `DF FF FF` ends the read.
    ///
    /// One deliberate difference from the SDK: a new sub 0 starts a fresh record, so a lost
    /// frame drops that record instead of gluing it onto the next.
    static func daily(_ frames: [[UInt8]], day: Int, calendar: Calendar, now: Date) -> [BandDailyRecord] {
        var records: [[UInt8]] = []
        var pending: [UInt8] = []
        var last = 0, length = 0
        for f in frames where f.count >= 4 && f[0] == BandOp.daily {
            if f[1] == 0xFF && f[2] == 0xFF { break }
            if f[3] == 0, f.count > 13 {
                last = Int(f[6])
                length = Int(f[13])
                pending = []
            }
            guard length == f.count else { continue }
            let body = Array(f[4...])
            if last == 1 { records.append(body); continue }   // the SDK: every frame a whole record
            pending += body
            if Int(f[3]) == last {
                records.append(pending)
                pending = []
            }
        }
        return records.compactMap { dailyRecord($0, calendar: calendar, now: now) }
    }

    /// `tag len value` runs; a later tag replaces an earlier one, as in the SDK.
    static func tlvs(_ p: [UInt8]) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        var i = 0
        while i < p.count - 1 {
            let tag = p[i], n = Int(p[i + 1])
            guard i + 2 + n <= p.count else { break }
            out[tag] = Array(p[(i + 2)..<(i + 2 + n)])
            i += 2 + n
        }
        return out
    }

    private static func dailyRecord(_ p: [UInt8], calendar: Calendar, now: Date) -> BandDailyRecord? {
        let t = tlvs(p)
        // B1: month, day, hour, minute — no year: this year, or last year for December read in January.
        guard let d = t[0xB1], d.count >= 4, (1...12).contains(d[0]), (1...31).contains(d[1]), d[2] < 24, d[3] < 60 else { return nil }
        let today = calendar.dateComponents([.year, .month], from: now)
        var year = today.year ?? 2000
        if today.month == 1 && d[0] == 12 { year -= 1 }
        guard let date = calendar.date(from: DateComponents(year: year, month: Int(d[0]), day: Int(d[1]),
                                                            hour: Int(d[2]), minute: Int(d[3]))) else { return nil }
        let minute = Int(d[2]) * 60 + Int(d[3])
        var r = BandDailyRecord(date: date, minuteOfDay: minute, slot: minute % 5 == 0 ? minute / 5 : nil,
                                steps: 0, exercise: 0, distanceMeters: 0, calories: 0)
        if let s = t[0xB2], s.count >= 10 {
            r.steps = be16(s, 0)
            r.exercise = be16(s, 2)
            r.distanceMeters = be16(s, 4)
            r.calories = be16(s, 6)
            r.worn = s[9] != 0
        }
        let pulse = (t[0xB4] ?? []).map(Int.init), heart = (t[0xB5] ?? []).map(Int.init)
        r.heartRates = pulse.isEmpty || pulse.allSatisfy({ $0 == 0 }) ? heart : pulse
        r.sleepStates = (t[0xB3] ?? []).map(Int.init)
        r.respiration = (t[0xB6] ?? []).map(Int.init)
        if let rr = t[0xB7], rr.count > 1 {
            let values = rr.dropFirst().map(Int.init)
            r.hrv = (0..<5).map { hrvMinute($0, values) }
        }
        if let bp = t[0xB8], bp.count >= 2, bp[0] > 0, bp[1] > 0 {
            r.systolic = Int(bp[0])
            r.diastolic = Int(bp[1])
        }
        if let o = t[0xB9] { r.spo2 = o.prefix(5).map(Int.init) }
        if let g = t[0xBE], g.count >= 2 { r.bloodGlucose = Double(le16(g, 0)) / 100 }
        r.met = (t[0xBF] ?? []).map(Int.init)
        r.stress = (t[0xC1] ?? []).map(Int.init)
        if let c = t[0xC2], c.count >= 10 {
            r.bloodComponent = BandBloodComponent(uricAcid: Double(le16(c, 8)) / 10, cholesterol: Double(le16(c, 0)) / 100,
                                                  triglycerides: Double(le16(c, 2)) / 100, hdl: Double(le16(c, 4)) / 100,
                                                  ldl: Double(le16(c, 6)) / 100)
        }
        if let c = t[0xC3], c.count >= 4 {
            r.surfaceTemperatureC = Double(le16(c, 0)) / 10
            r.temperatureC = Double(le16(c, 2)) / 10
        }
        return r
    }

    /// The SDK's HRV for minute `m`: the mean absolute step between the minute's valid values
    /// (30…210), × 10, wrapped above 210.
    static func hrvMinute(_ m: Int, _ values: [Int]) -> Int {
        var sum = 0, count = 0, previous = -1
        for i in (10 * m)..<(10 * (m + 1)) where i < values.count {
            let v = values[i]
            guard (30...210).contains(v) else { continue }
            if previous != -1 { sum += abs(previous - v); count += 1 }
            previous = v
        }
        guard count > 0 else { return 0 }
        var hrv = Int((Double(sum * 10) / Double(count)).rounded())
        if hrv > 210 { hrv %= 210 }
        return hrv
    }

    // MARK: Precise sleep

    /// One `E0` read: bytes 4… of every frame joined until the frame whose byte 1 is 0 (byte 2
    /// 0 = no sleep). Each segment is an `A1 <len LE>` block of `A3` (times, scores, durations,
    /// curve type), `A4` (insomnia) and `A5 <points LE>` (the curve).
    static func sleep(_ frames: [[UInt8]], calendar: Calendar, now: Date = Date()) -> [BandSleep] {
        var joined: [UInt8] = []
        var out: [BandSleep] = []
        var sleepType = 1   // carried from block to block, as the SDK does
        for f in frames where f.count >= 4 && f[0] == BandOp.sleep {
            joined += f[4...]
            guard f[1] == 0 else { continue }
            defer { joined = [] }
            guard f[2] != 0 else { continue }
            for block in sleepBlocks(joined) {
                if let s = sleepSegment(block, sleepType: &sleepType, calendar: calendar, now: now) { out.append(s) }
            }
        }
        return out
    }

    private static func sleepBlocks(_ p: [UInt8]) -> [[UInt8]] {
        var blocks: [[UInt8]] = []
        var i = 0
        while i < p.count {
            if p[i] == 0xA1, i + 2 < p.count {
                let end = i + le16(p, i + 1)
                if end > p.count { break }
                if end >= i + 3 {
                    blocks.append(Array(p[i..<end]))
                    i = end
                    continue
                }
            }
            i += 1
        }
        return blocks
    }

    private static func sleepSegment(_ b: [UInt8], sleepType: inout Int, calendar: Calendar, now: Date) -> BandSleep? {
        var a3: [UInt8]?, a4: [UInt8]?, curve: [Int] = []
        var i = 0
        while i < b.count - 1 {
            let tag = b[i]
            var start = i + 2, n = Int(b[i + 1]), step = 0
            if tag == 0xA1 {
                start = i + 3; n = 0; step = 3
            } else if tag == 0xA5 {
                let points = le16(b, i + 1)
                n = sleepType == 2 ? (points + 3) / 4 : points
                start = i + 3; step = 3 + n
            } else {
                step = 2 + n
            }
            guard start + n <= b.count else { break }
            let v = Array(b[start..<(start + n)])
            switch tag {
            case 0xA3:
                a3 = v
                if let t = v.last { sleepType = Int(t) }
            case 0xA4: a4 = v
            case 0xA5:
                let total = a3.map { le16(Array($0.dropFirst(17)), 8) }
                curve = sleepType == 2 ? packedCurve(v, total: total) : wideCurve(v)
            default: break
            }
            i += step
        }
        guard let a = a3, a.count >= 18,
              let start = sleepDate(a, 0, calendar: calendar, now: now),
              var end = sleepDate(a, 4, calendar: calendar, now: now) else { return nil }
        if end < start, let next = calendar.date(byAdding: .year, value: 1, to: end) { end = next }
        let d = Array(a.dropFirst(17).dropLast())
        return BandSleep(start: start, end: end, curve: curve, sleepType: Int(a.last ?? 0), quality: at(a, 15),
                         nightScore: at(a, 9), deepScore: at(a, 10), efficiencyScore: at(a, 11), fallAsleepScore: at(a, 12),
                         durationScore: at(a, 13), deepMinutes: le16(d, 2), lightMinutes: le16(d, 4), otherMinutes: le16(d, 6),
                         totalMinutes: le16(d, 8), firstDeepMinutes: le16(d, 10), nightWakeMinutes: le16(d, 12),
                         nightDeepMean: le16(d, 14), insomniaScore: a4.map { at($0, 1) } ?? 0,
                         insomniaCount: a4.map { at($0, 2) } ?? 0)
    }

    /// Four 2-bit points per byte, high bits first; 3 (insomnia) reads as 4 (awake). The last
    /// byte drops the padding the total sleep time implies.
    private static func packedCurve(_ v: [UInt8], total: Int?) -> [Int] {
        var out: [Int] = []
        let pad = total.map { max(0, 4 * v.count - $0) } ?? 0
        for (i, byte) in v.enumerated() {
            let points = [Int(byte >> 6 & 3), Int(byte >> 4 & 3), Int(byte >> 2 & 3), Int(byte & 3)]
            let keep = i == v.count - 1 && pad > 0 && pad < 4 ? 4 - pad : 4
            out += points.prefix(keep).map { $0 == 3 ? 4 : $0 }
        }
        return out
    }

    /// Two bytes per point, the stage in the top three bits.
    private static func wideCurve(_ v: [UInt8]) -> [Int] {
        stride(from: 0, to: v.count - 1, by: 2).map { Int((UInt16(v[$0]) << 8 | UInt16(v[$0 + 1])) >> 13 & 7) }
    }

    /// Month, day, hour, minute at `i` — the latest year that is not more than a day ahead of now.
    private static func sleepDate(_ a: [UInt8], _ i: Int, calendar: Calendar, now: Date) -> Date? {
        guard i + 3 < a.count, (1...12).contains(a[i]), (1...31).contains(a[i + 1]), a[i + 2] < 24, a[i + 3] < 60 else { return nil }
        let year = calendar.component(.year, from: now)
        for y in [year, year - 1] {
            if let date = calendar.date(from: DateComponents(year: y, month: Int(a[i]), day: Int(a[i + 1]),
                                                             hour: Int(a[i + 2]), minute: Int(a[i + 3]))),
               date <= now.addingTimeInterval(86_400) {
                return date
            }
        }
        return nil
    }

    // MARK: Stored workouts

    /// One `D4` read: `D4 <packet LE> <total LE> <module>`; packets 1–3 carry a 42-byte header
    /// (bytes 6…19 each), every later packet one minute. Done when packet = total.
    static func sportRecords(_ frames: [[UInt8]], calendar: Calendar) -> [BandSportRecord] {
        var header: [UInt8] = []
        var head: BandSportRecord?
        var minutes: [BandSportMinute] = []
        var out: [BandSportRecord] = []
        for f in frames where f.count >= 16 && f[0] == BandOp.sportRecords {
            let packet = le16(f, 1), total = le16(f, 3)
            if packet <= 3 {
                if packet == 1 { header = []; minutes = []; head = nil }
                header += f[6..<min(20, f.count)]
                if packet == 3, header.count >= 39 { head = sportHeader(header, module: Int(f[5]) + 1, calendar: calendar) }
                continue
            }
            minutes.append(BandSportMinute(heartRate: Int(f[6]), movement: le16(f, 7), steps: le16(f, 9), calories: le16(f, 11),
                                           distanceMeters: le16(f, 13), paused: f[15] != 0))
            if packet == total, var record = head {
                record.minutes = minutes
                out.append(record)
                head = nil
                minutes = []
            }
        }
        return out
    }

    private static func sportHeader(_ h: [UInt8], module: Int, calendar: Calendar) -> BandSportRecord {
        func date(_ i: Int) -> Date? {
            calendar.date(from: DateComponents(year: le16(h, i), month: at(h, i + 2), day: at(h, i + 3),
                                               hour: at(h, i + 4), minute: at(h, i + 5), second: at(h, i + 6)))
        }
        return BandSportRecord(module: module, start: date(1), end: date(8), sportType: at(h, 38), steps: le32(h, 15),
                               distanceMeters: le32(h, 19), calories: le32(h, 23), movement: le32(h, 27),
                               recordCount: le16(h, 31), pauseCount: at(h, 33), pauseSeconds: le16(h, 34), crc: le16(h, 36),
                               minutes: [])
    }
}
