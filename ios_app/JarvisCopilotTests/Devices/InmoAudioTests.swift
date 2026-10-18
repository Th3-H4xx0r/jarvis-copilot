import XCTest
@testable import JarvisCopilot

final class InmoAudioTests: XCTestCase {
    @MainActor func testDisablingWakePersistsAcrossChannelRecreation() async {
        let name = "inmo-voice-preference-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: InmoAIChannel.enabledPreference)
        let channel = InmoAIChannel(defaults: defaults)
        await channel.setEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: InmoAIChannel.enabledPreference))
        let recreated = InmoAIChannel(defaults: defaults)
        XCTAssertFalse(recreated.enabled)
    }

    func testRawOpusSilenceDecodesToMonoPCM16() throws {
        // RFC 6716's interoperable Opus silence packet. Generated/public fixture,
        // never an owner's recording. Success requires actual decoded frames.
        let decoder = try InmoOpusDecoder()
        let packet = Data([0xf8, 0xff, 0xfe])
        var pcm = Data()
        for _ in 0..<10 { pcm.append(try decoder.decode(packet)) }
        XCTAssertGreaterThan(pcm.count, 5000)
        XCTAssertEqual(pcm.count % 2, 0)
        XCTAssertLessThan(voicePeakAmplitude(pcm), 0.01)
    }
    func testRawOpusRejectsUnboundedAndEmptyPackets() throws {
        let decoder = try InmoOpusDecoder()
        XCTAssertThrowsError(try decoder.decode(Data()))
        XCTAssertThrowsError(try decoder.decode(Data(repeating: 0, count: 1276)))
    }
    @MainActor
    func testAIRenderHandlersAreInstalledWhileTakeoverIsOff() throws {
        InmoAIChannel.shared.install(on: InmoGo3Device.shared)
        XCTAssertNotNil(InmoGo3Device.shared.featureHandlers["glasses_show_transcription"])
        XCTAssertNotNil(InmoGo3Device.shared.featureHandlers["glasses_show_answer"])
        let result = try InmoAIChannel.renderArguments(["text": "Five", "final": true])
        XCTAssertEqual(result.0, "Five")
        XCTAssertTrue(result.1)
        XCTAssertThrowsError(try InmoAIChannel.renderArguments(["text": "Five", "final": "true"]))
        XCTAssertThrowsError(try InmoAIChannel.renderArguments(["text": ""]))
    }
    @MainActor
    func testAIFramesUnwrapOnlyFirstOpusStream() throws {
        let header = InmoWireCodec.uint(1, 16000) + InmoWireCodec.uint(2, 1) + InmoWireCodec.uint(4, 2)
        let left = Data([0xf8, 0xff, 0xfe]) // public Opus silence
        let right = Data([0xf8, 0xff, 0xfe, 0x00])
        let wrapped = Data([0, 0, 0, 3, 0, 0, 0, 0]) + left
            + Data([0, 0, 0, 4, 0, 0, 0, 0]) + right
        let audio = InmoWireCodec.bytes(1, header) + InmoWireCodec.uint(3, UInt64(wrapped.count))
            + InmoWireCodec.bytes(4, wrapped) + InmoWireCodec.bytes(5, Data([0, UInt8(wrapped.count)]))
        let (packets, lengths) = try InmoAIChannel.audioPayload(InmoWireCodec.decode(audio))
        XCTAssertEqual(packets, left, "wrapper and second stream must never enter the Opus decoder")
        XCTAssertEqual(lengths, [3])
    }

    @MainActor
    func testCapturedZeroLengthPrefixAndPackedBoundaries() throws {
        let header = InmoWireCodec.uint(1, 16000) + InmoWireCodec.uint(2, 1) + InmoWireCodec.uint(4, 2)
        let packet = Data([0xf8, 0xff, 0xfe])
        let frame = Data([0, 0, 0, 3, 0, 0, 0, 1]) + packet
            + Data([0, 0, 0, 3, 0, 0, 0, 2]) + packet
        let opus = frame + frame
        let audio = InmoWireCodec.bytes(1, header) + InmoWireCodec.uint(3, 44)
            + InmoWireCodec.bytes(4, opus) + InmoWireCodec.bytes(5, Data([0, 22, 22]))
        let result = try InmoAIChannel.audioPayload(InmoWireCodec.decode(audio))
        XCTAssertEqual(result.0, packet + packet)
        XCTAssertEqual(result.1, [3, 3])
        let invalid = InmoWireCodec.bytes(1, header) + InmoWireCodec.uint(3, 44)
            + InmoWireCodec.bytes(4, opus) + InmoWireCodec.bytes(5, Data([0, 21, 22]))
        XCTAssertThrowsError(try InmoAIChannel.audioPayload(InmoWireCodec.decode(invalid)))
    }
    @MainActor
    func testAIRejectsTruncatedOrInvalidInnerLengths() throws {
        let header = InmoWireCodec.uint(1, 16000) + InmoWireCodec.uint(2, 1) + InmoWireCodec.uint(4, 2)
        let packet = Data([0xf8, 0xff, 0xfe])
        let valid = Data([0, 0, 0, 3, 0, 0, 0, 0]) + packet
            + Data([0, 0, 0, 3, 0, 0, 0, 0]) + packet
        var zeroFirst = valid; zeroFirst[3] = 0
        var hugeFirst = valid; hugeFirst[0] = 255
        var hugeSecond = valid; hugeSecond[11] = 255
        for bad in [Data(valid.dropLast()), valid + Data([0]), zeroFirst, hugeFirst, hugeSecond] {
            let audio = InmoWireCodec.bytes(1, header) + InmoWireCodec.uint(3, UInt64(bad.count))
                + InmoWireCodec.bytes(4, bad) + InmoWireCodec.uint(5, UInt64(bad.count))
            XCTAssertThrowsError(try InmoAIChannel.audioPayload(InmoWireCodec.decode(audio)))
        }
    }

    @MainActor
    func testWearableInputHasNoPhoneFallbackAndStopsDelivery() async throws {
        let input = InmoAudioInput()
        var frames: [Data] = []
        input.onFrame = { frames.append($0) }
        let pcm = Data([1, 0, 2, 0])
        input.receive(pcm)
        XCTAssertTrue(frames.isEmpty)
        try await input.start(sampleRate: 16000)
        input.receive(pcm)
        await input.stop()
        input.receive(pcm)
        XCTAssertEqual(frames, [pcm])
    }

    /// With the glasses away, a failed reconnect used to retry 2 s later forever (a connect waits
    /// 20 s): every ~22 s all night, each state change re-sending the phone's skill list.
    /// With the glasses out of reach, any caller (a lens card, the keepalive, a workout) started a
    /// new 20 s connect the moment the last one failed: every ~21 s for an hour (Oct 17).
    @MainActor
    func testControlConnectsBackOffAfterFailuresToFiveMinutes() {
        XCTAssertEqual(InmoSession.retryDelay(after: 1), 15)
        XCTAssertEqual(InmoSession.retryDelay(after: 2), 30)
        XCTAssertEqual(InmoSession.retryDelay(after: 4), 120)
        XCTAssertEqual(InmoSession.retryDelay(after: 6), 300)
        XCTAssertEqual(InmoSession.retryDelay(after: 500), 300)
    }

    @MainActor
    func testAIReconnectsBackOffToFiveMinutes() {
        XCTAssertEqual(InmoAIChannel.reconnectDelay(after: 0), 2)
        XCTAssertEqual(InmoAIChannel.reconnectDelay(after: 1), 4)
        XCTAssertEqual(InmoAIChannel.reconnectDelay(after: 6), 128)
        XCTAssertEqual(InmoAIChannel.reconnectDelay(after: 8), 300)
        XCTAssertEqual(InmoAIChannel.reconnectDelay(after: 500), 300)
        XCTAssertTrue(InmoAIChannel.isDown(.failed))
        XCTAssertTrue(InmoAIChannel.isDown(.disconnected))
        XCTAssertFalse(InmoAIChannel.isDown(.connecting))
        XCTAssertFalse(InmoAIChannel.isDown(.ready))
    }
}
