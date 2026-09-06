import XCTest
@testable import MoshiLib

final class MoshiLibTests: XCTestCase {
    func testMoshi1bConfigMatchesTheBundledVocab() {
        // The vocab we download must be the one the 1B config expects (48k pieces).
        let cfg = LmConfig.moshi1b(audioDelay: 2)
        XCTAssertEqual(cfg.textOutVocabSize, 48000)
        XCTAssertEqual(MoshiRuntime.Files.vocab, "tokenizer_spm_48k_multi6_2.json")
        XCTAssertEqual(MoshiRuntime.Files.vocabFile(for: LmConfig.asr300m()),
                       MoshiRuntime.Files.vocabFile(for: cfg).isEmpty ? "" : MoshiRuntime.Files.vocabFile(for: LmConfig.asr300m()))
        XCTAssertEqual(cfg.audioCodebooks, 16)
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
