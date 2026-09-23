import Accelerate
import CoreML
import Foundation

/// A voiceprint made on the phone, comparable with the server's.
///
/// The server identifies voices with WeSpeaker ResNet34 (`live_voiceprint.py`):
/// decode the utterance's Opus, compute Kaldi fbank features, embed, match —
/// 276 ms mean on its shared four cores, behind the language rescue in the
/// queue. The phone already holds the raw samples, so it can skip the decode
/// and the embedding there and hand over the vector instead. The MATCHING
/// stays on the server, which owns every voice's history.
///
/// Comparable is the whole requirement: a vector from a different model, or
/// from the same model fed different features, is not a worse match but a
/// meaningless one. So the model is the server's own ONNX checkpoint converted
/// to CoreML (parity measured on real speech: cosine 0.99999 at fp16, 1.0 at
/// fp32, at lengths from 1.6 to 12 s), and `fbank` is a line-for-line port of
/// `live_voiceprint.kaldi_fbank`, whose own notes record what a near-miss
/// costs: a librosa-shaped filterbank scored 0.58, forgetting CMN 0.52.
enum LiveVoiceprint {

    /// The interlock id. It must equal the server's `live_voiceprint.MODEL_ID`
    /// and `live.embed_model`: declaring it says "my vectors are yours".
    static let modelID = "wespeaker-resnet34-lm-v1"
    static let dimension = 256

    static let sampleRate = 16000
    static let melBins = 80
    static let frameLength = 400   // 25 ms
    static let frameShift = 160    // 10 ms
    static let fftSize = 512
    static let preemphasis = 0.97
    static let lowFrequency = 20.0
    static let logFloor: Float = 1.1920928955078125e-07

    /// Shorter than this carries no usable voice; the server refuses it too.
    static let minSpeechMs = 600
    /// The server embeds at most this much of an utterance.
    static let maxSpeechMs = 20_000

    // MARK: - Features

    /// `(frames, 80)` log-mel features with CMN applied, row-major, or nil when
    /// the audio is shorter than one window.
    ///
    /// `samples` are on the int16 scale (±32768), NOT ±1.0 — the server reads
    /// PCM the same way, and the features are log energies, so a scale change is
    /// not harmless. Every step mirrors `kaldi_fbank`, in its order: per-frame DC
    /// removal, preemphasis with the first sample replicated, a symmetric
    /// Hamming window, a zero-padded 512-point FFT, power, the mel bank, the log
    /// with its floor, and mean normalisation over the utterance.
    static func fbank(_ samples: [Double]) -> (frames: Int, values: [Float])? {
        guard samples.count >= frameLength else { return nil }
        let frames = 1 + (samples.count - frameLength) / frameShift
        let bins = fftSize / 2 + 1
        let window = hamming(frameLength)
        let bank = melBank()
        // The C interface: the Swift `vDSP.DFT` wrapper is deprecated, and its
        // replacement is newer than this app's oldest supported iOS.
        guard let dft = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(fftSize), .FORWARD)
        else { return nil }
        defer { vDSP_DFT_DestroySetupD(dft) }

        var power = [Float](repeating: 0, count: frames * bins)
        var frame = [Double](repeating: 0, count: fftSize)
        let zeros = [Double](repeating: 0, count: fftSize)
        var outReal = [Double](repeating: 0, count: fftSize)
        var outImag = [Double](repeating: 0, count: fftSize)
        for f in 0..<frames {
            let start = f * frameShift
            let chunk = samples[start..<(start + frameLength)]
            let mean = chunk.reduce(0, +) / Double(frameLength)
            var previous = chunk[chunk.startIndex] - mean
            for (i, raw) in chunk.enumerated() {
                let centred = raw - mean
                // frame[0] = x0 - 0.97·x0: the first sample is its own predecessor.
                frame[i] = (centred - preemphasis * previous) * window[i]
                previous = centred
            }
            for i in frameLength..<fftSize { frame[i] = 0 }
            vDSP_DFT_ExecuteD(dft, frame, zeros, &outReal, &outImag)
            for k in 0..<bins {
                power[f * bins + k] = Float(outReal[k] * outReal[k] + outImag[k] * outImag[k])
            }
        }

        // energies (frames × mels) = power (frames × bins) · bankᵀ (bins × mels)
        var energies = [Float](repeating: 0, count: frames * melBins)
        let bankT = transpose(bank, rows: melBins, cols: bins)
        vDSP_mmul(power, 1, bankT, 1, &energies, 1,
                  vDSP_Length(frames), vDSP_Length(melBins), vDSP_Length(bins))
        for i in energies.indices { energies[i] = logf(max(energies[i], logFloor)) }

        // CMN over the utterance.
        for m in 0..<melBins {
            var sum: Float = 0
            for f in 0..<frames { sum += energies[f * melBins + m] }
            let mean = sum / Float(frames)
            for f in 0..<frames { energies[f * melBins + m] -= mean }
        }
        return (frames, energies)
    }

    /// Symmetric Hamming, 0.54 − 0.46·cos(2πn/(N−1)) — numpy's `hamming`, Kaldi's.
    static func hamming(_ n: Int) -> [Double] {
        (0..<n).map { 0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
    }

    /// Kaldi's mel filterbank, `(80, 257)` row-major. No area normalisation, the
    /// triangles laid over 256 bins and a zero Nyquist column — both details are
    /// what a librosa-shaped bank gets wrong.
    static func melBank() -> [Float] {
        let fftBins = fftSize / 2
        let nyquist = 0.5 * Double(sampleRate)
        let binWidth = Double(sampleRate) / Double(fftSize)
        func mel(_ hz: Double) -> Double { 1127.0 * log(1.0 + hz / 700.0) }
        let low = mel(lowFrequency), high = mel(nyquist)
        let delta = (high - low) / Double(melBins + 1)
        var bank = [Float](repeating: 0, count: melBins * (fftBins + 1))
        for m in 0..<melBins {
            let left = low + Double(m) * delta
            let centre = low + Double(m + 1) * delta
            let right = low + Double(m + 2) * delta
            for k in 0..<fftBins {
                let x = 1127.0 * log1p(binWidth * Double(k) / 700.0)
                let up = (x - left) / (centre - left)
                let down = (right - x) / (right - centre)
                bank[m * (fftBins + 1) + k] = Float(max(0, min(up, down)))
            }
        }
        return bank
    }

    private static func transpose(_ m: [Float], rows: Int, cols: Int) -> [Float] {
        var out = [Float](repeating: 0, count: m.count)
        vDSP_mtrans(m, 1, &out, 1, vDSP_Length(cols), vDSP_Length(rows))
        return out
    }
}

/// Something that turns an utterance's PCM into a voiceprint. A protocol so the
/// store can be tested without CoreML.
protocol VoiceprintEmbedding: AnyObject, Sendable {
    func embed(pcm16: Data) -> [Float]?
}

/// Runs the bundled CoreML model over `LiveVoiceprint.fbank` features.
final class LiveVoiceprintEmbedder: VoiceprintEmbedding, @unchecked Sendable {
    private let model: MLModel
    private let lock = NSLock()

    /// Nil when the model is not in the bundle or will not load — identification
    /// then stays on the server, exactly as before.
    init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "WeSpeakerResNet34", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url, configuration: MLModelConfiguration())
        else { return nil }
        self.model = model
    }

    /// Why a voiceprint could not be made, for the log and for tests.
    enum Failure: Error, Equatable {
        case features
        case output([String])
        case notFinite
    }

    /// A unit-length 256-d voiceprint for 16 kHz mono int16 PCM, or nil when
    /// the audio is too short to carry a voice or anything fails.
    func embed(pcm16: Data) -> [Float]? {
        do {
            return try voiceprint(pcm16: pcm16)
        } catch {
            JcLog.dropped(JcLog.voice, "make a voiceprint", error)
            return nil
        }
    }

    /// The same, saying why when it fails. Nil only for too little speech,
    /// which is an answer rather than a fault.
    func voiceprint(pcm16: Data) throws -> [Float]? {
        let count = pcm16.count / 2
        let minimum = LiveVoiceprint.sampleRate * LiveVoiceprint.minSpeechMs / 1000
        guard count >= minimum else { return nil }
        let usable = min(count, LiveVoiceprint.sampleRate * LiveVoiceprint.maxSpeechMs / 1000)
        var samples = [Double](repeating: 0, count: usable)
        pcm16.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for i in 0..<usable { samples[i] = Double(Int16(littleEndian: ints[i])) }
        }
        guard let feats = LiveVoiceprint.fbank(samples), feats.frames >= 2 else { throw Failure.features }
        let input = try MLMultiArray(shape: [1, NSNumber(value: feats.frames),
                                             NSNumber(value: LiveVoiceprint.melBins)],
                                     dataType: .float32)
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: feats.values.count)
        feats.values.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: $0.count) }

        lock.lock(); defer { lock.unlock() }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["feats": input]))
        guard let embs = out.featureValue(for: "embs")?.multiArrayValue,
              embs.count == LiveVoiceprint.dimension
        else { throw Failure.output(out.featureNames.sorted()) }
        var vec = (0..<embs.count).map { Float(truncating: embs[$0]) }
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw Failure.notFinite }
        for i in vec.indices { vec[i] /= norm }
        return vec
    }
}
