import Accelerate
import AVFoundation

/// Turns the microphone's buffers into nine levels (0…1) for the pill's dots,
/// low voices on the left, high on the right. Fed from the audio thread, read by
/// the pill at 30 fps; only the latest nine numbers are kept, behind a lock.
/// After coucou's FlowAudioBands (github.com/Louis-CFM/coucou, MIT).
final class FlowAudioBands: @unchecked Sendable {
    static let fftSize = 1024
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]
    private let lock = NSLock()
    private var latest = [Float](repeating: 0, count: FlowBands.count)
    private var ranges: [Range<Int>] = []
    private var rate: Double = 0
    // Scratch, audio thread only.
    private var frame = [Float](repeating: 0, count: FlowAudioBands.fftSize)
    private var real = [Float](repeating: 0, count: FlowAudioBands.fftSize / 2)
    private var imag = [Float](repeating: 0, count: FlowAudioBands.fftSize / 2)
    private var power = [Float](repeating: 0, count: FlowAudioBands.fftSize / 2)

    init() {
        fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
    }

    var levels: [Float] { lock.withLock { latest } }

    func reset() { lock.withLock { latest = [Float](repeating: 0, count: FlowBands.count) } }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let fft, let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n >= Self.fftSize else { return }
        if buffer.format.sampleRate != rate {
            rate = buffer.format.sampleRate
            ranges = FlowBands.binRanges(fftSize: Self.fftSize, sampleRate: rate)
        }
        let start = n - Self.fftSize
        for i in 0..<Self.fftSize { frame[i] = data[start + i] * window[i] }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                var spectrum = split
                fft.forward(input: split, output: &spectrum)
                vDSP.squareMagnitudes(spectrum, result: &power)
            }
        }
        let scale = Float(1.0 / Double(Self.fftSize * Self.fftSize))
        var out = [Float](repeating: 0, count: FlowBands.count)
        for (i, range) in ranges.enumerated() {
            var sum: Float = 0
            for b in range where b < power.count { sum += power[b] }
            let db = 10 * log10(Double(max(sum * scale, 1e-12)))
            // Speech is weaker up high: a little tilt so the right-hand dots move too.
            out[i] = Float(FlowBands.level(db: db + Double(i) * 2.2))
        }
        lock.withLock { latest = out }
    }
}
