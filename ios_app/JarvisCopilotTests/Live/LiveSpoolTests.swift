import XCTest
@testable import JarvisCopilot

/// The bounded on-disk spool of design §8. A dropped socket is the NORMAL path, so
/// these cover the ordinary behaviour, the crash recovery, and the loud stop.
@MainActor
final class LiveSpoolTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-spool-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeSpool(limit: Int = 1024 * 1024) -> LiveSpool {
        LiveSpool(directory: directory, limitBytes: limit)
    }

    // MARK: - Line codec

    func testRecordsRoundTripThroughTheLineCodec() {
        let text = LiveOutbound.text(#"{"t":"seg","text":"hello"}"#)
        XCTAssertEqual(LiveSpool.decode(LiveSpool.encode(text)), text)

        let binary = LiveOutbound.binary(Data([0x00, 0x0A, 0xFF, 0x7F]))
        XCTAssertEqual(LiveSpool.decode(LiveSpool.encode(binary)), binary)
    }

    /// Base64 is the framing's whole point: it cannot contain a newline, so audio
    /// bytes can never split a record in half.
    func testAnEncodedRecordNeverContainsANewline() {
        let awkward = LiveOutbound.binary(Data([0x0A, 0x0D, 0x0A, 0x0A]))
        XCTAssertFalse(LiveSpool.encode(awkward).contains("\n"))
        XCTAssertFalse(LiveSpool.encode(.text("a\nb\nc")).contains("\n"))
        XCTAssertEqual(LiveSpool.decode(LiveSpool.encode(.text("a\nb\nc"))), .text("a\nb\nc"))
    }

    func testAGarbledLineIsRejectedRatherThanGuessedAt() {
        XCTAssertNil(LiveSpool.decode("T !!!not-base64!!!"))
        XCTAssertNil(LiveSpool.decode("X aGVsbG8="))
        XCTAssertNil(LiveSpool.decode(""))
    }

    // MARK: - Queue and drain

    func testFramesDrainInTheOrderTheyWereQueued() throws {
        let spool = makeSpool()
        try spool.append(.text("one"))
        try spool.append(.binary(Data([1])))
        try spool.append(.text("three"))
        XCTAssertEqual(spool.count, 3)

        var sent: [LiveOutbound] = []
        let drained = spool.drain { sent.append($0); return true }

        XCTAssertEqual(drained, 3)
        XCTAssertEqual(sent, [.text("one"), .binary(Data([1])), .text("three")])
        XCTAssertTrue(spool.isEmpty)
        XCTAssertEqual(spool.byteCount, 0)
    }

    /// The bug this guards: a half-drained spool that forgot the remainder is the
    /// same data loss as having no spool at all.
    func testARefusedSendLeavesTheRestOfTheQueueIntact() throws {
        let spool = makeSpool()
        try spool.append(.text("one"))
        try spool.append(.text("two"))
        try spool.append(.text("three"))

        var sent: [LiveOutbound] = []
        let drained = spool.drain { frame in
            guard sent.count < 1 else { return false }
            sent.append(frame)
            return true
        }

        XCTAssertEqual(drained, 1)
        XCTAssertEqual(spool.count, 2)

        var rest: [LiveOutbound] = []
        _ = spool.drain { rest.append($0); return true }
        XCTAssertEqual(rest, [.text("two"), .text("three")],
                       "the unsent remainder must survive in order")
    }

    func testDrainingAnEmptySpoolSendsNothing() {
        let spool = makeSpool()
        var calls = 0
        XCTAssertEqual(spool.drain { _ in calls += 1; return true }, 0)
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Crash recovery

    /// A relaunch mid-conversation must find its unsent audio, or the drop that
    /// outlived the process silently loses whatever was said during it.
    func testUnsentFramesSurviveANewSpoolOverTheSameDirectory() throws {
        let first = makeSpool()
        first.adopt(sessionID: "L1")
        try first.append(.text("kept"))
        try first.append(.binary(Data([9, 9])))

        let second = makeSpool()
        XCTAssertEqual(second.sessionID, "L1")
        XCTAssertEqual(second.count, 2)
        var sent: [LiveOutbound] = []
        _ = second.drain { sent.append($0); return true }
        XCTAssertEqual(sent, [.text("kept"), .binary(Data([9, 9]))])
    }

    /// A kill mid-append leaves a torn final line. It must cost one frame, not the
    /// whole file.
    func testATornFinalLineCostsOneFrameNotTheFile() throws {
        let first = makeSpool()
        first.adopt(sessionID: "L1")
        try first.append(.text("good one"))
        try first.append(.text("good two"))

        let file = directory.appendingPathComponent("outbox.log")
        let text = try String(contentsOf: file, encoding: .utf8)
        try (text + "T !!!torn").write(to: file, atomically: true, encoding: .utf8)

        let recovered = makeSpool()
        XCTAssertEqual(recovered.count, 2, "both intact records must survive the torn one")
    }

    /// **The opening of every recording.** Audio is captured between tapping Record
    /// and the server answering with an id, so it lands in an UNBOUND spool. Adopting
    /// the id must keep it — this used to delete it, which for an offline start meant
    /// deleting the entire recording.
    func testAdoptingAnIDKeepsWhatWasCapturedBeforeTheSessionHadOne() throws {
        let spool = makeSpool()
        XCTAssertEqual(spool.sessionID, "", "a fresh spool is unbound")
        try spool.append(.text("said before the server answered"))
        try spool.append(.binary(Data([1, 2, 3])))

        spool.adopt(sessionID: "L1")

        XCTAssertEqual(spool.count, 2, "pre-ready audio must survive being bound to a session")
        XCTAssertEqual(spool.sessionID, "L1")
    }

    /// A spool reused for a new recording must start unbound, or the next recording's
    /// pre-ready audio is attributed to the session that just ended.
    func testResetLeavesTheSpoolUnbound() throws {
        let spool = makeSpool()
        spool.adopt(sessionID: "L1")
        try spool.append(.text("x"))
        spool.reset()
        XCTAssertEqual(spool.sessionID, "")
    }

    /// Replaying a previous conversation's audio into a new session would file it
    /// under the wrong transcript — but it is moved aside, not destroyed.
    func testAdoptingADifferentSessionSetsTheOldBacklogAsideRatherThanDeletingIt() throws {
        let spool = makeSpool()
        spool.adopt(sessionID: "L1")
        try spool.append(.text("from the old conversation"))
        XCTAssertEqual(spool.count, 1)

        spool.adopt(sessionID: "L2")
        XCTAssertTrue(spool.isEmpty)
        XCTAssertEqual(spool.sessionID, "L2")

        // The bytes are still on disk under the old session's name.
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(kept.contains { $0.contains("session-L1") },
                      "the old conversation must be recoverable, not deleted: \(kept)")
    }

    /// A file that exists but cannot be read is NOT the same as no file, and
    /// overwriting it would destroy the only copy of part of a conversation.
    func testAnUnreadableFileIsMovedAsideRatherThanOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("outbox.log")
        // Invalid UTF-8.
        try Data([0xFF, 0xFE, 0xFF, 0xFE]).write(to: file)

        let spool = makeSpool()
        XCTAssertTrue(spool.isEmpty)
        XCTAssertNotNil(spool.quarantinedFile, "the caller has to be able to say this happened")

        let kept = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(kept.contains { $0.contains("corrupt") }, "\(kept)")
    }

    // MARK: - Re-queueing unconfirmed frames

    /// `send` is fire-and-forget, so frames handed to a socket that then dies have to
    /// go back — at the HEAD, or the transcript arrives out of order.
    func testPrependPutsUnconfirmedFramesBackInFrontOfTheQueue() throws {
        let spool = makeSpool()
        try spool.append(.text("captured after the socket died"))

        try spool.prepend([.text("written first"), .text("written second")])

        var order: [LiveOutbound] = []
        _ = spool.drain { order.append($0); return true }
        XCTAssertEqual(order, [.text("written first"),
                               .text("written second"),
                               .text("captured after the socket died")])
    }

    func testPrependRespectsTheBoundRatherThanOverflowingIt() throws {
        let spool = makeSpool(limit: 120)
        XCTAssertThrowsError(try spool.prepend([.binary(Data(repeating: 0, count: 256))])) { failure in
            guard case LiveSpoolError.full = failure else {
                return XCTFail("expected .full, got \(failure)")
            }
        }
    }

    // MARK: - Bounded drain

    /// A 30 MB backlog uploaded in one pass would base64 and rewrite the lot on the
    /// main actor, from the audio callback.
    func testDrainIsBoundedByItsLimitAndResumesWhereItStopped() throws {
        let spool = makeSpool()
        for index in 0..<10 { try spool.append(.text("frame \(index)")) }

        var first: [LiveOutbound] = []
        XCTAssertEqual(spool.drain(limit: 4) { first.append($0); return true }, 4)
        XCTAssertEqual(spool.count, 6)

        var rest: [LiveOutbound] = []
        _ = spool.drain { rest.append($0); return true }
        XCTAssertEqual(first + rest, (0..<10).map { .text("frame \($0)") })
    }

    /// `byteCount` is adjusted by subtraction now rather than recomputed; the
    /// arithmetic still has to come out right.
    func testByteAccountingSurvivesAPartialDrain() throws {
        let spool = makeSpool()
        for index in 0..<6 { try spool.append(.text("frame \(index)")) }
        let full = spool.byteCount

        _ = spool.drain(limit: 2) { _ in true }
        XCTAssertGreaterThan(spool.byteCount, 0)
        XCTAssertLessThan(spool.byteCount, full)

        _ = spool.drain { _ in true }
        XCTAssertEqual(spool.byteCount, 0, "an empty spool must cost nothing")
    }

    func testAdoptingTheSameSessionKeepsTheBacklog() throws {
        let spool = makeSpool()
        spool.adopt(sessionID: "L1")
        try spool.append(.text("still ours"))
        spool.adopt(sessionID: "L1")
        XCTAssertEqual(spool.count, 1, "a reconnect to the same session must not discard the queue")
    }

    // MARK: - The bound

    /// §8: past the bound, capture STOPS loudly. It must not silently drop, because
    /// the bound exists in order to be noticed.
    func testCrossingTheBoundThrowsRatherThanDroppingSilently() throws {
        let spool = makeSpool(limit: 200)
        var appended = 0
        do {
            for _ in 0..<100 {
                try spool.append(.binary(Data(repeating: 0x41, count: 64)))
                appended += 1
            }
            XCTFail("the spool accepted more than its bound")
        } catch let failure as LiveSpoolError {
            guard case .full(let bytes, let limit) = failure else {
                return XCTFail("expected .full, got \(failure)")
            }
            XCTAssertEqual(limit, 200)
            XCTAssertLessThanOrEqual(bytes, 200)
        }
        XCTAssertGreaterThan(appended, 0, "it must accept something before refusing")
        XCTAssertEqual(spool.count, appended, "the refused frame must not have been kept")
    }

    func testFillReportsHowCloseTheSpoolIsToStopping() throws {
        let spool = makeSpool(limit: 1000)
        XCTAssertEqual(spool.fill, 0)
        try spool.append(.binary(Data(repeating: 0, count: 300)))
        XCTAssertGreaterThan(spool.fill, 0.3)
        XCTAssertLessThanOrEqual(spool.fill, 1)
    }

    func testTheBoundFailureSaysBothNumbersSoTheMessageIsActionable() {
        let message = LiveSpoolError.full(bytes: 5 * 1024 * 1024,
                                          limit: 48 * 1024 * 1024).errorDescription ?? ""
        XCTAssertTrue(message.contains("5.0 MB"), message)
        XCTAssertTrue(message.contains("48"), message)
    }

    func testResetClearsBothMemoryAndDisk() throws {
        let spool = makeSpool()
        spool.adopt(sessionID: "L1")
        try spool.append(.text("gone"))
        spool.reset()
        XCTAssertTrue(spool.isEmpty)
        XCTAssertTrue(makeSpool().isEmpty, "the reset must reach the file too")
    }

    // MARK: - The codec the queued audio is in

    /// The codec is declared once per socket, so it has to survive a relaunch with
    /// the records it describes — otherwise the next launch cannot tell whether the
    /// bytes it is about to drain are Opus packets or raw samples.
    func testTheCodecSurvivesARelaunchWithItsRecords() throws {
        let first = makeSpool()
        first.adopt(sessionID: "L1")
        first.adopt(codec: "opus-packets")
        try first.append(.binary(Data([1, 2, 3])))

        let recovered = makeSpool()
        XCTAssertEqual(recovered.codec, "opus-packets")
        XCTAssertEqual(recovered.count, 1)
    }

    /// **Never label PCM as Opus.** A launch that cannot build an encoder, holding a
    /// backlog the previous launch encoded, must not drain it under a PCM label. The
    /// bytes are set aside under their own codec, not deleted.
    func testChangingCodecSetsTheOtherEncodingsBacklogAsideRatherThanSendingIt() throws {
        let spool = makeSpool()
        spool.adopt(sessionID: "L1")
        spool.adopt(codec: "opus-packets")
        try spool.append(.binary(Data([9, 9, 9])))
        XCTAssertEqual(spool.count, 1)

        spool.adopt(codec: "pcm16")

        XCTAssertTrue(spool.isEmpty, "opus records must not go up as pcm16")
        XCTAssertEqual(spool.codec, "pcm16")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(kept.contains { $0.contains("codec-opus-packets") },
                      "the audio must be recoverable, not destroyed: \(kept)")
    }

    /// Adopting the SAME codec is the ordinary case — every start does it — and must
    /// keep the backlog it is about to drain.
    func testAdoptingTheSameCodecKeepsTheBacklog() throws {
        let spool = makeSpool()
        spool.adopt(codec: "opus-packets")
        try spool.append(.binary(Data([1])))
        spool.adopt(codec: "opus-packets")
        XCTAssertEqual(spool.count, 1)
    }

    /// The first adopt on a fresh spool has nothing to compare against, so whatever
    /// was captured before the codec was known (the opening of a recording) is kept.
    func testTheFirstCodecAdoptKeepsWhatWasAlreadyCaptured() throws {
        let spool = makeSpool()
        try spool.append(.binary(Data([4, 5])))
        spool.adopt(codec: "opus-packets")
        XCTAssertEqual(spool.count, 1)
        XCTAssertEqual(spool.codec, "opus-packets")
    }

    /// A file written before the codec header existed holds PCM16 — that is history,
    /// not a guess, because it is all this app has ever queued. Reading it as
    /// untagged would let an Opus launch adopt those samples silently.
    func testAFileFromBeforeTheCodecHeaderIsReadAsPCM() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = LiveSpool.encode(.binary(Data([7, 7, 7])))
        try "S L1\n\(line)\n".write(to: directory.appendingPathComponent("outbox.log"),
                                    atomically: true, encoding: .utf8)

        let spool = makeSpool()
        XCTAssertEqual(spool.count, 1)
        XCTAssertEqual(spool.codec, "pcm16")
    }

    /// A reset spool is a fresh one: it must not carry the last recording's codec
    /// into the next, or the first adopt would compare against a stale value.
    func testResetLeavesTheSpoolWithoutACodec() throws {
        let spool = makeSpool()
        spool.adopt(codec: "opus-packets")
        try spool.append(.binary(Data([1])))
        spool.reset()
        XCTAssertEqual(spool.codec, "")
    }
}
