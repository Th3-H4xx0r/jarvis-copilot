import XCTest
@testable import JarvisCopilot

/// The wire format, both directions. These are the rules the server half is being
/// written against, so they are pinned as contracts rather than snapshots.
final class LiveProtocolTests: XCTestCase {

    // MARK: - Hello

    func testHelloCarriesTheDeclaredCapsAndDeviceKind() throws {
        let caps = LiveCaps(stt: "on_device")
        let message = LiveClientMessage.hello(deviceID: "iphone-17pm", caps: caps, resume: nil)
        let json = try object(message)

        XCTAssertEqual(json["t"] as? String, "hello")
        XCTAssertEqual(json["device_id"] as? String, "iphone-17pm")
        XCTAssertEqual(json["device_kind"] as? String, "ios")
        let sent = try XCTUnwrap(json["caps"] as? [String: Any])
        XCTAssertEqual(sent["stt"] as? String, "on_device")
        XCTAssertEqual(sent["audio"] as? String, "stream")
        XCTAssertEqual(sent["text"] as? String, "stream")
        XCTAssertEqual(sent["rate"] as? Int, 16000)
        XCTAssertEqual(sent["speak"] as? Bool, true)
        XCTAssertNil(json["resume"], "a first connection must not claim to be resuming")
    }

    /// The embedding phase has not started, so declaring anything but "none" would
    /// earn the edge lane and then feed the server no vectors.
    func testHelloNeverClaimsAnOnDeviceEmbedder() throws {
        let json = try object(.hello(deviceID: "d", caps: LiveCaps(stt: "on_device"), resume: nil))
        let caps = try XCTUnwrap(json["caps"] as? [String: Any])
        XCTAssertEqual(caps["embed"] as? String, "none")
        XCTAssertEqual(caps["embed_model"] as? String, "")
    }

    /// The codec declared has to be what the phone can actually produce, so the
    /// DEFAULT is the one it can always send. `LiveStore` raises it to
    /// `opus-packets` only once it holds a working encoder.
    func testHelloDeclaresTheCodecItCanActuallySend() throws {
        let json = try object(.hello(deviceID: "d", caps: LiveCaps(stt: "none"), resume: nil))
        let caps = try XCTUnwrap(json["caps"] as? [String: Any])
        XCTAssertEqual(caps["codec"] as? String, "pcm16")
    }

    func testHelloCarriesResumeWhenThereIsACursor() throws {
        let resume = LiveResume(liveSessionID: "sess-1", afterSeq: 4417)
        let json = try object(.hello(deviceID: "d", caps: LiveCaps(stt: "none"), resume: resume))
        let sent = try XCTUnwrap(json["resume"] as? [String: Any])
        XCTAssertEqual(sent["live_session_id"] as? String, "sess-1")
        XCTAssertEqual(sent["after_seq"] as? Int, 4417)
    }

    func testSegmentFrameIsAlwaysFinal() throws {
        let json = try object(.segment(startMs: 1200, endMs: 3400, text: "hello there",
                                       lang: "en-US", localLabel: "me"))
        XCTAssertEqual(json["t"] as? String, "seg")
        XCTAssertEqual(json["partial"] as? Bool, false)
        XCTAssertEqual(json["ts_start_ms"] as? Int, 1200)
        XCTAssertEqual(json["ts_end_ms"] as? Int, 3400)
        XCTAssertEqual(json["text"] as? String, "hello there")
        XCTAssertEqual(json["lang"] as? String, "en-US")
        XCTAssertEqual(json["local_label"] as? String, "me")
    }

    // MARK: - Binary framing

    /// `[4B big-endian seq][8B big-endian ts_ms][payload]`. Big-endian is the part
    /// worth a test: little-endian is what both ends would reach for by default.
    func testAudioFrameHeaderIsTwelveBigEndianBytes() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let frame = LiveAudioFrame.encode(seq: 0x01020304, tsMs: 0x0102030405060708, payload: payload)

        XCTAssertEqual(frame.count, 12 + payload.count)
        XCTAssertEqual(Array(frame.prefix(4)), [0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(Array(frame[4..<12]), [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        XCTAssertEqual(frame.suffix(3), payload)
    }

    func testAudioFrameRoundTrips() throws {
        let payload = Data(repeating: 0x7F, count: 320)
        let frame = LiveAudioFrame.encode(seq: 9, tsMs: 123_456, payload: payload)
        let decoded = try XCTUnwrap(LiveAudioFrame.decode(frame))
        XCTAssertEqual(decoded.seq, 9)
        XCTAssertEqual(decoded.tsMs, 123_456)
        XCTAssertEqual(decoded.payload, payload)
    }

    /// A `Data` sliced out of a file does not start at index 0. Decoding from a
    /// hardcoded 0 works on a freshly built frame and crashes on a replayed one.
    func testAudioFrameDecodesADataSliceWithANonZeroStartIndex() throws {
        let frame = LiveAudioFrame.encode(seq: 5, tsMs: 900, payload: Data([1, 2, 3]))
        let padded = Data([0xFF, 0xFF]) + frame
        let slice = padded[2...]
        XCTAssertNotEqual(slice.startIndex, 0, "the slice must not be zero-based for this to test anything")

        let decoded = try XCTUnwrap(LiveAudioFrame.decode(slice))
        XCTAssertEqual(decoded.seq, 5)
        XCTAssertEqual(decoded.tsMs, 900)
        XCTAssertEqual(decoded.payload, Data([1, 2, 3]))
    }

    func testTruncatedAudioFrameIsRejectedRatherThanRead() {
        XCTAssertNil(LiveAudioFrame.decode(Data(repeating: 0, count: 11)))
    }

    // MARK: - Server frames

    func testReadyIsDecodedIncludingServerCaps() throws {
        let frame = LiveServerFrame.decode(object: [
            "t": "ready", "live_session_id": "L1", "chat_session_id": "C1",
            "seq": 42, "lane": "edge",
            "server_caps": ["stt": true, "embed": true, "embed_model": "ecapa-v1"],
        ])
        guard case .ready(let ready) = frame else { return XCTFail("expected ready, got \(frame)") }
        XCTAssertEqual(ready.liveSessionID, "L1")
        XCTAssertEqual(ready.chatSessionID, "C1")
        XCTAssertEqual(ready.seq, 42)
        XCTAssertEqual(ready.lane, .edge)
        XCTAssertTrue(ready.serverSTT)
        XCTAssertEqual(ready.serverEmbedModel, "ecapa-v1")
    }

    /// An unknown lane must read as `server`: a device that wrongly thinks it is on
    /// the edge lane stops sending the audio the server would need itself.
    func testAnUnknownLaneFallsBackToTheServerLane() {
        XCTAssertEqual(LiveLane.parse("turbo"), .server)
        XCTAssertEqual(LiveLane.parse(nil), .server)
        XCTAssertEqual(LiveLane.parse("edge"), .edge)
    }

    func testSegmentDecodesEveryContractField() throws {
        let frame = LiveServerFrame.decode(object: [
            "t": "seg", "seq": 7, "ts_start_ms": 100, "ts_end_ms": 900,
            "speaker_id": "sp-3", "speaker_name": "Ada", "speaker_conf": 0.91,
            "label_state": "confirmed", "text": "the meeting is at four",
            "lang": "en-US", "translation": "la reunión es a las cuatro",
        ])
        guard case .segment(let s) = frame else { return XCTFail("expected seg, got \(frame)") }
        XCTAssertEqual(s.seq, 7)
        XCTAssertEqual(s.startMs, 100)
        XCTAssertEqual(s.endMs, 900)
        XCTAssertEqual(s.speakerID, "sp-3")
        XCTAssertEqual(s.speakerName, "Ada")
        XCTAssertEqual(s.speakerConf ?? 0, 0.91, accuracy: 0.0001)
        XCTAssertEqual(s.labelState, .confirmed)
        XCTAssertEqual(s.translation, "la reunión es a las cuatro")
    }

    /// An empty string from the server means "not set". Keeping it would draw an
    /// empty speaker chip and an empty translation line under every row.
    func testEmptyStringsDecodeAsAbsentRatherThanBlank() throws {
        let frame = LiveServerFrame.decode(object: [
            "t": "seg", "seq": 1, "speaker_id": "", "translation": "  ", "speaker_name": "",
        ])
        guard case .segment(let s) = frame else { return XCTFail("expected seg") }
        XCTAssertNil(s.speakerID)
        XCTAssertNil(s.translation)
        XCTAssertNil(s.speakerName)
    }

    func testAnUnlabelledSegmentIsProvisionalByDefault() throws {
        let frame = LiveServerFrame.decode(object: ["t": "seg", "seq": 1])
        guard case .segment(let s) = frame else { return XCTFail("expected seg") }
        XCTAssertEqual(s.labelState, .provisional)
    }

    func testMergeReadsTheFoldedIdsFromEitherSpelling() throws {
        guard case .speaker(let a) = LiveServerFrame.decode(object: [
            "t": "speaker", "op": "merge", "into": "sp-1", "from": ["sp-4", "sp-9"],
        ]) else { return XCTFail("expected speaker") }
        XCTAssertEqual(a.op, .merge)
        XCTAssertEqual(a.speakerID, "sp-1")
        XCTAssertEqual(a.mergedFrom, ["sp-4", "sp-9"])

        // `ids` minus the survivor is the other way the server may express it.
        guard case .speaker(let b) = LiveServerFrame.decode(object: [
            "t": "speaker", "op": "merge", "speaker_id": "sp-1", "ids": ["sp-1", "sp-7"],
        ]) else { return XCTFail("expected speaker") }
        XCTAssertEqual(b.mergedFrom, ["sp-7"], "the survivor must not be in its own merge list")

        // A single `from` string, not an array.
        guard case .speaker(let c) = LiveServerFrame.decode(object: [
            "t": "speaker", "op": "merge", "speaker_id": "sp-2", "from": "sp-5",
        ]) else { return XCTFail("expected speaker") }
        XCTAssertEqual(c.mergedFrom, ["sp-5"])
    }

    func testErrorReadsEitherFieldName() throws {
        guard case .error(let a) = LiveServerFrame.decode(object: ["t": "error", "error": "nope"])
        else { return XCTFail("expected error") }
        XCTAssertEqual(a, "nope")
        guard case .error(let b) = LiveServerFrame.decode(object: ["t": "error", "message": "bad"])
        else { return XCTFail("expected error") }
        XCTAssertEqual(b, "bad")
    }

    /// A frame type this client does not know must stay visible, not vanish — a
    /// dropped frame is indistinguishable from a dead socket.
    func testAnUnknownFrameTypeIsKeptAsUnknown() {
        guard case .unknown(let kind) = LiveServerFrame.decode(object: ["t": "hologram"])
        else { return XCTFail("expected unknown") }
        XCTAssertEqual(kind, "hologram")
    }

    func testTypeIsAcceptedAsAnAliasForT() {
        guard case .state = LiveServerFrame.decode(object: ["type": "state", "recording": true])
        else { return XCTFail("the app's other sockets spell the discriminator `type`") }
    }

    func testNonJSONTextIsRejectedRatherThanGuessedAt() {
        XCTAssertNil(LiveServerFrame.decode(text: "not json at all"))
    }

    // MARK: - Display

    /// A speaker's number must be stable for the whole session. Numbering by order
    /// of appearance renumbers everyone the moment a merge lands.
    func testSpeakerLabelIsStableForAnIDAndPrefersARealName() {
        XCTAssertEqual(LiveFormat.speakerLabel(id: "sp-3", name: "Ada"), "Ada")
        XCTAssertEqual(LiveFormat.speakerLabel(id: "sp-3", name: nil), "Speaker 3")
        XCTAssertEqual(LiveFormat.speakerLabel(id: "sp-3", name: ""), "Speaker 3")
        let first = LiveFormat.speakerLabel(id: "abcdef", name: nil)
        XCTAssertEqual(first, LiveFormat.speakerLabel(id: "abcdef", name: nil))
        XCTAssertEqual(LiveFormat.speakerLabel(id: nil, name: nil), "Unknown speaker")
    }

    func testStampIsRelativeToTheRecordingNotTheWallClock() {
        XCTAssertEqual(LiveFormat.stamp(ms: 0), "0:00")
        XCTAssertEqual(LiveFormat.stamp(ms: 65_000), "1:05")
        XCTAssertEqual(LiveFormat.stamp(ms: 3_725_000), "1:02:05")
        XCTAssertEqual(LiveFormat.stamp(ms: -5), "0:00")
    }

    func testByteFormattingReadsLikeAPersonWouldSayIt() {
        XCTAssertEqual(LiveFormat.bytes(512), "512 B")
        XCTAssertEqual(LiveFormat.bytes(2048), "2.0 KB")
        XCTAssertEqual(LiveFormat.bytes(150 * 1024), "150 KB")
        XCTAssertEqual(LiveFormat.bytes(5 * 1024 * 1024), "5.0 MB")
    }

    // MARK: - The wrap-up rides the insight frame

    /// The artifacts watcher publishes its wrap-up as an `insight` whose `seq`
    /// is null. Read as an ordinary insight that became seq 0 — so the summary
    /// of the whole conversation was filed ABOVE the conversation.
    func testAnArtifactsInsightDecodesAsTheWrapUpWithItsLists() throws {
        let frame = LiveServerFrame.decode(object: [
            "t": "insight",
            "kind": "artifacts",
            "seq": NSNull(),
            "text": "## Conversation wrap-up\n\nThey agreed to ship.",
            "summary": "They agreed to ship.",
            "decisions": ["Ship on Friday", ""],
            "action_items": ["Alan to cut the release"],
        ])
        guard case .wrapUp(let wrap) = frame else {
            return XCTFail("expected a wrap-up, got \(frame)")
        }
        XCTAssertEqual(wrap.summary, "They agreed to ship.")
        XCTAssertEqual(wrap.decisions, ["Ship on Friday"], "blanks are dropped, not bulleted")
        XCTAssertEqual(wrap.actionItems, ["Alan to cut the release"])
    }

    /// `actions` is the other spelling the watcher has used.
    func testTheWrapUpReadsEitherSpellingOfItsActionList() throws {
        let frame = LiveServerFrame.decode(object: [
            "t": "insight", "kind": "artifacts",
            "summary": "s", "actions": ["do the thing"],
        ])
        guard case .wrapUp(let wrap) = frame else {
            return XCTFail("expected a wrap-up, got \(frame)")
        }
        XCTAssertEqual(wrap.actionItems, ["do the thing"])
    }

    /// An ordinary monitor note is still an insight, not a wrap-up.
    func testAMonitorNoteIsStillAnInsight() throws {
        let frame = LiveServerFrame.decode(object: [
            "t": "insight", "kind": "monitor", "seq": 7, "text": "worth noting",
        ])
        guard case .insight(let insight) = frame else {
            return XCTFail("expected an insight, got \(frame)")
        }
        XCTAssertEqual(insight.seq, 7)
        XCTAssertEqual(insight.kind, "monitor")
    }

    // MARK: - A fact-check verdict

    /// `anchor_seq` names the line the claim was judged on, so the card can sit
    /// under that line instead of at the end of everything.
    func testAFactCheckCarriesTheRowItWasAbout() {
        let frame = LiveServerFrame.decode(object: [
            "t": "insight", "kind": "fact_check", "seq": 42,
            "text": "The bridge opened in 1937.", "verdict": "true",
            "anchor_seq": 39,
        ])
        guard case .factCheck(let result) = frame else {
            return XCTFail("expected a fact-check, got \(String(describing: frame))")
        }
        XCTAssertEqual(result.anchorSeq, 39)
    }

    /// Without an anchor the verdict is about a WINDOW. It must not fall back to
    /// `seq`, which every fact-check carries (the last row of the window it
    /// read) — that would pin every verdict under whatever was said last.
    func testAFactCheckWithNoAnchorDoesNotBorrowItsWindowsSeq() {
        let frame = LiveServerFrame.decode(object: [
            "t": "insight", "kind": "fact_check", "seq": 42,
            "text": "Nobody said anything checkable.", "verdict": "unverifiable",
        ])
        guard case .factCheck(let result) = frame else {
            return XCTFail("expected a fact-check, got \(String(describing: frame))")
        }
        XCTAssertNil(result.anchorSeq)
    }

    /// Red means "this claim is false" and nothing else. The verdict is free text
    /// written by a model, so only an unambiguous refutation may colour the card.
    func testOnlyAnExplicitFalseVerdictReadsAsARefutation() {
        for verdict in ["false", "False", " FALSE ", "incorrect", "untrue"] {
            XCTAssertTrue(LiveFactCheckResult(text: "x", verdict: verdict).isRefuted,
                          "\(verdict) should read as a refutation")
        }
        for verdict in ["true", "mixed", "misleading", "unverifiable", "partly false", ""] {
            XCTAssertFalse(LiveFactCheckResult(text: "x", verdict: verdict).isRefuted,
                           "\(verdict) is not a refutation and must not be painted red")
        }
    }

    /// "We couldn't check" and "this is false" are different states, and
    /// conflating them would be worse than having no colour at all.
    func testAFailedCheckIsNeverARefutationAndCarriesNoAnchor() {
        let failed = LiveFactCheckResult.from(
            insightText: "API call failed after 3 retries: HTTP 404: model \"\" not found",
            verdict: "false", sources: [], anchorSeq: 12)
        XCTAssertTrue(failed.failed)
        XCTAssertFalse(failed.isRefuted, "a failure must not read as a refutation")
        XCTAssertNil(failed.anchorSeq, "a check that did not run judged no line")
    }

    /// The loading card is a local state with no text, and `apply` drops results
    /// it considers empty — so "pending" has to survive that guard.
    func testAPendingCheckIsNotTreatedAsAnEmptyResult() {
        let pending = LiveFactCheckResult(pending: true)
        XCTAssertFalse(pending.isEmpty)
        XCTAssertFalse(pending.isRefuted)
        XCTAssertTrue(LiveFactCheckResult().isEmpty)
    }

    // MARK: - Helpers

    private func object(_ message: LiveClientMessage) throws -> [String: Any] {
        let data = Data(message.encoded().utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
