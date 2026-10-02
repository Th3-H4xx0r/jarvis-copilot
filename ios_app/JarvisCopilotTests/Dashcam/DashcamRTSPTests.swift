import CoreMedia
import Network
import VideoToolbox
import XCTest
@testable import JarvisCopilot

/// The dashcam live view's RTSP client: SDP, RTP, depacketizers, access units, sample buffers,
/// and a whole session against a fake camera on 127.0.0.1 streaming VideoToolbox-encoded video.
final class DashcamRTSPTests: XCTestCase {

    // MARK: SDP

    static let h264SDP = """
    v=0\r
    o=- 1 1 IN IP4 192.168.169.1\r
    s=Session streamed by Viidure\r
    c=IN IP4 0.0.0.0\r
    t=0 0\r
    a=control:*\r
    a=range:npt=0-\r
    m=video 0 RTP/AVP 96\r
    a=rtpmap:96 H264/90000\r
    a=fmtp:96 packetization-mode=1;profile-level-id=42C01E;sprop-parameter-sets=Z0LAHtkDxWhAAAADAEAAAAwDxYuS,aMuMsg==\r
    a=control:trackID=0\r
    m=audio 0 RTP/AVP 97\r
    a=rtpmap:97 MPEG4-GENERIC/16000/1\r
    a=control:trackID=1\r

    """

    func testParsesH264SDP() throws {
        let sdp = try XCTUnwrap(DashcamRTSP.parseSDP(Self.h264SDP))
        XCTAssertEqual(sdp.codec, .h264)
        XCTAssertEqual(sdp.payloadType, 96)
        XCTAssertEqual(sdp.clockRate, 90000)
        XCTAssertEqual(sdp.control, "trackID=0", "the video track's control, not the audio's")
        XCTAssertEqual(sdp.sessionControl, "*")
        XCTAssertEqual(sdp.parameterSets.count, 2)
        XCTAssertEqual(sdp.parameterSets.map { DashcamRTSP.nalType($0, codec: .h264) }, [7, 8])
        XCTAssertEqual(sdp.parameterSets[1], Data([0x68, 0xCB, 0x8C, 0xB2]))
    }

    func testParsesH265SDPWithUnpaddedBase64() throws {
        let text = """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=live
        t=0 0
        m=audio 0 RTP/AVP 0
        a=control:rtsp://192.168.169.1:554/live/audio
        m=video 0 RTP/AVP 98
        a=rtpmap:98 H265/90000
        a=fmtp:98 sprop-vps=QAEMAf//AWAAAAMAgAAAAwAAAwBdlZgJ; sprop-sps=QgEBAWAAAAMAgAAAAwAAAwBdoAKAgC0WWVmkkyvAQAAA+kAAF3AC; sprop-pps=RAHBcrRiQA
        a=control:rtsp://192.168.169.1:554/live/video
        """
        let sdp = try XCTUnwrap(DashcamRTSP.parseSDP(text))
        XCTAssertEqual(sdp.codec, .h265)
        XCTAssertEqual(sdp.payloadType, 98)
        XCTAssertEqual(sdp.control, "rtsp://192.168.169.1:554/live/video")
        XCTAssertNil(sdp.sessionControl)
        XCTAssertEqual(sdp.parameterSets.map { DashcamRTSP.nalType($0, codec: .h265) }, [32, 33, 34], "VPS, SPS, PPS in order")
        XCTAssertEqual(sdp.parameterSets[2].count, 7, "unpadded base64 still decodes")
    }

    func testSDPWithoutH26xVideoIsNil() {
        XCTAssertNil(DashcamRTSP.parseSDP("v=0\r\nm=audio 0 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"))
        XCTAssertNil(DashcamRTSP.parseSDP("v=0\r\nm=video 0 RTP/AVP 26\r\na=rtpmap:26 JPEG/90000\r\n"))
    }

    func testResolvesControlURLs() {
        let base = "rtsp://192.168.169.1:554/live/"
        XCTAssertEqual(DashcamRTSP.resolve(control: nil, base: base), base)
        XCTAssertEqual(DashcamRTSP.resolve(control: "*", base: base), base)
        XCTAssertEqual(DashcamRTSP.resolve(control: "trackID=0", base: base), "rtsp://192.168.169.1:554/live/trackID=0")
        XCTAssertEqual(DashcamRTSP.resolve(control: "trackID=0", base: "rtsp://192.168.169.1:554"),
                       "rtsp://192.168.169.1:554/trackID=0")
        XCTAssertEqual(DashcamRTSP.resolve(control: "rtsp://10.0.0.1/v", base: base), "rtsp://10.0.0.1/v")
    }

    func testParsesSessionAndTransportHeaders() {
        let s = DashcamRTSP.parseSession("  66334873;timeout=60")
        XCTAssertEqual(s.id, "66334873")
        XCTAssertEqual(s.timeout, 60)
        XCTAssertEqual(DashcamRTSP.parseSession("ABC").timeout, nil)
        XCTAssertEqual(DashcamRTSP.interleavedChannel("RTP/AVP/TCP;unicast;interleaved=2-3;ssrc=1234"), 2)
        XCTAssertNil(DashcamRTSP.interleavedChannel("RTP/AVP;unicast;client_port=5000-5001"))
    }

    func testDigestAuthorizationMatchesRFC2617() {
        // RFC 2617 §3.5's worked example.
        let challenge = DashcamRTSP.Challenge(header: #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#)
        XCTAssertEqual(challenge?.realm, "testrealm@host.com")
        let header = DashcamRTSP.authorization(challenge!, user: "Mufasa", password: "Circle Of Life",
                                               method: "GET", uri: "/dir/index.html", nc: 1, cnonce: "0a4f113b")
        XCTAssertTrue(header.contains(#"response="6629fae49393a05397450978507c4ef1""#), header)
        XCTAssertTrue(header.contains("qop=auth"), header)
        XCTAssertTrue(header.contains(#"opaque="5ccc069c403ebaf9f0171e9517f40e41""#), header)

        let noQop = DashcamRTSP.Challenge(header: #"Digest realm="testrealm@host.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093""#)!
        XCTAssertTrue(DashcamRTSP.authorization(noQop, user: "Mufasa", password: "Circle Of Life",
                                                method: "GET", uri: "/dir/index.html", nc: 1, cnonce: "x")
                        .contains(#"response="670fd8c2df070c60b045671b8b24ff02""#))

        let basic = DashcamRTSP.Challenge(header: #"Basic realm="cam""#)!
        XCTAssertEqual(DashcamRTSP.authorization(basic, user: "admin", password: "12345", method: "DESCRIBE", uri: "rtsp://x/"),
                       "Basic YWRtaW46MTIzNDU=")
    }

    // MARK: RTP

    func testParsesRTPHeaderWithCSRCExtensionAndPadding() throws {
        var bytes: [UInt8] = [
            0b1011_0010,                 // V=2, P=1, X=1, CC=2
            0x80 | 96,                   // M=1, PT=96
            0xFF, 0xFF,                  // seq 65535
            0x00, 0x01, 0x5F, 0x90,      // ts 90000
            0xDE, 0xAD, 0xBE, 0xEF,      // ssrc
            0, 0, 0, 1, 0, 0, 0, 2,      // two CSRCs
            0xBE, 0xDE, 0x00, 0x01,      // extension, 1 word
            1, 2, 3, 4,
        ]
        bytes += [0x65, 0xAA, 0xBB]     // payload
        bytes += [0, 0, 3]              // 3 bytes of padding
        let p = try XCTUnwrap(RTPPacket.parse(Data(bytes)))
        XCTAssertEqual(p.version, 2)
        XCTAssertTrue(p.marker)
        XCTAssertEqual(p.payloadType, 96)
        XCTAssertEqual(p.sequence, 65535)
        XCTAssertEqual(p.timestamp, 90000)
        XCTAssertEqual(p.ssrc, 0xDEADBEEF)
        XCTAssertEqual(p.payload, Data([0x65, 0xAA, 0xBB]))
        XCTAssertEqual(p.payload.startIndex, 0)
    }

    func testRejectsBadRTP() {
        XCTAssertNil(RTPPacket.parse(Data([0x80, 96, 0, 1])), "too short")
        XCTAssertNil(RTPPacket.parse(Data([0x40, 96, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0x65])), "version 1")
        XCTAssertNil(RTPPacket.parse(Data([0x8F, 96, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0x65])), "15 CSRCs that aren't there")
    }

    // MARK: The TCP stream: RTSP replies and interleaved frames

    func testMessageParserSplitsRepliesAndFramesFedByteByByte() {
        var stream = Data("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Type: application/sdp\r\nContent-Length: 5\r\n\r\nv=0\r\n".utf8)
        stream += Data([0x24, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC])
        stream += Data([0x24, 0x01, 0x00, 0x01, 0x99])
        stream += Data("SET_PARAMETER rtsp://x RTSP/1.0\r\nCSeq: 9\r\nContent-Length: 2\r\n\r\nhi".utf8)
        stream += Data("RTSP/1.0 401 Unauthorized\r\ncseq: 3\r\nWWW-Authenticate: Digest realm=\"a\", nonce=\"b\"\r\n\r\n".utf8)

        var parser = RTSPMessageParser()
        var out: [RTSPMessage] = []
        for byte in stream {
            parser.append(Data([byte]))
            while let m = parser.next() { out.append(m) }
        }
        XCTAssertEqual(out.count, 5)
        guard out.count == 5 else { return }
        guard case .response(let ok) = out[0] else { return XCTFail("\(out[0])") }
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(ok.cseq, 2)
        XCTAssertEqual(ok.header("content-type"), "application/sdp")
        XCTAssertEqual(String(decoding: ok.body, as: UTF8.self), "v=0\r\n")
        XCTAssertEqual(out[1], .interleaved(channel: 0, payload: Data([0xAA, 0xBB, 0xCC])))
        XCTAssertEqual(out[2], .interleaved(channel: 1, payload: Data([0x99])))
        XCTAssertEqual(out[3], .request(method: "SET_PARAMETER", cseq: 9))
        guard case .response(let unauthorized) = out[4] else { return XCTFail("\(out[4])") }
        XCTAssertEqual(unauthorized.status, 401)
        XCTAssertEqual(unauthorized.cseq, 3, "header names are case-insensitive")
        XCTAssertEqual(unauthorized.header("WWW-Authenticate"), #"Digest realm="a", nonce="b""#)
    }

    func testMessageParserSkipsGarbageBetweenMessages() {
        var parser = RTSPMessageParser()
        parser.append(Data([0x00, 0x13, 0x37]) + Data([0x24, 0x00, 0x00, 0x01, 0x42]))
        XCTAssertEqual(parser.next(), .interleaved(channel: 0, payload: Data([0x42])))
        XCTAssertNil(parser.next())
    }

    // MARK: Depacketizing

    private func packet(_ seq: UInt16, ts: UInt32 = 3000, marker: Bool = false, _ payload: Data) -> RTPPacket {
        RTPPacket(marker: marker, payloadType: 96, sequence: seq, timestamp: ts, payload: payload)
    }

    private func nal(_ header: [UInt8], _ count: Int, seed: UInt8 = 1) -> Data {
        Data(header) + Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
    }

    func testH264SingleSTAPAAndFUA() {
        let sps = nal([0x67, 0x42, 0xC0, 0x1E], 6)
        let pps = nal([0x68], 3)
        let idr = nal([0x65], 3000)
        var d = RTPDepacketizer(codec: .h264)

        var stap = Data([0x78])                      // F=0 NRI=3 type=24
        for n in [sps, pps] { stap += Data([UInt8(n.count >> 8), UInt8(n.count & 0xFF)]) + n }
        XCTAssertEqual(d.push(packet(1, stap)).nals, [sps, pps])

        // FU-A: indicator keeps F/NRI, the header carries the type; S on the first, E on the last.
        let body = idr.dropFirst()
        let chunks = stride(from: body.startIndex, to: body.endIndex, by: 1200).map { body[$0..<min($0 + 1200, body.endIndex)] }
        XCTAssertEqual(chunks.count, 3)
        var got: [Data] = []
        for (i, chunk) in chunks.enumerated() {
            var fuHeader: UInt8 = 0x05
            if i == 0 { fuHeader |= 0x80 }
            if i == chunks.count - 1 { fuHeader |= 0x40 }
            let out = d.push(packet(UInt16(2 + i), marker: i == chunks.count - 1, Data([0x7C, fuHeader]) + chunk))
            XCTAssertFalse(out.lost)
            got += out.nals
        }
        XCTAssertEqual(got, [idr], "FU-A fragments rebuild the original NAL, header included")

        let slice = nal([0x41], 40)
        XCTAssertEqual(d.push(packet(5, slice)).nals, [slice], "a single NAL unit packet is the NAL")
    }

    func testH264FUAWithAMissingFragmentIsDroppedAndFlagged() {
        var d = RTPDepacketizer(codec: .h264)
        _ = d.push(packet(10, Data([0x7C, 0x85, 1, 2, 3])))
        let gap = d.push(packet(12, Data([0x7C, 0x45, 7, 8])))   // seq 11 never arrived
        XCTAssertTrue(gap.lost)
        XCTAssertEqual(gap.nals, [], "half a NAL is never emitted")
        let orphan = d.push(packet(13, Data([0x7C, 0x45, 9])))
        XCTAssertEqual(orphan.nals, [])
        XCTAssertTrue(orphan.lost, "an end fragment without a start is a loss too")
        XCTAssertEqual(d.push(packet(14, Data([0x41, 1]))), RTPDepacketizer.Output(nals: [Data([0x41, 1])], lost: false))
    }

    func testH265APAndFU() {
        let vps = nal([0x40, 0x01], 20)
        let sps = nal([0x42, 0x01], 30)
        let pps = nal([0x44, 0x01], 5)
        let idr = nal([0x26, 0x01], 2500, seed: 3)   // type 19 IDR_W_RADL
        var d = RTPDepacketizer(codec: .h265)

        var ap = Data([0x60, 0x01])                  // type 48
        for n in [vps, sps, pps] { ap += Data([UInt8(n.count >> 8), UInt8(n.count & 0xFF)]) + n }
        XCTAssertEqual(d.push(packet(1, ap)).nals, [vps, sps, pps])

        let body = idr.dropFirst(2)
        let chunks = stride(from: body.startIndex, to: body.endIndex, by: 1000).map { body[$0..<min($0 + 1000, body.endIndex)] }
        var got: [Data] = []
        for (i, chunk) in chunks.enumerated() {
            var fu: UInt8 = 19
            if i == 0 { fu |= 0x80 }
            if i == chunks.count - 1 { fu |= 0x40 }
            got += d.push(packet(UInt16(2 + i), Data([0x62, 0x01, fu]) + chunk)).nals   // type 49 FU
        }
        XCTAssertEqual(got, [idr])
        XCTAssertEqual(DashcamRTSP.nalType(idr, codec: .h265), 19)

        let trail = nal([0x02, 0x01], 12)            // type 1 TRAIL_R
        XCTAssertEqual(d.push(packet(UInt16(2 + chunks.count), trail)).nals, [trail])
    }

    // MARK: Access units and keyframes

    func testAccessUnitsSplitOnMarkerAndTimestampChange() {
        var a = RTSPAccessUnitAssembler()
        let n1 = Data([0x65, 1]), n2 = Data([0x65, 2]), n3 = Data([0x41, 3]), n4 = Data([0x41, 4])
        XCTAssertEqual(a.push(timestamp: 100, marker: false, nals: [n1], lost: false), [])
        let first = a.push(timestamp: 100, marker: true, nals: [n2], lost: false)
        XCTAssertEqual(first, [RTSPAccessUnit(nals: [n1, n2], timestamp: 100, damaged: false)])
        // No marker: the next timestamp closes the unit.
        XCTAssertEqual(a.push(timestamp: 3100, marker: false, nals: [n3], lost: false), [])
        let byTimestamp = a.push(timestamp: 6100, marker: false, nals: [n4], lost: true)
        XCTAssertEqual(byTimestamp, [RTSPAccessUnit(nals: [n3], timestamp: 3100, damaged: true)],
                       "no marker and a gap: the missing packet may have been this unit's end")
        XCTAssertEqual(a.push(timestamp: 6100, marker: true, nals: [], lost: false),
                       [RTSPAccessUnit(nals: [n4], timestamp: 6100, damaged: true)])
    }

    func testKeyframeDetection() {
        XCTAssertTrue(DashcamRTSP.isKeyframe([Data([0x67]), Data([0x68]), Data([0x65, 0x88])], codec: .h264))
        XCTAssertFalse(DashcamRTSP.isKeyframe([Data([0x41, 0x9A])], codec: .h264))
        // A non-IDR slice whose slice_type is I (ue(v) first_mb=0 → '1', slice_type=7 → '0001000') with an SPS.
        XCTAssertTrue(DashcamRTSP.isKeyframe([Data([0x67, 0x42]), Data([0x68]), Data([0x01, 0b1000_1000, 0x00])], codec: .h264))
        XCTAssertFalse(DashcamRTSP.isKeyframe([Data([0x01, 0b1000_1000, 0x00])], codec: .h264), "an I slice without an SPS isn't a join point")
        XCTAssertTrue(DashcamRTSP.isKeyframe([Data([0x26, 0x01])], codec: .h265), "IDR_W_RADL")
        XCTAssertTrue(DashcamRTSP.isKeyframe([Data([0x2A, 0x01])], codec: .h265), "CRA")
        XCTAssertFalse(DashcamRTSP.isKeyframe([Data([0x02, 0x01])], codec: .h265), "TRAIL_R")
    }

    // MARK: Format descriptions and sample buffers from real encoder output

    func testH264FormatDescriptionFromEncodedParameterSets() throws {
        let enc = try TestEncoder.encode(codec: kCMVideoCodecType_H264, frames: 1)
        XCTAssertEqual(enc.parameterSets.map { DashcamRTSP.nalType($0, codec: .h264) }, [7, 8])
        let fmt = try XCTUnwrap(DashcamRTSP.formatDescription(codec: .h264, parameterSets: enc.parameterSets))
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        XCTAssertEqual(dims.width, 320)
        XCTAssertEqual(dims.height, 240)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fmt), kCMVideoCodecType_H264)
        XCTAssertNil(DashcamRTSP.formatDescription(codec: .h264, parameterSets: [enc.parameterSets[0]]), "an SPS alone isn't enough")
    }

    func testH265FormatDescriptionFromEncodedParameterSets() throws {
        let enc = try TestEncoder.encode(codec: kCMVideoCodecType_HEVC, frames: 1)
        XCTAssertEqual(enc.parameterSets.map { DashcamRTSP.nalType($0, codec: .h265) }.prefix(3), [32, 33, 34])
        let fmt = try XCTUnwrap(DashcamRTSP.formatDescription(codec: .h265, parameterSets: enc.parameterSets))
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(fmt).width, 320)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fmt), kCMVideoCodecType_HEVC)
    }

    func testFrameBuilderWaitsForAKeyframeAndBuildsDecodableAVCC() throws {
        let enc = try TestEncoder.encode(codec: kCMVideoCodecType_H264, frames: 4)
        XCTAssertTrue(enc.frames[0].key)
        XCTAssertFalse(enc.frames[1].key)
        var b = RTSPFrameBuilder(codec: .h264, parameterSets: [])
        // A delta frame first (joined mid-GOP): dropped.
        XCTAssertNil(b.build(RTSPAccessUnit(nals: enc.frames[1].nals, timestamp: 0, damaged: false)))
        // The keyframe with in-band SPS/PPS: decodable, display-immediately.
        let key = try XCTUnwrap(b.build(RTSPAccessUnit(nals: enc.parameterSets + enc.frames[0].nals, timestamp: 3000, damaged: false)))
        XCTAssertTrue(CMSampleBufferIsValid(key))
        XCTAssertTrue(CMSampleBufferDataIsReady(key))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(key).timescale, 90000)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(key, createIfNecessary: false) as? [[String: Any]])
        XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool, true)
        XCTAssertNil(attachments.first?[kCMSampleAttachmentKey_NotSync as String])
        // Parameter sets are carried by the format description, not the sample.
        let avcc = TestEncoder.bytes(key)
        XCTAssertEqual(TestEncoder.splitAVCC(avcc), enc.frames[0].nals)
        let image = try XCTUnwrap(TestEncoder.decode(key))
        XCTAssertEqual(CVPixelBufferGetWidth(image), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(image), 240)

        let delta = try XCTUnwrap(b.build(RTSPAccessUnit(nals: enc.frames[1].nals, timestamp: 6000, damaged: false)))
        let deltaAttachments = CMSampleBufferGetSampleAttachmentsArray(delta, createIfNecessary: false) as? [[String: Any]]
        XCTAssertEqual(deltaAttachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool, true)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(delta).value - CMSampleBufferGetPresentationTimeStamp(key).value, 3000)

        // A damaged unit means everything after it is suspect until the next keyframe.
        XCTAssertNil(b.build(RTSPAccessUnit(nals: enc.frames[2].nals, timestamp: 9000, damaged: true)))
        XCTAssertNil(b.build(RTSPAccessUnit(nals: enc.frames[3].nals, timestamp: 12000, damaged: false)))
        XCTAssertTrue(b.waitingForKeyframe)
    }

    func testFrameBuilderUsesSDPParameterSetsAndHandlesTimestampWrap() throws {
        let enc = try TestEncoder.encode(codec: kCMVideoCodecType_H264, frames: 2)
        var b = RTSPFrameBuilder(codec: .h264, parameterSets: enc.parameterSets)
        let key = try XCTUnwrap(b.build(RTSPAccessUnit(nals: enc.frames[0].nals, timestamp: UInt32.max - 1499, damaged: false)))
        let next = try XCTUnwrap(b.build(RTSPAccessUnit(nals: enc.frames[1].nals, timestamp: 1500, damaged: false)))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(next).value - CMSampleBufferGetPresentationTimeStamp(key).value, 3000,
                       "the 32-bit RTP clock wrapping doesn't jump time backwards")
        XCTAssertNotNil(TestEncoder.decode(key))
    }

    func testPipelineTurnsPacketsIntoFrames() throws {
        let enc = try TestEncoder.encode(codec: kCMVideoCodecType_H264, frames: 3)
        let sdp = RTSPSessionDescription(codec: .h264, payloadType: 96, clockRate: 90000, control: nil, sessionControl: nil, parameterSets: [])
        var pipeline = RTSPVideoPipeline(sdp)
        var frames: [CMSampleBuffer] = []
        for packet in TestPacketizer.packets(codec: .h264, encoded: enc) {
            frames += pipeline.push(try XCTUnwrap(RTPPacket.parse(packet)))
        }
        XCTAssertEqual(frames.count, 3)
        XCTAssertNotNil(frames.first.flatMap(TestEncoder.decode))
    }

    // MARK: Live source (getmediainfo)

    func testLiveSourceFromMediaInfo() {
        let one = DashcamLiveSource.parse(media: ["rtsp": "rtsp://192.168.169.1:554/", "transport": "tcp"],
                                          attr: ["camnum": 2, "curcamid": 1], host: "192.168.169.1")
        XCTAssertEqual(one.urls.map(\.absoluteString), ["rtsp://192.168.169.1:554/"])
        XCTAssertEqual(one.lenses, 2)
        XCTAssertEqual(one.currentLens, 1)
        XCTAssertTrue(one.canSwitch, "two lenses behind one URL switch with switchcam")
        XCTAssertFalse(one.switchesByURL)

        let two = DashcamLiveSource.parse(media: ["rtsps": ["rtsp://192.168.169.1:554/front", "rtsp://192.168.169.1:554/rear"]],
                                          attr: [:], host: "192.168.169.1")
        XCTAssertEqual(two.urls.count, 2)
        XCTAssertTrue(two.canSwitch)
        XCTAssertTrue(two.switchesByURL)

        let none = DashcamLiveSource.parse(media: nil, attr: nil, host: "10.0.0.5")
        XCTAssertEqual(none.urls.map(\.absoluteString), ["rtsp://10.0.0.5:554/"], "falls back to the usual port")
        XCTAssertFalse(none.canSwitch)

        let zeroHost = DashcamLiveSource.parse(media: ["rtsp": "rtsp://0.0.0.0:554/live"], attr: ["camnum": "1"], host: "192.168.169.1")
        XCTAssertEqual(zeroHost.urls.first?.absoluteString, "rtsp://192.168.169.1:554/live", "a placeholder host is the camera's")
    }

    @MainActor
    func testPauseForLiveSetsTheFlag() {
        let sync = DashcamSync()
        XCTAssertFalse(sync.liveActive)
        sync.pauseForLive(true)
        XCTAssertTrue(sync.liveActive)
        XCTAssertFalse(DashcamSync().liveActive, "per instance")
        sync.pauseForLive(false)
        XCTAssertFalse(sync.liveActive)
    }

    // MARK: End to end against a fake camera

    func testEndToEndH264InBandParameterSets() throws {
        try runEndToEnd(codec: .h264, videoCodec: kCMVideoCodecType_H264, spropInSDP: false)
    }

    func testEndToEndH265WithSDPParameterSets() throws {
        try runEndToEnd(codec: .h265, videoCodec: kCMVideoCodecType_HEVC, spropInSDP: true)
    }

    private func runEndToEnd(codec: RTSPVideoCodec, videoCodec: CMVideoCodecType, spropInSDP: Bool) throws {
        let enc = try TestEncoder.encode(codec: videoCodec, frames: 8)
        let fmtp: String
        let b64 = enc.parameterSets.map { $0.base64EncodedString() }
        switch codec {
        case .h264: fmtp = "a=fmtp:96 packetization-mode=1" + (spropInSDP ? ";sprop-parameter-sets=\(b64.joined(separator: ","))" : "")
        case .h265: fmtp = "a=fmtp:96 " + (spropInSDP ? "sprop-vps=\(b64[0]);sprop-sps=\(b64[1]);sprop-pps=\(b64[2])" : "")
        }
        let sdp = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=fake\r\nt=0 0\r\na=control:*\r\n"
            + "m=video 0 RTP/AVP 96\r\na=rtpmap:96 \(codec == .h264 ? "H264" : "H265")/90000\r\n\(fmtp)\r\na=control:track1\r\n"
        let packets = TestPacketizer.packets(codec: codec, encoded: enc, inBandParameterSets: !spropInSDP)
        let server = try FakeRTSPServer(sdp: sdp, packets: packets)
        defer { server.stop() }
        let port = try server.start()

        let client = DashcamRTSPClient(url: URL(string: "rtsp://127.0.0.1:\(port)/live")!, keepaliveInterval: 0.3)
        var states: [DashcamRTSPClient.State] = []
        var frames: [CMSampleBuffer] = []
        let enough = expectation(description: "frames")
        enough.assertForOverFulfill = false
        let failed = expectation(description: "no failure")
        failed.isInverted = true
        client.onState = { s in
            states.append(s)
            if case .failed = s { failed.fulfill() }
        }
        client.onFrame = { sb in
            XCTAssertTrue(Thread.isMainThread)
            frames.append(sb)
            if frames.count >= enc.frames.count { enough.fulfill() }
        }
        client.start()
        wait(for: [enough], timeout: 10)
        let keepalive = expectation(description: "keepalive")
        keepalive.assertForOverFulfill = false
        server.onRequest = { method in if method == "GET_PARAMETER" { keepalive.fulfill() } }
        wait(for: [keepalive], timeout: 3)
        server.onRequest = nil
        wait(for: [failed], timeout: 0.2)

        XCTAssertEqual(states.first, .connecting)
        XCTAssertTrue(states.contains(.playing))
        XCTAssertEqual(frames.count, enc.frames.count)
        let fmt = try XCTUnwrap(frames.first.flatMap(CMSampleBufferGetFormatDescription))
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(fmt).width, 320)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(fmt).height, 240)
        let image = try XCTUnwrap(frames.first.flatMap(TestEncoder.decode), "the first frame decodes")
        XCTAssertEqual(CVPixelBufferGetWidth(image), 320)

        let methods = server.requests.map(\.method)
        XCTAssertEqual(Array(methods.prefix(4)), ["OPTIONS", "DESCRIBE", "SETUP", "PLAY"])
        let describe = try XCTUnwrap(server.requests.first { $0.method == "DESCRIBE" })
        XCTAssertTrue(describe.text.contains("Accept: application/sdp"))
        let setup = try XCTUnwrap(server.requests.first { $0.method == "SETUP" })
        XCTAssertEqual(setup.url, "rtsp://127.0.0.1:\(port)/live/track1")
        XCTAssertTrue(setup.text.contains("Transport: RTP/AVP/TCP;unicast;interleaved=0-1"), setup.text)
        let play = try XCTUnwrap(server.requests.first { $0.method == "PLAY" })
        XCTAssertTrue(play.text.contains("Session: 66334873\r\n"), play.text)
        XCTAssertEqual(Set(server.requests.compactMap(\.cseq)).count, server.requests.count, "CSeq never repeats")

        let teardown = expectation(description: "teardown")
        server.onRequest = { method in if method == "TEARDOWN" { teardown.fulfill() } }
        let count = frames.count
        client.stop()
        wait(for: [teardown], timeout: 3)
        XCTAssertEqual(frames.count, count, "nothing is delivered after stop")
    }

    func testFailsWhenNothingAnswers() throws {
        // A listener that accepts and then closes: the client must say so, not hang.
        let server = try FakeRTSPServer(sdp: "", packets: [], closeImmediately: true)
        defer { server.stop() }
        let port = try server.start()
        let client = DashcamRTSPClient(url: URL(string: "rtsp://127.0.0.1:\(port)/")!)
        let failed = expectation(description: "failed")
        client.onState = { if case .failed(let message) = $0 { XCTAssertFalse(message.isEmpty); failed.fulfill() } }
        client.start()
        wait(for: [failed], timeout: 5)
        client.stop()
    }

    func testDigestChallengeIsAnsweredWithURLCredentials() throws {
        let enc = try TestEncoder.encode(codec: kCMVideoCodecType_H264, frames: 2)
        let sdp = "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:trackID=0\r\n"
        let server = try FakeRTSPServer(sdp: sdp, packets: TestPacketizer.packets(codec: .h264, encoded: enc, inBandParameterSets: true),
                                        digestRealm: "cam")
        defer { server.stop() }
        let port = try server.start()
        let client = DashcamRTSPClient(url: URL(string: "rtsp://admin:secret@127.0.0.1:\(port)/")!)
        let frame = expectation(description: "frame")
        frame.assertForOverFulfill = false
        client.onFrame = { _ in frame.fulfill() }
        client.start()
        wait(for: [frame], timeout: 10)
        client.stop()
        let describes = server.requests.filter { $0.method == "DESCRIBE" }
        XCTAssertEqual(describes.count, 2, "one refused, one answered")
        XCTAssertTrue(describes.last?.text.contains(#"Authorization: Digest username="admin", realm="cam""#) == true,
                      describes.last?.text ?? "")
        XCTAssertFalse(describes.last?.url.contains("secret") == true, "credentials never go in the request line")
    }
}

// MARK: - Test support

/// Encodes a few frames of a moving gradient with VideoToolbox and hands back what an RTSP
/// camera would send: the parameter sets and each frame's NAL units.
enum TestEncoder {
    struct Output {
        var parameterSets: [Data]
        var frames: [(nals: [Data], key: Bool)]
    }

    static func encode(codec: CMVideoCodecType, frames count: Int, width: Int32 = 320, height: Int32 = 240) throws -> Output {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: codec,
                                                encoderSpecification: nil, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &session)
        guard status == noErr, let session else { throw XCTSkip("no \(codec) encoder here (\(status))") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1000 as CFNumber)
        if codec == kCMVideoCodecType_H264 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        let lock = NSLock()
        var encoded: [CMSampleBuffer] = []
        for i in 0..<count {
            let pixels = try pixelBuffer(session: session, width: Int(width), height: Int(height), frame: i)
            let props = i == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            let s = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels,
                                                    presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30),
                                                    duration: .invalid, frameProperties: props, infoFlagsOut: nil) { status, _, sb in
                guard status == noErr, let sb else { return }
                lock.lock(); encoded.append(sb); lock.unlock()
            }
            guard s == noErr else { throw XCTSkip("encode failed (\(s))") }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock(); defer { lock.unlock() }
        guard let first = encoded.first, let fmt = CMSampleBufferGetFormatDescription(first) else {
            throw XCTSkip("the encoder produced nothing")
        }
        var sets: [Data] = []
        var countOut = 0
        var index = 0
        repeat {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = codec == kCMVideoCodecType_H264
                ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: index, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: &countOut,
                                                                     nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: index, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: &countOut,
                                                                     nalUnitHeaderLengthOut: nil)
            guard st == noErr, let ptr else { break }
            sets.append(Data(bytes: ptr, count: size))
            index += 1
        } while index < countOut
        let frames = encoded.map { sb -> (nals: [Data], key: Bool) in
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
            return (splitAVCC(bytes(sb)), !notSync)
        }
        return Output(parameterSets: sets, frames: frames)
    }

    private static func pixelBuffer(session: VTCompressionSession, width: Int, height: Int, frame: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        if let pool = VTCompressionSessionGetPixelBufferPool(session) {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        }
        if pb == nil {
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb)
        }
        guard let pb else { throw XCTSkip("no pixel buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let planes = max(1, CVPixelBufferGetPlaneCount(pb))
        for plane in 0..<planes {
            let planar = CVPixelBufferIsPlanar(pb)
            guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, plane) : CVPixelBufferGetBaseAddress(pb) else { continue }
            let rows = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, plane) : CVPixelBufferGetBytesPerRow(pb)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rows {
                for x in 0..<stride {
                    bytes[y * stride + x] = plane == 0 ? UInt8(truncatingIfNeeded: x + y + frame * 9) : 128
                }
            }
        }
        return pb
    }

    static func bytes(_ sb: CMSampleBuffer) -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return Data() }
        var out = Data(count: CMBlockBufferGetDataLength(block))
        out.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        return out
    }

    static func splitAVCC(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var out: [Data] = []
        var i = 0
        while i + 4 <= b.count {
            let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            i += 4
            guard i + n <= b.count else { break }
            out.append(Data(b[i..<i + n]))
            i += n
        }
        return out
    }

    static func decode(_ sb: CMSampleBuffer) -> CVPixelBuffer? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb) else { return nil }
        var session: VTDecompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                           imageBufferAttributes: attrs, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        var image: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            if status == noErr { image = img }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr ? image : nil
    }
}

/// RTP packets for encoded frames, packetised the way cameras do: parameter sets in an
/// aggregation packet before each keyframe, big NALs in fragmentation units, marker on the last.
enum TestPacketizer {
    static func packets(codec: RTSPVideoCodec, encoded: TestEncoder.Output, inBandParameterSets: Bool = true,
                        mtu: Int = 1200) -> [Data] {
        var out: [Data] = []
        var seq: UInt16 = 4000
        for (i, frame) in encoded.frames.enumerated() {
            let ts = UInt32(1_000_000 + i * 3000)
            var payloads: [Data] = []
            if frame.key && inBandParameterSets { payloads.append(aggregate(codec, encoded.parameterSets)) }
            for nal in frame.nals { payloads += nal.count <= mtu ? [nal] : fragments(codec, nal, mtu: mtu) }
            for (j, p) in payloads.enumerated() {
                out.append(rtp(seq: seq, ts: ts, marker: j == payloads.count - 1, payload: p))
                seq &+= 1
            }
        }
        return out
    }

    static func rtp(seq: UInt16, ts: UInt32, marker: Bool, payload: Data) -> Data {
        var h: [UInt8] = [0x80, (marker ? 0x80 : 0) | 96, UInt8(seq >> 8), UInt8(seq & 0xFF)]
        h += [UInt8(ts >> 24), UInt8((ts >> 16) & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF), 0x12, 0x34, 0x56, 0x78]
        return Data(h) + payload
    }

    static func aggregate(_ codec: RTSPVideoCodec, _ nals: [Data]) -> Data {
        var p = codec == .h264 ? Data([0x78]) : Data([0x60, 0x01])
        for n in nals { p += Data([UInt8(n.count >> 8), UInt8(n.count & 0xFF)]) + n }
        return p
    }

    static func fragments(_ codec: RTSPVideoCodec, _ nal: Data, mtu: Int) -> [Data] {
        let bytes = [UInt8](nal)
        let headerLength = codec == .h264 ? 1 : 2
        let body = Array(bytes[headerLength...])
        var out: [Data] = []
        var i = 0
        while i < body.count {
            let end = min(i + mtu, body.count)
            let start = i == 0, last = end == body.count
            var flags: UInt8 = 0
            if start { flags |= 0x80 }
            if last { flags |= 0x40 }
            switch codec {
            case .h264:
                out.append(Data([(bytes[0] & 0xE0) | 28, flags | (bytes[0] & 0x1F)]) + Data(body[i..<end]))
            case .h265:
                let type = (bytes[0] >> 1) & 0x3F
                out.append(Data([(bytes[0] & 0x81) | (49 << 1), bytes[1], flags | type]) + Data(body[i..<end]))
            }
            i = end
        }
        return out
    }
}

/// A camera's RTSP server on 127.0.0.1: answers OPTIONS/DESCRIBE/SETUP/PLAY/GET_PARAMETER/TEARDOWN
/// and, after PLAY, streams the given RTP packets interleaved on channel 0 (plus an RTCP-ish
/// frame on channel 1 that the client must ignore).
final class FakeRTSPServer: @unchecked Sendable {
    struct Request { var method: String; var url: String; var cseq: Int?; var text: String }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.rtsp")
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _onRequest: ((String) -> Void)?
    private var connections: [NWConnection] = []
    let sdp: String
    let packets: [Data]
    let closeImmediately: Bool
    let digestRealm: String?

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }
    var onRequest: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onRequest }
        set { lock.lock(); _onRequest = newValue; lock.unlock() }
    }

    init(sdp: String, packets: [Data], closeImmediately: Bool = false, digestRealm: String? = nil) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        self.sdp = sdp
        self.packets = packets
        self.closeImmediately = closeImmediately
        self.digestRealm = digestRealm
    }

    func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue, port != 0 else { throw XCTSkip("the fake camera couldn't listen") }
        return port
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: queue)
        if closeImmediately {
            conn.cancel()
            return
        }
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer + (data ?? Data())
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let text = String(decoding: buffer[buffer.startIndex..<end.upperBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                self.handle(text, conn)
            }
            if !done && error == nil { self.read(conn, buffer: buffer) }
        }
    }

    private func handle(_ text: String, _ conn: NWConnection) {
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return }
        let method = parts[0]
        let cseq = lines.first { $0.lowercased().hasPrefix("cseq:") }.flatMap { Int($0.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
        lock.lock()
        _requests.append(Request(method: method, url: parts[1], cseq: cseq, text: text))
        let callback = _onRequest
        lock.unlock()
        callback?(method)

        let c = "CSeq: \(cseq ?? 0)\r\n"
        func reply(_ status: String, _ headers: String = "", body: String = "") {
            let len = body.isEmpty ? "" : "Content-Length: \(body.utf8.count)\r\n"
            conn.send(content: Data("RTSP/1.0 \(status)\r\n\(c)\(headers)\(len)\r\n\(body)".utf8), completion: .idempotent)
        }
        if let realm = digestRealm, method != "OPTIONS", !text.contains("Authorization: Digest") {
            reply("401 Unauthorized", "WWW-Authenticate: Digest realm=\"\(realm)\", nonce=\"abc123\"\r\n")
            return
        }
        switch method {
        case "OPTIONS":
            reply("200 OK", "Public: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY, GET_PARAMETER\r\n")
        case "DESCRIBE":
            let base = parts[1].hasSuffix("/") ? parts[1] : parts[1] + "/"
            reply("200 OK", "Content-Type: application/sdp\r\nContent-Base: \(base)\r\n", body: sdp)
        case "SETUP":
            reply("200 OK", "Transport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=12345678\r\nSession: 66334873;timeout=60\r\n")
        case "PLAY":
            reply("200 OK", "Session: 66334873\r\nRTP-Info: url=track1;seq=4000;rtptime=1000000\r\n")
            var stream = Data([0x24, 0x01, 0x00, 0x04, 0x80, 0xC8, 0x00, 0x01])   // RTCP on channel 1
            for p in packets {
                stream += Data([0x24, 0x00, UInt8(p.count >> 8), UInt8(p.count & 0xFF)]) + p
            }
            // Split into odd-sized writes so frames straddle TCP reads.
            var i = 0
            while i < stream.count {
                let end = min(i + 977, stream.count)
                conn.send(content: stream.subdata(in: i..<end), completion: .idempotent)
                i = end
            }
        case "GET_PARAMETER", "TEARDOWN":
            reply("200 OK", "Session: 66334873\r\n")
        default:
            reply("501 Not Implemented")
        }
    }
}
