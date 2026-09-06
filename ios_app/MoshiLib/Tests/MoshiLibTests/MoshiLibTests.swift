import XCTest
@testable import MoshiLib

final class MoshiLibTests: XCTestCase {
    func testEachModelPairsWithTheRightVocab() {
        // Vocab file must match the config's text vocab size, per Kyutai's CLI.
        XCTAssertEqual(MoshiRuntime.Model.hibiki.config.textOutVocabSize, 48000)
        XCTAssertEqual(MoshiRuntime.Model.hibiki.vocabFile, "tokenizer_spm_48k_multi6_2.json")
        XCTAssertEqual(MoshiRuntime.Model.moshiko.config.textOutVocabSize, 32000)
        XCTAssertEqual(MoshiRuntime.Model.moshiko.vocabFile, "tokenizer_spm_32k_3.json")
        XCTAssertEqual(MoshiRuntime.Model.moshika.vocabFile, MoshiRuntime.Model.moshiko.vocabFile)
        // The 7B weights come from Kyutai's MLX repos; the step loop slices 8 codebooks.
        XCTAssertEqual(MoshiRuntime.Model.moshiko.weights.repo, "kyutai/moshiko-mlx-q4")
        for m in MoshiRuntime.Model.allCases { XCTAssertEqual(m.config.depformerSlices(), 8, m.rawValue) }
    }

    func testTextPiecesSkipSilenceAndUnescapeSpaces() {
        let vocab = [0: "<pad>", 3: "<eos>", 42: "▁hello", 43: "!"]
        XCTAssertNil(MoshiRuntime.textPiece(0, vocab: vocab))
        XCTAssertNil(MoshiRuntime.textPiece(3, vocab: vocab))
        XCTAssertNil(MoshiRuntime.textPiece(999, vocab: vocab))
        XCTAssertEqual(MoshiRuntime.textPiece(42, vocab: vocab), " hello")
        XCTAssertEqual(MoshiRuntime.textPiece(43, vocab: vocab), "!")
    }

    func testFrameGeometry() {
        // 80 ms at 24 kHz, the Mimi frame the runtime steps on.
        XCTAssertEqual(Double(MoshiRuntime.frameSize) / MoshiRuntime.sampleRate, 0.08, accuracy: 1e-9)
    }

    func testStepBeforeLoadIsANoop() {
        let rt = MoshiRuntime()
        XCTAssertFalse(rt.isLoaded)
        let out = rt.step(pcm: [Float](repeating: 0, count: MoshiRuntime.frameSize))
        XCTAssertTrue(out.audio.isEmpty)
        XCTAssertTrue(out.text.isEmpty)
    }
}
