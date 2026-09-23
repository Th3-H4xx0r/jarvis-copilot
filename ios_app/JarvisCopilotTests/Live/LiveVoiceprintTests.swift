import XCTest
@testable import JarvisCopilot

/// The phone's voiceprint must be the server's voiceprint, or matching it
/// against the stored voices means nothing.
///
/// The expected numbers come from the SERVER's own code on the same signal:
/// `live_voiceprint.kaldi_fbank` for the features and the ONNX checkpoint the
/// server runs for the embedding. The signal is built from integer arithmetic
/// alone so Swift and Python produce the identical samples.
final class LiveVoiceprintTests: XCTestCase {

    /// 1.5 s at 16 kHz: pseudo-random noise plus a 100 Hz sawtooth. Mirrors,
    /// in Python, `((n*7919 + n*n % 104729) % 20001 - 10000) // 4 + (n % 160 - 80) * 40`.
    private func signal() -> [Int16] {
        (0..<Int64(24_000)).map { n in
            let a = (n * 7919 + (n * n) % 104_729) % 20_001 - 10_000
            let quarter = a >= 0 ? a / 4 : -((-a + 3) / 4)   // Python's floor division
            return Int16(quarter + ((n % 160) - 80) * 40)
        }
    }

    func testTheFeaturesAreTheServersKaldiFbank() throws {
        let samples = signal().map(Double.init)
        let feats = try XCTUnwrap(LiveVoiceprint.fbank(samples))

        XCTAssertEqual(feats.frames, 148)
        let at = { (t: Int, m: Int) -> Double in Double(feats.values[t * LiveVoiceprint.melBins + m]) }
        // (frame, mel bin) -> the server's value on the same samples.
        let expected: [((Int, Int), Double)] = [
            ((0, 0), -0.11884784698486328), ((0, 79), -1.0644035339355469),
            ((50, 10), 0.17865753173828125), ((100, 40), 0.4278526306152344),
            ((147, 3), -0.04752159118652344), ((147, 79), -0.6509876251220703),
        ]
        for ((t, m), value) in expected {
            XCTAssertEqual(at(t, m), value, accuracy: 1e-4, "frame \(t), bin \(m)")
        }
        let meanAbs = feats.values.reduce(0) { $0 + abs(Double($1)) } / Double(feats.values.count)
        XCTAssertEqual(meanAbs, 0.6110284924507141, accuracy: 1e-4)
    }

    func testTheBundledModelGivesTheServersVoiceprint() throws {
        let embedder = try XCTUnwrap(LiveVoiceprintEmbedder(), "the model ships in the app")
        let pcm = signal().withUnsafeBufferPointer { Data(buffer: $0) }

        let vec = try XCTUnwrap(try embedder.voiceprint(pcm16: pcm))

        XCTAssertEqual(vec.count, LiveVoiceprint.dimension)
        let cosine = zip(vec, Self.serverEmbedding).reduce(0.0) { $0 + Double($1.0) * $1.1 }
        XCTAssertGreaterThan(cosine, 0.9999,
                             "measured 0.99999 on real speech; below this the vectors are not comparable")
    }

    func testTooLittleSpeechMakesNoVoiceprint() throws {
        let embedder = try XCTUnwrap(LiveVoiceprintEmbedder())
        let short = Array(signal().prefix(LiveVoiceprint.sampleRate * 400 / 1000))
        XCTAssertNil(embedder.embed(pcm16: short.withUnsafeBufferPointer { Data(buffer: $0) }))
    }

    /// The server's unit-length embedding of `signal()`, from the ONNX model.
    private static let serverEmbedding: [Double] = [
        0.002804, 0.003479, -0.022095, 0.030383, -0.049284, -0.017732, 0.002828, 0.068688,
        -0.013718, 0.062904, -0.068919, 0.079723, -0.015986, 0.010474, -0.097600, 0.098448,
        0.020415, -0.004911, 0.036311, 0.063988, -0.025988, -0.109348, -0.025453, 0.001048,
        -0.038412, -0.036786, 0.056139, 0.036741, -0.034727, 0.032198, -0.024617, 0.036381,
        -0.029864, 0.101481, 0.019973, -0.026713, -0.072646, 0.072395, -0.016132, 0.054950,
        0.067346, -0.010291, -0.082336, 0.002134, -0.054591, 0.094453, 0.016918, -0.040919,
        0.088759, 0.042738, 0.145331, -0.056709, 0.131883, 0.072041, -0.078139, 0.001947,
        -0.001054, 0.015901, -0.099763, -0.059674, 0.073973, 0.085013, 0.078141, 0.081998,
        0.016209, -0.008266, -0.002450, 0.066737, -0.028229, 0.055964, -0.029246, -0.036787,
        0.177649, -0.078943, -0.042128, -0.026613, -0.157764, -0.108285, 0.079628, -0.041169,
        0.010568, 0.011943, -0.037770, 0.010829, -0.142220, -0.074966, 0.071948, 0.053334,
        0.049866, -0.016460, 0.055608, 0.060549, -0.059727, 0.004344, -0.066185, -0.000960,
        0.033763, 0.055739, -0.078922, -0.057381, 0.052139, 0.013888, -0.008925, 0.028099,
        0.017697, 0.120667, -0.025243, -0.027447, -0.059203, -0.088108, 0.041690, -0.072708,
        -0.020546, 0.003190, -0.109663, 0.016580, -0.091876, 0.033841, -0.041259, 0.000077,
        0.004597, -0.001506, -0.099125, -0.038097, -0.190645, -0.025260, -0.007743, 0.001211,
        -0.018499, -0.029686, -0.004401, 0.031727, 0.014388, 0.047519, 0.032696, -0.049172,
        0.019042, 0.100449, 0.030270, -0.013334, -0.017620, -0.035386, -0.000430, -0.033468,
        -0.080012, -0.061131, -0.021264, -0.036233, 0.033553, -0.060784, -0.036274, -0.000732,
        -0.083734, 0.015337, -0.126311, 0.008503, 0.037038, -0.022057, 0.031396, 0.073452,
        0.032930, -0.124739, 0.021430, -0.097161, -0.012106, -0.041874, -0.051465, -0.043692,
        0.112373, 0.102308, -0.066819, 0.074503, 0.093392, 0.003169, 0.021294, -0.134905,
        -0.001371, -0.030929, 0.007323, 0.074912, -0.106388, 0.078415, -0.057668, -0.070737,
        -0.040727, 0.037682, -0.022976, 0.116793, 0.071716, -0.020304, -0.164624, 0.003516,
        -0.098903, -0.032918, 0.000019, -0.042434, -0.053862, 0.003413, -0.008065, -0.048474,
        -0.022159, -0.014663, 0.083691, 0.073238, -0.058464, -0.036920, 0.135917, 0.094423,
        -0.005322, -0.040047, 0.064845, -0.032334, 0.077975, 0.014891, -0.087379, 0.085291,
        -0.079178, -0.027694, 0.082090, -0.031018, -0.063517, 0.110786, 0.032861, -0.078568,
        -0.065507, 0.014356, -0.006052, 0.012613, 0.005291, -0.137549, -0.131355, 0.051022,
        0.113282, 0.091812, 0.074317, 0.072419, 0.058556, -0.028167, -0.125042, -0.056060,
        0.027133, -0.008862, -0.033090, 0.018065, -0.066256, -0.029720, -0.068852, -0.006187,
        0.041841, 0.015868, 0.049396, -0.059804, 0.037107, 0.024964, 0.014645, -0.015391,
    ]
}
