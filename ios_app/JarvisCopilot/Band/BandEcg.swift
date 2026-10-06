import Foundation

// The band's ECG report, as the official app shows one: the diagnosis the band computes (heart
// rate, breathing, HRV, QT, QRS, ST, SDNN, RMSSD, six risk scores, the arrhythmia findings), the
// per-second heart rate, and the waveform. Decoded the way the Android SDK does
// (`EcgDiagnosis`, built from the type-5 result parts, 14 bytes each from byte 6).

/// A finding the band's eight diagnosis bytes can carry, graded 0 (none) to 3.
struct BandEcgFinding: Codable, Equatable, Identifiable {
    var id: Int
    var grade: Int

    var name: String { Self.names[id] ?? "Finding \(id)" }
    var gradeWord: String { grade >= 3 ? "High" : grade == 2 ? "Moderate" : grade == 1 ? "Low" : "None" }

    /// The SDK's thirteen single-lead finding ids (`(byte + 1) × 10 + slot + 1`). Their names
    /// follow the WeChat SDK's ECG text list in order, grouped as the bytes group them (sinus,
    /// ventricular premature beats, tachycardia, flutter, ischemia/escape). Inferred: the
    /// vendor app holds the table.
    static let names: [Int: String] = [
        11: "Sinus tachycardia", 12: "Sinus bradycardia", 13: "Sinus arrhythmia", 14: "Sinus arrest",
        21: "Ventricular premature beats", 22: "Bigeminy", 23: "Trigeminy",
        33: "Paroxysmal ventricular tachycardia", 34: "Paroxysmal tachycardia",
        42: "Atrial flutter", 52: "Ventricular flutter",
        63: "Myocardial ischemia", 64: "Atrial escape beats",
    ]
}

/// What the band concluded from one ECG (all of `EcgDiagnosis`).
struct BandEcgDiagnosis: Codable, Equatable {
    var leadOffType: Int
    /// The eight diagnosis bytes, four 2-bit grades each.
    var diagnosisBytes: [Int]
    var heartRate: Int
    var respiratoryRate: Int
    var hrv: Int
    /// QT, as the band corrects it (the official app labels it QTc).
    var qtcMs: Int
    var arrhythmiaRisk: Int
    var stressIndex: Int
    var fatigueIndex: Int
    var myocarditisRisk: Int
    var coronaryRisk: Int
    var arteriosclerosisRisk: Int
    var qrsMs: Int
    /// QRS and ST amplitude in µV (the official app shows mV); signed.
    var qrsAmplitudeUv: Int
    var pwv: Int
    var stAmplitudeUv: Int
    var sdnnMs: Int
    var rmssdMs: Int

    /// The joined result parts: lead-off type, eight diagnosis bytes, HR, breathing, HRV, QT (LE),
    /// six risks, 32 risk bytes, then QRS time, QRS amplitude, PWV, ST (LE 16) and SDNN, RMSSD (LE 32).
    init?(_ data: [UInt8]) {
        guard data.count >= 20 else { return nil }
        func u8(_ i: Int) -> Int { i < data.count ? Int(data[i]) : 0 }
        func u16(_ i: Int) -> Int { u8(i) | u8(i + 1) << 8 }
        func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(i)))) }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        leadOffType = u8(0)
        diagnosisBytes = (1...8).map(u8)
        heartRate = u8(9)
        respiratoryRate = u8(10)
        hrv = u8(11)
        qtcMs = u16(12)
        arrhythmiaRisk = u8(14)
        stressIndex = u8(15)
        fatigueIndex = u8(16)
        myocarditisRisk = u8(17)
        coronaryRisk = u8(18)
        arteriosclerosisRisk = u8(19)
        qrsMs = u16(52)
        qrsAmplitudeUv = s16(54)
        pwv = u16(56)
        stAmplitudeUv = s16(58)
        sdnnMs = u32(60)
        rmssdMs = u32(64)
    }

    /// Every finding with a grade (the SDK's `vp_ab` reading of the diagnosis bytes).
    var findings: [BandEcgFinding] {
        var out: [BandEcgFinding] = []
        for (byte, value) in diagnosisBytes.enumerated() {
            for slot in 0..<4 {
                let grade = (value >> (6 - slot * 2)) & 3
                let id = (byte + 1) * 10 + slot + 1
                guard grade > 0, BandEcgFinding.names[id] != nil else { continue }
                out.append(BandEcgFinding(id: id, grade: grade))
            }
        }
        return out
    }

    /// Every named finding at its grade (0 when the band saw none of it), for the list.
    var allFindings: [BandEcgFinding] {
        let found = Dictionary(uniqueKeysWithValues: findings.map { ($0.id, $0.grade) })
        return BandEcgFinding.names.keys.sorted().map { BandEcgFinding(id: $0, grade: found[$0] ?? 0) }
    }

    /// The headline, as the official app titles the strip: "Sinus rhythm" unless a finding says
    /// otherwise.
    var rhythm: String {
        if let strongest = findings.max(by: { $0.grade < $1.grade }), strongest.grade >= 2 { return strongest.name }
        if heartRate > 100 { return "Sinus tachycardia" }
        if heartRate > 0 && heartRate < 60 { return "Sinus bradycardia" }
        return "Sinus rhythm"
    }

    var qrsDirection: String { qrsAmplitudeUv >= 0 ? "Upward" : "Downward" }

    /// The record's summary values (`RingMeasurementRecord.extra`), canonical units.
    var extra: [String: Double] {
        var out: [String: Double] = [
            "qtc_ms": Double(qtcMs), "qrs_ms": Double(qrsMs), "qrs_amplitude_mv": Double(qrsAmplitudeUv) / 1000,
            "st_amplitude_mv": Double(stAmplitudeUv) / 1000, "sdnn_ms": Double(sdnnMs), "rmssd_ms": Double(rmssdMs),
            "pwv": Double(pwv), "myocarditis_risk": Double(myocarditisRisk), "coronary_risk": Double(coronaryRisk),
            "arteriosclerosis_risk": Double(arteriosclerosisRisk), "arrhythmia_risk": Double(arrhythmiaRisk),
            "stress_index": Double(stressIndex), "fatigue_index": Double(fatigueIndex),
        ]
        if hrv > 0 { out["hrv"] = Double(hrv) }
        if respiratoryRate > 0 { out["respiratory_rate"] = Double(respiratoryRate) }
        return out.filter { $0.value != 0 || $0.key.hasSuffix("_mv") }
    }
}

/// One ECG reading, kept whole for its report page.
struct BandEcgReport: Codable, Equatable, Identifiable {
    var date: Date
    var diagnosis: BandEcgDiagnosis?
    /// The band's heart rate, about once a second through the reading.
    var heartRates: [Int]
    /// The waveform, as the band sent it (raw counts), at `sampleRate`.
    var samples: [Int]
    var sampleRate: Int

    var id: Date { date }
    var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0 }

    var averageHeartRate: Int? { heartRates.isEmpty ? diagnosis.map(\.heartRate) : heartRates.reduce(0, +) / heartRates.count }
    var maxHeartRate: Int? { heartRates.max() ?? diagnosis?.heartRate }
    var minHeartRate: Int? { heartRates.min() ?? diagnosis?.heartRate }

    /// Shares of the seconds that were normal (60–100), fast (>100) and slow (<60).
    var heartRateShares: (normal: Double, fast: Double, slow: Double) {
        let all = heartRates.isEmpty ? diagnosis.map { [$0.heartRate] } ?? [] : heartRates
        guard !all.isEmpty else { return (0, 0, 0) }
        let n = Double(all.count)
        return (Double(all.filter { (60...100).contains($0) }.count) / n, Double(all.filter { $0 > 100 }.count) / n,
                Double(all.filter { $0 < 60 }.count) / n)
    }
}

/// Each band's ECG reports, one JSON file per reading, newest kept.
enum BandEcgStore {
    static let keep = 60

    private static func directory(_ deviceID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BandEcg/\(deviceID)", isDirectory: true)
    }

    static func save(_ report: BandEcgReport, deviceID: String) {
        let dir = directory(deviceID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(Int(report.date.timeIntervalSince1970)).json")
        try? JSONEncoder().encode(report).write(to: file, options: .atomic)
        // Oldest go first.
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for old in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// Newest first.
    static func reports(deviceID: String) -> [BandEcgReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(deviceID), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? JSONDecoder().decode(BandEcgReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    static func delete(_ report: BandEcgReport, deviceID: String) {
        try? FileManager.default.removeItem(at: directory(deviceID)
            .appendingPathComponent("\(Int(report.date.timeIntervalSince1970)).json"))
    }
}

/// The waveform made readable: the band's raw counts with the baseline wander taken out (a
/// running mean of about 0.6 s subtracted) and the hum smoothed (a short running mean).
enum BandEcgSignal {
    static func cleaned(_ raw: [Int], rate: Int) -> [Double] {
        guard raw.count > 4 else { return raw.map(Double.init) }
        let x = raw.map(Double.init)
        let window = max(3, rate * 6 / 10)
        var prefix = [0.0]
        prefix.reserveCapacity(x.count + 1)
        for v in x { prefix.append(prefix.last! + v) }
        let detrended = x.indices.map { i -> Double in
            let lo = max(0, i - window / 2), hi = min(x.count, i + window / 2 + 1)
            return x[i] - (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
        return detrended.indices.map { i in
            let lo = max(0, i - 1), hi = min(detrended.count - 1, i + 1)
            return detrended[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }

    /// The trace's height: the spread between its 2nd and 98th percentile, so a few spikes
    /// don't flatten the rest.
    static func spread(_ y: [Double]) -> Double {
        guard y.count > 10 else { return max(1, (y.max() ?? 1) - (y.min() ?? 0)) }
        let sorted = y.sorted()
        let lo = sorted[sorted.count * 2 / 100], hi = sorted[sorted.count * 98 / 100]
        return max(1, hi - lo)
    }

    /// A frame from the waveform channel (`BandGATT.wave`), as the SDK unpacks the E910's ECG
    /// type 11 (`vp_l` case 11): `(length − 5) / 3` samples, 24-bit big-endian from byte 1, sign
    /// in bit 23; `FFFFFF` is no sample.
    static func waveSamples(_ f: [UInt8]) -> [Int] {
        guard f.count > 5 else { return [] }
        let count = (f.count - 5) / 3
        return (0..<count).compactMap { i in
            let raw = Int(f[1 + i * 3]) << 16 | Int(f[2 + i * 3]) << 8 | Int(f[3 + i * 3])
            if raw == 0xFFFFFF { return nil }
            return raw & 0x800000 == 0 ? raw : raw - 0x1000000
        }
    }
}
