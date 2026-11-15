import AVFoundation
import Foundation

/// The Mac's beacon codes — the same numbers as `mac_app/JarvisMac/Sources/HoloDrop/HoloDropModels.swift`
/// (`HoloBeaconCode`): a chirp is FSK, one 15 ms tone per bit (18.5 kHz = 0, 19.5 kHz = 1),
/// preamble 1010 then the nonce's 16 bits; a screen flash is 10 frames a second, preamble then 11 bits.
enum HoloBeaconCode {
    static let chirpSymbol: TimeInterval = 0.015
    static let zeroHz: Double = 18_500
    static let oneHz: Double = 19_500
    static let flashHz: Double = 10
    static let preamble: [Bool] = [true, false, true, false]

    static func code16(_ nonce: String) -> UInt16 {
        let t = nonce.trimmingCharacters(in: .whitespaces)
        if let n = UInt64(t) { return UInt16(truncatingIfNeeded: n) }
        if t.count <= 16, let n = UInt64(t.hasPrefix("0x") ? String(t.dropFirst(2)) : t, radix: 16) {
            return UInt16(truncatingIfNeeded: n)
        }
        var h: UInt32 = 2_166_136_261
        for b in t.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return UInt16(truncatingIfNeeded: h)
    }

    static func chirpBits(_ nonce: String) -> [Bool] {
        let c = code16(nonce)
        return preamble + (0..<16).reversed().map { (c >> UInt16($0)) & 1 == 1 }
    }

    static func flashFrames(_ nonce: String) -> [Bool] {
        let c = code16(nonce)
        return preamble + (0..<11).reversed().map { (c >> UInt16($0)) & 1 == 1 }
    }

    /// A fresh nonce: a decimal number (the Mac reads its low 16 bits).
    static func newNonce() -> String { String(UInt16.random(in: 1...UInt16.max)) }
}

/// Finds a known chirp in microphone samples (matched Goertzel detection: we chose the nonce,
/// so we know exactly which tone to expect in each 15 ms slot).
enum HoloChirpDecoder {
    struct Hit: Equatable {
        let start: Int          // sample index where the chirp begins
        let score: Double       // 0…1: how cleanly each slot had the expected tone
        let amplitude: Double   // tone amplitude (0…1 full scale)
        let snr: Double         // tone energy over the recording's median energy at those tones
    }

    /// Goertzel power of `f` over `x[from..<from+n]`, normalised (a sine of amplitude A → A²/4).
    static func power(_ x: [Float], from: Int, n: Int, f: Double, rate: Double) -> Double {
        let k = 2 * cos(2 * Double.pi * f / rate)
        var s1 = 0.0, s2 = 0.0
        for i in from..<(from + n) {
            let s0 = Double(x[i]) + k * s1 - s2
            s2 = s1
            s1 = s0
        }
        let p = s1 * s1 + s2 * s2 - k * s1 * s2
        return p / Double(n * n)
    }

    static func find(_ x: [Float], rate: Double, nonce: String) -> Hit? {
        let bits = HoloBeaconCode.chirpBits(nonce)
        let sym = Int(rate * HoloBeaconCode.chirpSymbol)
        let hop = max(1, sym / 4)
        guard sym > 8, x.count >= sym * bits.count else { return nil }
        let windows = (x.count - sym) / hop + 1
        var e0 = [Double](repeating: 0, count: windows), e1 = e0
        for w in 0..<windows {
            e0[w] = power(x, from: w * hop, n: sym, f: HoloBeaconCode.zeroHz, rate: rate)
            e1[w] = power(x, from: w * hop, n: sym, f: HoloBeaconCode.oneHz, rate: rate)
        }
        let perSymbol = sym / hop
        let span = perSymbol * (bits.count - 1)
        guard windows > span else { return nil }
        // Every slot must carry the expected tone, well above the room's noise at those tones:
        // the tail of someone else's chirp sharing our preamble can't pass for ours.
        let floor = median(zip(e0, e1).map { $0 + $1 })
        var best: (k: Int, score: Double, energy: Double)?
        for k in 0..<(windows - span) {
            var right = 0, total = 0.0
            for (i, bit) in bits.enumerated() {
                let w = k + i * perSymbol
                let sum = e0[w] + e1[w]
                total += sum
                if sum > 4 * floor, bit ? e1[w] > 2 * e0[w] : e0[w] > 2 * e1[w] { right += 1 }
            }
            let score = Double(right) / Double(bits.count)
            if best == nil || score > best!.score || (score == best!.score && total > best!.energy * Double(bits.count)) {
                best = (k, score, total / Double(bits.count))
            }
        }
        guard let b = best else { return nil }
        let snr = floor > 0 ? b.energy / floor : .infinity
        let amplitude = 2 * b.energy.squareRoot()
        guard b.score >= 0.85, amplitude >= 1e-4 else { return nil }
        return Hit(start: b.k * hop, score: b.score, amplitude: amplitude, snr: snr)
    }

    /// A rough distance from loudness (uncalibrated: the Mac's volume is unknown) — proximity only.
    static func distance(amplitude: Double) -> Double { min(8, max(0.3, 0.02 / max(amplitude, 1e-6))) }

    /// Rough left/right from the two microphones' levels (portrait stereo): −60° (left) … +60° (right).
    static func side(left: Double, right: Double) -> Double? {
        guard left > 0, right > 0 else { return nil }
        let db = 10 * log10(right / left)
        guard abs(db) >= 1 else { return 0 }
        return max(-60, min(60, db * 12))
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }
}

/// "Hear it": listens for the Mac's chirp for a moment while the popup asks for one.
@MainActor
final class HoloUltrasonic {
    struct Reading: Equatable {
        let distance: Double
        let offsetDeg: Double?     // left/right of where the phone points, when it has stereo mics
        let confidence: Double
    }

    static let shared = HoloUltrasonic()
    private var engine: AVAudioEngine?

    /// Starts the microphones, calls `ask` (which asks the Mac to chirp), records `seconds`, decodes.
    private var cancelled = false

    func listen(nonce: String, seconds: Double = 2.2, ask: @escaping () async -> Void) async -> Reading? {
        cancelled = false
        guard await AVAudioApplication.requestRecordPermission(), !cancelled else { return nil }
        let session = AVAudioSession.sharedInstance()
        // Put the audio session back exactly as it was (voice / Live may be using it).
        let saved = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.record, mode: .measurement)   // no voice filtering: it cuts above ~8 kHz
            Self.preferStereo(session)
            try session.setActive(true)
        } catch { return nil }
        defer {
            try? session.setPreferredInput(nil)
            try? session.setCategory(saved.0, mode: saved.1, options: saved.2)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate >= 40_000 else { return nil }      // 19.5 kHz needs ≥ 39 kHz sampling
        let box = SampleBox()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in box.add(buffer) }
        do { try engine.start() } catch { return nil }
        self.engine = engine
        await ask()
        try? await Task.sleep(for: .seconds(seconds))
        input.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        guard !cancelled else { return nil }
        let (left, right) = box.take()
        let rate = format.sampleRate
        guard let hit = HoloChirpDecoder.find(left, rate: rate, nonce: nonce) else { return nil }
        let n = Int(rate * HoloBeaconCode.chirpSymbol)
        var offset: Double?
        if right.count >= hit.start + n * 20, left.count >= hit.start + n * 20 {
            func level(_ x: [Float]) -> Double {
                (0..<20).reduce(0.0) { sum, i in
                    sum + HoloChirpDecoder.power(x, from: hit.start + i * n, n: n, f: HoloBeaconCode.oneHz, rate: rate)
                        + HoloChirpDecoder.power(x, from: hit.start + i * n, n: n, f: HoloBeaconCode.zeroHz, rate: rate)
                }
            }
            offset = HoloChirpDecoder.side(left: level(left), right: level(right))
        }
        return Reading(distance: HoloChirpDecoder.distance(amplitude: hit.amplitude), offsetDeg: offset,
                       confidence: offset == nil ? 0.15 : 0.3)
    }

    func stop() {
        cancelled = true
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// The built-in mic's stereo pattern when the phone has one (portrait left/right).
    private static func preferStereo(_ session: AVAudioSession) {
        guard let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        try? session.setPreferredInput(mic)
        guard let source = mic.dataSources?.first(where: { $0.supportedPolarPatterns?.contains(.stereo) == true }) else { return }
        try? source.setPreferredPolarPattern(.stereo)
        try? mic.setPreferredDataSource(source)
        try? session.setPreferredInputOrientation(.portrait)
    }

    /// Samples from the audio thread, read once at the end.
    private final class SampleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var left: [Float] = []
        private var right: [Float] = []

        func add(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            lock.lock()
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            if buffer.format.channelCount > 1 { right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: n)) }
            lock.unlock()
        }

        func take() -> ([Float], [Float]) {
            lock.lock(); defer { lock.unlock() }
            return (left, right)
        }
    }
}
