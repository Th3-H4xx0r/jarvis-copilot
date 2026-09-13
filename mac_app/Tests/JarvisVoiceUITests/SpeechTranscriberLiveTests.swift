import XCTest
@testable import JarvisVoiceUI

/// The on-device transcriber against real speech, without a microphone.
///
/// Opt-in with `JC_LIVE_SPEECH=1`: the first run downloads the language model.
/// Audio comes from `say`, converted to 16 kHz mono Int16 and fed in 100 ms
/// chunks — exactly the frames and cadence the mic path hands the recognizer.
/// (Playing speech at the Mac's mic does not work for this: voice processing
/// cancels the Mac's own speaker output, as it should.)
@MainActor
final class SpeechTranscriberLiveTests: XCTestCase {

    func testItTranscribesSpeechFedTheWayTheMicFeedsIt() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JC_LIVE_SPEECH"] == "1",
                          "set JC_LIVE_SPEECH=1 to run")
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }

        let engine = AnalyzerSpeechEngine()
        let readiness = await engine.prepare { _ in }
        XCTAssertEqual(readiness, .ready)

        let pcm = try Self.spokenPcm16("the quick brown fox jumps over the lazy dog")
        let session = try XCTUnwrap(engine.makeSession(sampleRate: 16000))
        var partials: [String] = []
        session.onPartial = { partials.append($0) }

        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 3200, pcm.count)   // 100 ms at 16 kHz Int16
            session.feed(pcm.subdata(in: offset..<end))
            offset = end
        }
        let transcript = await session.stop()

        XCTAssertTrue(transcript.lowercased().contains("quick brown fox"), "got: \(transcript)")
        XCTAssertFalse(partials.isEmpty, "live words were reported while it listened")
        XCTAssertTrue(session.isDone)
    }

    func testSilenceTranscribesToNothing() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JC_LIVE_SPEECH"] == "1",
                          "set JC_LIVE_SPEECH=1 to run")
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }

        let engine = AnalyzerSpeechEngine()
        _ = await engine.prepare { _ in }
        let session = try XCTUnwrap(engine.makeSession(sampleRate: 16000))
        session.feed(Data(count: 16000 * 2))   // one second of digital silence
        let transcript = await session.stop()
        // What turns a quiet cough into "Didn't catch that" rather than a turn.
        XCTAssertEqual(transcript, "")
    }

    /// `say` → 16 kHz mono Int16 LE samples, header stripped.
    private static func spokenPcm16(_ phrase: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
        let aiff = dir.appendingPathComponent("jc-live-speech.aiff")
        let wav = dir.appendingPathComponent("jc-live-speech.wav")
        try run("/usr/bin/say", ["-o", aiff.path, phrase])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                                        aiff.path, wav.path])
        let file = try Data(contentsOf: wav)
        // The samples follow the "data" chunk's 8-byte header; WAVE files are
        // not always the canonical 44 bytes up to there.
        guard let marker = file.range(of: Data("data".utf8)) else {
            throw XCTSkip("no data chunk in the converted audio")
        }
        return file.subdata(in: (marker.upperBound + 4)..<file.count)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }
}
