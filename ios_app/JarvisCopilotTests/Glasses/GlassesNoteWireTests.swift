import XCTest
@testable import JarvisCopilot

/// Goldens are the official INMO app's own bytes from the 2026-09-27 note captures
/// (docs/glasses/go3-ai-notes.md).
@MainActor
final class GlassesNoteWireTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        let text = hex.filter { !$0.isWhitespace }; var result = Data(); var i = text.startIndex
        while i < text.endIndex { let end = text.index(i, offsetBy: 2); result.append(UInt8(text[i..<end], radix: 16)!); i = end }; return result
    }
    private func parse(_ hex: String) throws -> GlassesNoteWire.Event? {
        let fields = try InmoWireCodec.decode(data(hex))
        return try GlassesNoteWire.parse(type: Int(fields.firstField(2)?.varint ?? 0), fields: fields)
    }

    func testStartMatchesTheOfficialApp() {
        XCTAssertEqual(GlassesNoteWire.start(audioTimeMs: 1790549761235), [
            data("1011a201024200"), data("100c7a070804320308e807"), data("100f9201020805"),
            data("100c7a0d08022209080120d3b9d4a88e34")])
    }

    func testRecordingMessagesMatchTheOfficialApp() {
        XCTAssertEqual(GlassesNoteWire.elapsed(seconds: 0), data("100c7a0408053a00"))
        XCTAssertEqual(GlassesNoteWire.elapsed(seconds: 7), data("100c7a0608053a020807"))
        XCTAssertEqual(GlassesNoteWire.transcript("OK OK yeah", final: false), data("100c7a1008011a0c0a0a4f4b204f4b2079656168"))
        XCTAssertEqual(GlassesNoteWire.photoReceived(), data("100c7a06080222022801"))
        XCTAssertEqual(GlassesNoteWire.phonePhotoCount(1), data("100c7a06080222023001"))
        XCTAssertEqual(GlassesNoteWire.stop(), [data("100c7a021001"), data("100f92010408051001")])
    }

    func testAFinalSentenceCarriesIsFinish() throws {
        let fields = try InmoWireCodec.decode(GlassesNoteWire.transcript("Done.", final: true))
        let asr = try XCTUnwrap(fields.firstField(15)?.nested().firstField(3)?.nested())
        XCTAssertEqual(asr.firstField(2)?.varint, 1)
    }

    func testGlassesAppOpenAndCloseParse() throws {
        XCTAssertEqual(try parse("100f9201020805"), .opened)
        XCTAssertEqual(try parse("100f92010408051001"), .closed)
        XCTAssertNil(try parse("100f92010408081001"))   // voice subtitles, not notes
        XCTAssertEqual(try parse("100c7a021001"), .stopRequested)
    }

    func testAGlassesPhotoParsesWithItsName() throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9])
        let content = InmoWireCodec.bytes(2, jpeg) + InmoWireCodec.string(3, "1790549761235_11995")
        let message = InmoCommand.envelope(type: 12, field: 15, payload: InmoWireCodec.uint(1, 2) + InmoWireCodec.bytes(4, content))
        let fields = try InmoWireCodec.decode(message)
        XCTAssertEqual(try GlassesNoteWire.parse(type: 12, fields: fields), .photo(jpeg: jpeg, name: "1790549761235_11995"))
        XCTAssertEqual(GlassesNoteWire.photoOffsetMs("1790549761235_11995"), 11995)
        XCTAssertNil(GlassesNoteWire.photoOffsetMs("nounderscore"))
    }

    /// Notes audio: AUDIO_TYPE 3, each frame two opus_demo-framed packets
    /// (BE32 length, 4 opaque bytes, packet); only the first stream is speech.
    func testNotesAudioKeepsTheFirstStream() throws {
        func framed(_ packet: [UInt8]) -> Data {
            Data([0, 0, 0, UInt8(packet.count)]) + Data([1, 0, 0, 0]) + Data(packet)
        }
        let speech: [UInt8] = [0xb0, 0x11, 0x22, 0x33]
        let quiet: [UInt8] = [0xb0, 0xff, 0xfe]
        let frame = framed(speech) + framed(quiet)
        let payload = frame + frame + frame
        let header = InmoWireCodec.uint(1, 16000) + InmoWireCodec.uint(2, 1) + InmoWireCodec.uint(3, 256000) + InmoWireCodec.uint(4, 3)
        let lengths = InmoWireCodec.varint(UInt64(frame.count)) + InmoWireCodec.varint(UInt64(frame.count)) + InmoWireCodec.varint(UInt64(frame.count))
        let audio = InmoWireCodec.bytes(1, header) + InmoWireCodec.uint(3, UInt64(payload.count)) + InmoWireCodec.bytes(4, payload) + InmoWireCodec.bytes(5, lengths)
        let message = InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3, audio)
        let fields = try InmoWireCodec.decode(message)
        XCTAssertEqual(try GlassesNoteWire.parse(type: 0, fields: fields), .audio([Data(speech), Data(speech), Data(speech)]))
        // The AI assistant's parser still refuses notes audio.
        let decoded = try XCTUnwrap(fields.firstField(3)?.nested())
        XCTAssertThrowsError(try InmoAIChannel.audioPayload(decoded))
    }

    func testTheLensGetsTheGrowingSentenceThenItsFinalForm() {
        var lens = GlassesNoteLens()
        XCTAssertEqual(lens.update("ok ok"), [.init(text: "ok ok", final: false)])
        XCTAssertEqual(lens.update("ok ok"), [])
        XCTAssertEqual(lens.update("OK, OK. Remind me"), [.init(text: "OK, OK.", final: true), .init(text: "Remind me", final: false)])
        XCTAssertEqual(lens.update("OK, OK. Remind me to buy milk"), [.init(text: "Remind me to buy milk", final: false)])
        XCTAssertEqual(lens.finish("OK, OK. Remind me to buy milk tomorrow"), [.init(text: "Remind me to buy milk tomorrow", final: true)])
        XCTAssertEqual(lens.finish("OK, OK. Remind me to buy milk tomorrow"), [])
    }

    func testALongUnpunctuatedRunIsCutForTheLens() {
        var lens = GlassesNoteLens()
        let run = Array(repeating: "word", count: 40).joined(separator: " ")
        let lines = lens.update(run)
        XCTAssertTrue(lines.first?.final ?? false)
        XCTAssertLessThanOrEqual(lines.first?.text.count ?? 0, GlassesNoteLens.maxLine + 8)
    }

    func testPhotosSitBetweenTheSentencesTheyWereTakenIn() {
        let note = GlassesNote(id: "1", createdAt: Date(), duration: 30, title: "t", text: "a b",
                               segments: [.init(ms: 1000, text: "a"), .init(ms: 20000, text: "b")],
                               photos: [.init(id: "1_12000", ms: 12000, file: "1_12000.jpg", fullSize: false, source: .glasses)],
                               summary: nil, chatSessionID: nil)
        XCTAssertEqual(note.timeline.map(\.id), ["t1000-\("a".hashValue)", "p1_12000", "t20000-\("b".hashValue)"])
    }

    func testTheSummaryReplySplitsIntoTitleAndBody() {
        let (title, body) = GlassesNoteFinisher.parse("Title: Groceries\n\n- Buy milk\n- [ ] Call mum")
        XCTAssertEqual(title, "Groceries")
        XCTAssertEqual(body, "- Buy milk\n- [ ] Call mum")
        let (none, whole) = GlassesNoteFinisher.parse("Just a summary.")
        XCTAssertNil(none)
        XCTAssertEqual(whole, "Just a summary.")
        XCTAssertEqual(GlassesNoteFinisher.parse("**Title:** Standup\nNotes").0, "Standup")
    }

    // MARK: INMEET (SageNote) — goldens from the 2026-11-11 call-recording capture

    /// INMEET opens through STARTING_APPLICATION switchApp 15, the same message the glasses use
    /// (`15 18{1=15}`), NOT the AI-assistant app-switch the lens rejects as "not installed".
    func testInmeetOpensThroughStartingApplication() {
        XCTAssertEqual(GlassesSageNoteWire.open(), data("100f920102080f"))
        XCTAssertEqual(GlassesSageNoteWire.close(), data("100f920104080f1001"))
        XCTAssertNotEqual(GlassesSageNoteWire.open(), InmoCommand.aiSwitchApplication(15, open: true))
    }

    func testInmeetAppStateParsesTheGlassesEcho() throws {
        let opened = try InmoWireCodec.decode(data("0801100f920102080f"))
        let closed = try InmoWireCodec.decode(data("0801100f920104080f1001"))
        let notes = try InmoWireCodec.decode(data("100f9201020805"))
        XCTAssertEqual(GlassesSageNoteWire.appState(type: 15, fields: opened), true)
        XCTAssertEqual(GlassesSageNoteWire.appState(type: 15, fields: closed), false)
        XCTAssertNil(GlassesSageNoteWire.appState(type: 15, fields: notes))
    }

    func testInmeetStateMatchesTheOfficialApp() {
        XCTAssertEqual(GlassesSageNoteWire.state(sessionId: "mt-1794410621786-3", elapsedSeconds: 44, nowMs: 1794432267903),
                       data("102bf2022708031a126d742d313739343431303632313738362d3320ffecfde39c346a08080110011801202c"))
    }

    func testInmeetConfigMatchesTheOfficialApp() {
        XCTAssertEqual(GlassesSageNoteWire.config(sessionId: "mt-1794410790171-2", revision: 69, language: "en",
                                                  nowMs: 1794432399832, commandId: "EFC1CD88-A8AC-49D6-9C63-CE419ECB8AA4"),
                       data("102bf202590807122445464331434438382d413841432d343944362d394336332d4345343139454342384141341a126d742d313739343431303739303137312d3220d8f385e49c348a011308ff011202656e1a02656e2801380140456001"))
    }

    /// The companion-app declaration the firmware gates INMEET on: BLE_CONNECT_BIND(24) / field 27,
    /// BleConnectBind{msgType PHONE_INFO(7), phoneInfo(7): {appVersion "3.0.0", phoneType IOS(2)}}.
    func testPhoneInfoDeclaresTheIOSCompanionApp() {
        XCTAssertEqual(InmoCommand.phoneInfo(), data("08011018da010d08073a090a05332e302e301002"))
    }

    func testInmeetStartAndStopCommands() {
        XCTAssertTrue(GlassesSageNoteWire.isStart(0)); XCTAssertTrue(GlassesSageNoteWire.isStart(2))
        XCTAssertTrue(GlassesSageNoteWire.isStop(1)); XCTAssertTrue(GlassesSageNoteWire.isStop(3))
        XCTAssertFalse(GlassesSageNoteWire.isStart(4)); XCTAssertFalse(GlassesSageNoteWire.isStop(5))
    }
}
