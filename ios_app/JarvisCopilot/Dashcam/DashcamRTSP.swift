import CoreMedia
import CryptoKit
import Foundation
import Network
import os

// The dashcam's live view. AVPlayer can't play RTSP, so this is a small RTSP client of our own:
// RTSP over TCP with RTP interleaved on the same connection (what the vendor app's ijkplayer uses,
// `rtsp_transport=tcp`), H.264 / H.265 depacketizing, and CMSampleBuffers ready for an
// AVSampleBufferDisplayLayer. Everything that parses is static or a value type, so it is tested
// without a camera; `DashcamRTSPClient` only moves bytes. protocol.md §7.

enum RTSPVideoCodec: String, Sendable {
    case h264, h265
}

/// The parts of a DESCRIBE answer the client needs: the first H.264/H.265 video track.
struct RTSPSessionDescription: Equatable, Sendable {
    var codec: RTSPVideoCodec
    var payloadType: Int
    var clockRate: Int
    /// The video track's `a=control` (relative or absolute).
    var control: String?
    /// The session-level `a=control` (often `*`), used for PLAY.
    var sessionControl: String?
    /// Out-of-band parameter sets: H.264 SPS/PPS, H.265 VPS/SPS/PPS.
    var parameterSets: [Data]
}

enum DashcamRTSP {

    // MARK: SDP

    static func parseSDP(_ text: String) -> RTSPSessionDescription? {
        struct Media {
            var kind: String
            var payloads: [Int]
            var rtpmap: [Int: (name: String, clock: Int)] = [:]
            var fmtp: [Int: String] = [:]
            var control: String?
        }
        var sessionControl: String?
        var media: [Media] = []
        for raw in text.split(whereSeparator: \.isNewline) {   // "\r\n" is one Character
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 2, let key = line.first, line.dropFirst().first == "=" else { continue }
            let value = String(line.dropFirst(2))
            if key == "m" {
                let parts = value.split(separator: " ")
                media.append(Media(kind: parts.first.map { $0.lowercased() } ?? "",
                                   payloads: parts.dropFirst(3).compactMap { Int($0) }))
                continue
            }
            guard key == "a" else { continue }
            let name: String, arg: String
            if let colon = value.firstIndex(of: ":") {
                name = String(value[..<colon]).lowercased()
                arg = String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                name = value.lowercased(); arg = ""
            }
            guard !media.isEmpty else {
                if name == "control" { sessionControl = arg }
                continue
            }
            let i = media.count - 1
            switch name {
            case "control":
                media[i].control = arg
            case "rtpmap":
                // "96 H264/90000"
                let parts = arg.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let pt = Int(parts[0]) else { continue }
                let enc = parts[1].split(separator: "/")
                media[i].rtpmap[pt] = (String(enc.first ?? ""), enc.count > 1 ? Int(enc[1]) ?? 90000 : 90000)
            case "fmtp":
                let parts = arg.split(separator: " ", maxSplits: 1)
                guard let first = parts.first, let pt = Int(first) else { continue }
                media[i].fmtp[pt] = parts.count > 1 ? String(parts[1]) : ""
            default:
                break
            }
        }
        for m in media where m.kind == "video" {
            for pt in m.payloads {
                guard let map = m.rtpmap[pt] else { continue }
                let codec: RTSPVideoCodec
                switch map.name.uppercased() {
                case "H264": codec = .h264
                case "H265", "HEVC": codec = .h265
                default: continue
                }
                let params = fmtpParameters(m.fmtp[pt] ?? "")
                let keys = codec == .h264 ? ["sprop-parameter-sets"] : ["sprop-vps", "sprop-sps", "sprop-pps"]
                // The A4 (Lombotech RTSP server) puts Annex-B start codes inside its sprop values.
                let sets = keys.flatMap { (params[$0] ?? "").split(separator: ",").compactMap { base64($0) } }.flatMap(splitAnnexB)
                return RTSPSessionDescription(codec: codec, payloadType: pt, clockRate: map.clock,
                                              control: m.control, sessionControl: sessionControl, parameterSets: sets)
            }
        }
        return nil
    }

    static func fmtpParameters(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in text.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard let k = kv.first else { continue }
            out[k.trimmingCharacters(in: .whitespaces).lowercased()] = kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : ""
        }
        return out
    }

    /// Base64 as cameras write it: sometimes without the `=` padding.
    /// NAL units out of bytes that may carry Annex-B start codes (00 00 01 / 00 00 00 01) — in front, or
    /// inside. The A4 sends them in RTP payloads and sprop values, and fragments each keyframe as one unit
    /// holding "SPS 00 00 00 01 PPS 00 00 00 01 IDR" under the SPS's header — none of which RFC 6184 allows.
    /// Emulation prevention means a real NAL unit never contains 00 00 01, so any found is a boundary.
    static func splitAnnexB(_ nal: Data) -> [Data] {
        let b = [UInt8](nal)
        var cuts: [Int] = []                       // index just past each start code
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { cuts.append(i + 3); i += 3 } else { i += 1 }
        }
        guard !cuts.isEmpty else { return [nal] }
        var out: [Data] = []
        func take(_ from: Int, _ to: Int) {
            var e = to
            while e > from, b[e - 1] == 0 { e -= 1 }   // the 4th start-code byte / trailing zeros
            if e > from { out.append(Data(b[from..<e])) }
        }
        // Bytes before the first start code are a unit of their own (the SPS header case), unless they
        // are just the leading zeros of that start code.
        take(0, cuts[0] - 3)
        for (n, start) in cuts.enumerated() {
            take(start, n + 1 < cuts.count ? cuts[n + 1] - 3 : b.count)
        }
        return out
    }

    static func base64<S: StringProtocol>(_ s: S) -> Data? {
        var t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A track's control against the session base (Content-Base): `*`/none = the base, absolute
    /// stays, relative is appended with a slash (what ffmpeg and live555 do).
    static func resolve(control: String?, base: String) -> String {
        guard let control, !control.isEmpty, control != "*" else { return base }
        let low = control.lowercased()
        if low.hasPrefix("rtsp://") || low.hasPrefix("rtsps://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    /// `Session: 66334873;timeout=60` → id and timeout.
    static func parseSession(_ header: String) -> (id: String, timeout: Int?) {
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let timeout = parts.dropFirst().first { $0.lowercased().hasPrefix("timeout=") }.flatMap { Int($0.dropFirst(8)) }
        return (parts.first ?? "", timeout)
    }

    /// The RTP channel from a reply's `Transport: …;interleaved=0-1`.
    static func interleavedChannel(_ transport: String) -> Int? {
        for part in transport.split(separator: ";") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard p.lowercased().hasPrefix("interleaved=") else { continue }
            return Int(p.dropFirst(12).split(separator: "-").first ?? "")
        }
        return nil
    }

    // MARK: Authentication (cameras rarely ask; Basic and Digest are cheap to answer)

    struct Challenge: Equatable, Sendable {
        enum Scheme: Sendable { case basic, digest }
        var scheme: Scheme
        var realm: String
        var nonce: String
        var qop: String?
        var opaque: String?
        var algorithm: String?

        init?(header: String) {
            let trimmed = header.trimmingCharacters(in: .whitespaces)
            let space = trimmed.firstIndex(of: " ") ?? trimmed.endIndex
            switch trimmed[..<space].lowercased() {
            case "basic": scheme = .basic
            case "digest": scheme = .digest
            default: return nil
            }
            let params = Challenge.parameters(String(trimmed[space...]))
            realm = params["realm"] ?? ""
            nonce = params["nonce"] ?? ""
            qop = params["qop"]
            opaque = params["opaque"]
            algorithm = params["algorithm"]
            if scheme == .digest && nonce.isEmpty { return nil }
        }

        /// `a="x, y", b=z` → [a: "x, y", b: "z"] (commas inside quotes kept).
        static func parameters(_ text: String) -> [String: String] {
            var out: [String: String] = [:]
            var chars = Substring(text)
            while !chars.isEmpty {
                chars = chars.drop { $0 == " " || $0 == "," }
                guard let eq = chars.firstIndex(of: "=") else { break }
                let key = chars[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                chars = chars[chars.index(after: eq)...].drop { $0 == " " }
                var value = ""
                if chars.first == "\"" {
                    chars = chars.dropFirst()
                    let end = chars.firstIndex(of: "\"") ?? chars.endIndex
                    value = String(chars[..<end])
                    chars = end < chars.endIndex ? chars[chars.index(after: end)...] : chars[end...]
                } else {
                    let end = chars.firstIndex(of: ",") ?? chars.endIndex
                    value = chars[..<end].trimmingCharacters(in: .whitespaces)
                    chars = chars[end...]
                }
                out[key] = value
            }
            return out
        }
    }

    static func authorization(_ c: Challenge, user: String, password: String, method: String, uri: String,
                              nc: Int = 1, cnonce: String = String(UUID().uuidString.prefix(8)).lowercased()) -> String {
        switch c.scheme {
        case .basic:
            return "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        case .digest:
            func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
            let ha1 = md5("\(user):\(c.realm):\(password)")
            let ha2 = md5("\(method):\(uri)")
            let auth = (c.qop ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "auth" }
            let ncText = String(format: "%08x", nc)
            let response = auth ? md5("\(ha1):\(c.nonce):\(ncText):\(cnonce):auth:\(ha2)") : md5("\(ha1):\(c.nonce):\(ha2)")
            var h = #"Digest username="\#(user)", realm="\#(c.realm)", nonce="\#(c.nonce)", uri="\#(uri)", response="\#(response)""#
            if auth { h += #", qop=auth, nc=\#(ncText), cnonce="\#(cnonce)""# }
            if let opaque = c.opaque { h += #", opaque="\#(opaque)""# }
            if let algorithm = c.algorithm { h += ", algorithm=\(algorithm)" }
            return h
        }
    }

    // MARK: NAL units

    static func nalType(_ nal: Data, codec: RTSPVideoCodec) -> Int {
        guard let b = nal.first else { return -1 }
        return codec == .h264 ? Int(b & 0x1F) : Int((b >> 1) & 0x3F)
    }

    static func isParameterSet(_ nal: Data, codec: RTSPVideoCodec) -> Bool {
        let t = nalType(nal, codec: codec)
        return codec == .h264 ? (t == 7 || t == 8) : (32...34).contains(t)
    }

    static func isVCL(_ nal: Data, codec: RTSPVideoCodec) -> Bool {
        let t = nalType(nal, codec: codec)
        return codec == .h264 ? (1...5).contains(t) : (0...31).contains(t)
    }

    /// NAL units that go into a sample: slices and SEI. Parameter sets live in the format
    /// description; access unit delimiters, end-of-sequence and filler are dropped.
    static func sampleNALs(_ nals: [Data], codec: RTSPVideoCodec) -> [Data] {
        nals.filter { nal in
            let t = nalType(nal, codec: codec)
            return codec == .h264 ? (1...6).contains(t) : ((0...31).contains(t) || t == 39 || t == 40)
        }
    }

    /// Whether decoding can start at this access unit: an IDR (H.264) or IRAP (H.265) picture —
    /// or, for H.264 cameras that only send IDR once, an I slice that comes with an SPS.
    static func isKeyframe(_ nals: [Data], codec: RTSPVideoCodec) -> Bool {
        switch codec {
        case .h265:
            return nals.contains { (16...21).contains(nalType($0, codec: .h265)) }
        case .h264:
            if nals.contains(where: { nalType($0, codec: .h264) == 5 }) { return true }
            guard nals.contains(where: { nalType($0, codec: .h264) == 7 }) else { return false }
            return nals.contains { nalType($0, codec: .h264) == 1 && [2, 4].contains((h264SliceType($0) ?? -1) % 5) }
        }
    }

    /// slice_type from an H.264 slice header: ue(v) first_mb_in_slice, then ue(v) slice_type.
    static func h264SliceType(_ nal: Data) -> Int? {
        var bytes: [UInt8] = []
        var zeros = 0
        for b in nal.dropFirst().prefix(16) {   // strip emulation-prevention bytes
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            zeros = b == 0 ? zeros + 1 : 0
            bytes.append(b)
        }
        var bit = 0
        func next() -> Int? {
            guard bit < bytes.count * 8 else { return nil }
            defer { bit += 1 }
            return Int(bytes[bit / 8] >> (7 - UInt8(bit % 8))) & 1
        }
        func ue() -> Int? {
            var lz = 0
            while true {
                guard let b = next() else { return nil }
                if b == 1 { break }
                lz += 1
                if lz > 31 { return nil }
            }
            var v = 0
            for _ in 0..<lz {
                guard let b = next() else { return nil }
                v = v << 1 | b
            }
            return (1 << lz) - 1 + v
        }
        guard ue() != nil else { return nil }
        return ue()
    }

    // MARK: Core Media

    /// A format description from parameter sets (any order; only the ones the codec needs are used).
    static func formatDescription(codec: RTSPVideoCodec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        func first(_ type: Int) -> Data? { parameterSets.first { nalType($0, codec: codec) == type && $0.count > 1 } }
        let sets: [Data]
        switch codec {
        case .h264:
            guard let sps = first(7), let pps = first(8) else { return nil }
            sets = [sps, pps]
        case .h265:
            guard let vps = first(32), let sps = first(33), let pps = first(34) else { return nil }
            sets = [vps, sps, pps]
        }
        let joined = sets.reduce(into: [UInt8]()) { $0 += $1 }
        var format: CMVideoFormatDescription?
        let status: OSStatus = joined.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return -1 }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for s in sets { pointers.append(base + offset); offset += s.count }
            let sizes = sets.map(\.count)
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            case .h265:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    /// NAL units → AVCC/HVCC sample data (each NAL prefixed by its 4-byte big-endian length).
    static func avcc(_ nals: [Data]) -> Data {
        var out = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let n = UInt32(nal.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            out.append(nal)
        }
        return out
    }

    /// One frame as a ready CMSampleBuffer, marked display-immediately (live: no clock to wait for).
    static func sampleBuffer(nals: [Data], format: CMVideoFormatDescription, pts: CMTime, keyframe: Bool) -> CMSampleBuffer? {
        let data = avcc(nals)
        guard !data.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            func set(_ key: CFString) {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(key).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            set(kCMSampleAttachmentKey_DisplayImmediately)
            if !keyframe { set(kCMSampleAttachmentKey_NotSync) }
        }
        return sample
    }
}

// MARK: - RTP

struct RTPPacket: Equatable, Sendable {
    var version: Int
    var marker: Bool
    var payloadType: Int
    var sequence: UInt16
    var timestamp: UInt32
    var ssrc: UInt32
    var payload: Data

    init(version: Int = 2, marker: Bool, payloadType: Int, sequence: UInt16, timestamp: UInt32, ssrc: UInt32 = 0, payload: Data) {
        self.version = version
        self.marker = marker
        self.payloadType = payloadType
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    /// RFC 3550 §5.1: fixed header, CSRCs, optional extension, optional padding.
    static func parse(_ data: Data) -> RTPPacket? {
        let b = [UInt8](data)
        guard b.count >= 12, b[0] >> 6 == 2 else { return nil }
        var offset = 12 + 4 * Int(b[0] & 0x0F)
        var end = b.count
        guard offset <= end else { return nil }
        if b[0] & 0x10 != 0 {
            guard offset + 4 <= end else { return nil }
            offset += 4 + 4 * (Int(b[offset + 2]) << 8 | Int(b[offset + 3]))
        }
        if b[0] & 0x20 != 0 {
            let pad = Int(b[end - 1])
            guard pad >= 1 else { return nil }
            end -= pad
        }
        guard offset <= end else { return nil }
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        return RTPPacket(version: 2, marker: b[1] & 0x80 != 0, payloadType: Int(b[1] & 0x7F),
                         sequence: UInt16(b[2]) << 8 | UInt16(b[3]), timestamp: u32(4), ssrc: u32(8),
                         payload: Data(b[offset..<end]))
    }
}

/// RTP payloads → NAL units (RFC 6184 for H.264, RFC 7798 for H.265). A sequence gap, or a
/// fragment without its start, drops the half-built NAL and reports `lost`.
struct RTPDepacketizer {
    struct Output: Equatable {
        var nals: [Data]
        var lost: Bool
    }

    let codec: RTSPVideoCodec
    private var fragment: Data?
    private var lastSequence: UInt16?

    init(codec: RTSPVideoCodec) { self.codec = codec }

    mutating func push(_ packet: RTPPacket) -> Output {
        var lost = false
        if let last = lastSequence, packet.sequence != last &+ 1 {
            lost = true
            fragment = nil
        }
        lastSequence = packet.sequence
        let p = [UInt8](packet.payload)
        var nals: [Data] = []
        // A payload that starts with a start code is one or more whole NAL units (the A4's single packets).
        if p.count >= 4, p[0] == 0, p[1] == 0, p[2] == 1 || (p[2] == 0 && p[3] == 1) {
            if fragment != nil { lost = true; fragment = nil }
            return Output(nals: DashcamRTSP.splitAnnexB(packet.payload), lost: lost)
        }
        switch codec {
        case .h264:
            guard let first = p.first else { break }
            switch first & 0x1F {
            case 1...23:
                nals = [packet.payload]
            case 24:   // STAP-A
                nals = Self.aggregated(p, from: 1)
            case 28:   // FU-A
                guard p.count > 2 else { lost = true; break }
                let header = (first & 0xE0) | (p[1] & 0x1F)
                lost = reassemble(start: p[1] & 0x80 != 0, end: p[1] & 0x40 != 0, header: [header], body: p[2...], into: &nals) || lost
            default:   // STAP-B, MTAP, FU-B: not used by cameras in non-interleaved mode
                break
            }
        case .h265:
            guard p.count >= 2 else { break }
            switch (p[0] >> 1) & 0x3F {
            case 0...47:
                nals = [packet.payload]
            case 48:   // aggregation packet
                nals = Self.aggregated(p, from: 2)
            case 49:   // fragmentation unit
                guard p.count > 3 else { lost = true; break }
                let header = [(p[0] & 0x81) | ((p[2] & 0x3F) << 1), p[1]]
                lost = reassemble(start: p[2] & 0x80 != 0, end: p[2] & 0x40 != 0, header: header, body: p[3...], into: &nals) || lost
            default:   // PACI
                break
            }
        }
        // A fragmented unit the camera cut from its Annex-B output carries the start code inside.
        return Output(nals: nals.flatMap(DashcamRTSP.splitAnnexB), lost: lost)
    }

    /// Returns true when a fragment was lost.
    private mutating func reassemble(start: Bool, end: Bool, header: [UInt8], body: ArraySlice<UInt8>, into nals: inout [Data]) -> Bool {
        var lost = false
        if start {
            if fragment != nil { lost = true }   // the previous one never ended
            fragment = Data(header) + Data(body)
        } else if fragment != nil {
            fragment?.append(contentsOf: body)
        } else {
            return true                          // middle or end without a start
        }
        if end, let done = fragment {
            nals.append(done)
            fragment = nil
        }
        return lost
    }

    /// STAP-A / AP: repeated 16-bit size + NAL unit.
    private static func aggregated(_ p: [UInt8], from start: Int) -> [Data] {
        var out: [Data] = []
        var i = start
        while i + 2 <= p.count {
            let size = Int(p[i]) << 8 | Int(p[i + 1])
            i += 2
            guard size > 0, i + size <= p.count else { break }
            out.append(Data(p[i..<i + size]))
            i += size
        }
        return out
    }
}

/// NAL units belonging to one picture.
struct RTSPAccessUnit: Equatable {
    var nals: [Data]
    var timestamp: UInt32
    var damaged: Bool
}

/// Groups NAL units into access units: a unit ends at the RTP marker bit, or when the timestamp
/// moves on (cameras that never set the marker).
struct RTSPAccessUnitAssembler {
    private var nals: [Data] = []
    private var timestamp: UInt32?
    private var damaged = false

    mutating func push(timestamp ts: UInt32, marker: Bool, nals new: [Data], lost: Bool) -> [RTSPAccessUnit] {
        var out: [RTSPAccessUnit] = []
        if let current = timestamp, current != ts {
            // No marker yet and a gap: the missing packet may have been this unit's end.
            if lost { damaged = true }
            if let unit = flush() { out.append(unit) }
        }
        timestamp = ts
        nals += new
        if lost { damaged = true }
        if marker, let unit = flush() { out.append(unit) }
        return out
    }

    private mutating func flush() -> RTSPAccessUnit? {
        defer { nals = []; damaged = false; timestamp = nil }
        guard let ts = timestamp, !nals.isEmpty || damaged else { return nil }
        return RTSPAccessUnit(nals: nals, timestamp: ts, damaged: damaged)
    }
}

/// Access units → sample buffers. Keeps the latest parameter sets (from the SDP, then in-band),
/// rebuilds the format description when they change, and drops everything until a keyframe —
/// at the start, and again after any damaged unit.
struct RTSPFrameBuilder {
    let codec: RTSPVideoCodec
    let clockRate: Int32
    private(set) var format: CMVideoFormatDescription?
    private(set) var waitingForKeyframe = true
    private var parameterSets: [Int: Data] = [:]
    private var lastTimestamp: UInt32?
    private var elapsed: Int64 = 0

    init(codec: RTSPVideoCodec, parameterSets: [Data], clockRate: Int = 90000) {
        self.codec = codec
        self.clockRate = Int32(clamping: clockRate > 0 ? clockRate : 90000)
        for set in parameterSets { _ = store(set) }
    }

    mutating func waitForKeyframe() { waitingForKeyframe = true }

    static let traceUnits = DashcamLiveTrace.Sampler(first: 80, every: 100)

    mutating func build(_ unit: RTSPAccessUnit) -> CMSampleBuffer? {
        for nal in unit.nals where DashcamRTSP.isParameterSet(nal, codec: codec) {
            if store(nal) { format = nil }
        }
        let pts = time(unit.timestamp)
        let types = unit.nals.map { DashcamRTSP.nalType($0, codec: codec) }
        let sizes = Array(unit.nals.map(\.count).prefix(6))
        func trace(_ verdict: String) {
            guard let n = Self.traceUnits.next() else { return }
            DashcamLiveTrace.log("unit #\(n) ts=\(unit.timestamp) nals=\(types) sizes=\(sizes) damaged=\(unit.damaged) -> \(verdict)")
        }
        if unit.damaged {
            waitingForKeyframe = true
            trace("dropped: damaged")
            return nil
        }
        let nals = DashcamRTSP.sampleNALs(unit.nals, codec: codec)
        guard nals.contains(where: { DashcamRTSP.isVCL($0, codec: codec) }) else { trace("no picture slice"); return nil }
        let key = DashcamRTSP.isKeyframe(unit.nals, codec: codec)
        if waitingForKeyframe && !key { trace("waiting for a keyframe"); return nil }
        if format == nil {
            format = DashcamRTSP.formatDescription(codec: codec, parameterSets: Array(parameterSets.values))
            DashcamLiveTrace.log("format from parameter sets \(parameterSets.keys.sorted()) -> \(format == nil ? "FAILED" : "ok")")
        }
        guard let format, let sample = DashcamRTSP.sampleBuffer(nals: nals, format: format, pts: pts, keyframe: key) else {
            waitingForKeyframe = true
            trace(format == nil ? "no format (parameter sets missing or bad)" : "sample buffer failed")
            return nil
        }
        waitingForKeyframe = false
        trace(key ? "decoded keyframe" : "frame")
        return sample
    }

    /// Returns true when the stored set changed.
    private mutating func store(_ nal: Data) -> Bool {
        let type = DashcamRTSP.nalType(nal, codec: codec)
        guard nal.count > 1, parameterSets[type] != nal else { return false }
        parameterSets[type] = nal
        return true
    }

    /// RTP time → a running presentation time that survives the 32-bit clock wrapping.
    private mutating func time(_ ts: UInt32) -> CMTime {
        if let last = lastTimestamp { elapsed += Int64(Int32(bitPattern: ts &- last)) }
        lastTimestamp = ts
        return CMTime(value: elapsed, timescale: clockRate)
    }
}

/// RTP packets of the video track → sample buffers.
struct RTSPVideoPipeline {
    let sdp: RTSPSessionDescription
    private var depacketizer: RTPDepacketizer
    private var assembler = RTSPAccessUnitAssembler()
    private var builder: RTSPFrameBuilder

    init(_ sdp: RTSPSessionDescription) {
        self.sdp = sdp
        depacketizer = RTPDepacketizer(codec: sdp.codec)
        builder = RTSPFrameBuilder(codec: sdp.codec, parameterSets: sdp.parameterSets, clockRate: sdp.clockRate)
    }

    /// The A4 sets the marker bit on every packet, SPS and PPS included: once a marker comes on a packet
    /// with no picture in it, pictures are grouped by timestamp alone.
    private var markerTrusted = true

    mutating func push(_ packet: RTPPacket) -> [CMSampleBuffer] {
        if (72...76).contains(packet.payloadType) { return [] }   // RTCP muxed onto the channel
        let out = depacketizer.push(packet)
        if packet.marker, markerTrusted, !out.nals.isEmpty,
           !out.nals.contains(where: { DashcamRTSP.isVCL($0, codec: sdp.codec) }) {
            markerTrusted = false
            DashcamLiveTrace.log("the camera marks every packet: grouping pictures by timestamp")
        }
        return assembler.push(timestamp: packet.timestamp, marker: packet.marker && markerTrusted, nals: out.nals, lost: out.lost)
            .compactMap { builder.build($0) }
    }

    mutating func waitForKeyframe() { builder.waitForKeyframe() }
}

// MARK: - The TCP stream

struct RTSPResponse: Equatable {
    struct Header: Equatable {
        var name: String   // lowercased
        var value: String
    }

    var status: Int
    var reason: String
    var headers: [Header]
    var body: Data

    func header(_ name: String) -> String? { headers.first { $0.name == name.lowercased() }?.value }
    func headers(_ name: String) -> [String] { headers.filter { $0.name == name.lowercased() }.map(\.value) }
    var cseq: Int? { header("cseq").flatMap { Int($0) } }
}

enum RTSPMessage: Equatable {
    case response(RTSPResponse)
    /// A request from the server (rare: SET_PARAMETER, OPTIONS, ANNOUNCE).
    case request(method: String, cseq: Int?)
    /// `$` + channel + 16-bit length + data (RFC 2326 §10.12).
    case interleaved(channel: UInt8, payload: Data)
}

/// Splits the one TCP stream into RTSP messages and interleaved frames; bytes that are neither
/// are skipped.
struct RTSPMessageParser {
    private var buffer: [UInt8] = []
    private var position = 0
    private static let headerEnd: [UInt8] = [13, 10, 13, 10]

    mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    mutating func next() -> RTSPMessage? {
        defer { compact() }
        while position < buffer.count {
            if buffer[position] == 0x24 {
                guard buffer.count - position >= 4 else { return nil }
                let length = Int(buffer[position + 2]) << 8 | Int(buffer[position + 3])
                guard buffer.count - position >= 4 + length else { return nil }
                let channel = buffer[position + 1]
                let payload = Data(buffer[position + 4..<position + 4 + length])
                position += 4 + length
                return .interleaved(channel: channel, payload: payload)
            }
            switch looksLikeMessage(at: position) {
            case nil:
                return nil
            case false?:
                position += 1
                continue
            case true?:
                guard let end = find(Self.headerEnd, from: position) else {
                    if buffer.count - position > 16_384 { position += 1; continue }   // never ends: garbage
                    return nil
                }
                let head = String(decoding: buffer[position..<end], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let first = lines.removeFirst()
                var headers: [RTSPResponse.Header] = []
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers.append(.init(name: line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                                         value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                }
                let length = headers.first { $0.name == "content-length" }.flatMap { Int($0.value) } ?? 0
                let bodyStart = end + 4
                guard buffer.count >= bodyStart + max(0, length) else { return nil }
                let body = Data(buffer[bodyStart..<bodyStart + max(0, length)])
                position = bodyStart + max(0, length)
                let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
                if first.hasPrefix("RTSP/") {
                    return .response(RTSPResponse(status: parts.count > 1 ? Int(parts[1]) ?? 0 : 0,
                                                  reason: parts.count > 2 ? parts[2] : "", headers: headers, body: body))
                }
                let cseq = headers.first { $0.name == "cseq" }.flatMap { Int($0.value) }
                return .request(method: parts.first ?? "", cseq: cseq)
            }
        }
        return nil
    }

    /// "RTSP/…" or "METHOD " at `i`: true / false, or nil when there aren't enough bytes to tell.
    private func looksLikeMessage(at i: Int) -> Bool? {
        var j = i
        while j < buffer.count && j - i < 24 {
            let c = buffer[j]
            if c == 0x20 { return j > i }
            if c == 0x2F { return j - i == 4 && buffer[i..<j].elementsEqual("RTSP".utf8) }
            let upper = (0x41...0x5A).contains(c) || c == 0x5F || c == 0x2D
            if !upper { return false }
            j += 1
        }
        return j - i >= 24 ? false : nil
    }

    private func find(_ needle: [UInt8], from start: Int) -> Int? {
        guard buffer.count >= needle.count else { return nil }
        var i = start
        while i + needle.count <= buffer.count {
            if buffer[i] == needle[0] && buffer[i + 1] == needle[1] && buffer[i + 2] == needle[2] && buffer[i + 3] == needle[3] {
                return i
            }
            i += 1
        }
        return nil
    }

    private mutating func compact() {
        if position >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            position = 0
        } else if position > 65_536 {
            buffer.removeFirst(position)
            position = 0
        }
    }
}

// MARK: - RTP over UDP

extension DashcamRTSP {
    /// A `client_port=a-b` / `server_port=a-b` pair from a Transport header.
    static func ports(_ key: String, in transport: String) -> (rtp: UInt16, rtcp: UInt16)? {
        for part in transport.split(separator: ";") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard p.lowercased().hasPrefix(key.lowercased() + "=") else { continue }
            let nums = p.dropFirst(key.count + 1).split(separator: "-").compactMap { UInt16($0) }
            guard let first = nums.first else { return nil }
            return (first, nums.count > 1 ? nums[1] : first &+ 1)
        }
        return nil
    }

    /// The sender's SSRC and the middle 32 bits of its NTP time from an RTCP sender report
    /// (the first SR in a compound packet).
    static func senderReport(_ data: Data) -> (ssrc: UInt32, middleNTP: UInt32)? {
        let b = [UInt8](data)
        var i = 0
        while i + 4 <= b.count {
            let words = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if b[i] >> 6 == 2, b[i + 1] == 200, i + 16 <= b.count {
                func u32(_ j: Int) -> UInt32 { UInt32(b[j]) << 24 | UInt32(b[j + 1]) << 16 | UInt32(b[j + 2]) << 8 | UInt32(b[j + 3]) }
                return (u32(i + 4), u32(i + 10))
            }
            i += 4 * (words + 1)
        }
        return nil
    }

    /// RTCP receiver report (one report block) + SDES CNAME, RFC 3550 §6.4.2 / §6.5.
    static func receiverReport(ssrc: UInt32, sourceSSRC: UInt32, fractionLost: UInt8, cumulativeLost: Int32,
                               extendedHighestSequence: UInt32, lastSR: UInt32, delaySinceLastSR: UInt32,
                               cname: String = "jarviscopilot") -> Data {
        var out: [UInt8] = []
        func u32(_ v: UInt32) { out += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        out += [0x81, 201, 0, 7]
        u32(ssrc)
        u32(sourceSSRC)
        let lost = UInt32(bitPattern: max(-0x80_0000, min(0x7F_FFFF, cumulativeLost))) & 0xFF_FFFF
        u32(UInt32(fractionLost) << 24 | lost)
        u32(extendedHighestSequence)
        u32(0)                      // jitter: not tracked
        u32(lastSR)
        u32(delaySinceLastSR)
        let name = Array(cname.utf8.prefix(255))
        var chunk: [UInt8] = []
        chunk += [1, UInt8(name.count)] + name + [0]          // CNAME, END
        while (4 + chunk.count) % 4 != 0 { chunk.append(0) }
        let words = (4 + 4 + chunk.count) / 4 - 1
        out += [0x81, 202, UInt8(words >> 8), UInt8(words & 0xFF)]
        u32(ssrc)
        out += chunk
        return Data(out)
    }
}

/// Puts UDP packets back in sequence order. The first few are sorted before any goes out (so a
/// swapped start doesn't lose the keyframe's head); after that a missing packet is waited for
/// while `window` later ones pile up, then skipped (the gap shows downstream as a loss).
/// Packets that arrive after their slot was passed, and duplicates, are dropped.
struct RTPReorderBuffer {
    let window: Int
    private var expected: UInt16?
    private var held: [UInt16: RTPPacket] = [:]
    private var warmup: [RTPPacket] = []
    private static let warmupCount = 3
    private static let restart = 3000   // a jump this big is a restarted stream, not reordering

    init(window: Int = 16) { self.window = max(1, window) }

    mutating func push(_ packet: RTPPacket) -> [RTPPacket] {
        guard let exp = expected else {
            warmup.append(packet)
            guard warmup.count >= Self.warmupCount else { return [] }
            let ref = warmup[0].sequence
            let sorted = warmup.sorted { Int16(bitPattern: $0.sequence &- ref) < Int16(bitPattern: $1.sequence &- ref) }
            warmup = []
            expected = sorted[0].sequence
            return sorted.flatMap { push($0) }
        }
        let ahead = Int(Int16(bitPattern: packet.sequence &- exp))
        if abs(ahead) > Self.restart { return restart(with: packet) }
        guard ahead >= 0 else { return [] }   // late or duplicate
        held[packet.sequence] = packet
        var out = drain()
        while held.count > window, let next = oldestHeld() {
            expected = next
            out += drain()
        }
        return out
    }

    private mutating func drain() -> [RTPPacket] {
        var out: [RTPPacket] = []
        while let e = expected, let p = held.removeValue(forKey: e) {
            out.append(p)
            expected = e &+ 1
        }
        return out
    }

    private func oldestHeld() -> UInt16? {
        guard let e = expected else { return held.keys.first }
        return held.keys.min { Int16(bitPattern: $0 &- e) < Int16(bitPattern: $1 &- e) }
    }

    private mutating func restart(with packet: RTPPacket) -> [RTPPacket] {
        var older: [RTPPacket] = []
        while let next = oldestHeld() {
            expected = next
            older += drain()
        }
        held = [:]
        expected = packet.sequence &+ 1
        return older + [packet]
    }
}

/// What a receiver report needs (RFC 3550 A.3, without jitter).
struct RTPReceiveStats {
    private(set) var ssrc: UInt32?
    private(set) var received: UInt32 = 0
    private var baseSequence: UInt32 = 0
    private var maxSequence: UInt16 = 0
    private var cycles: UInt32 = 0
    private var expectedPrior: UInt32 = 0
    private var receivedPrior: UInt32 = 0

    mutating func record(_ packet: RTPPacket) {
        guard let ssrc else {
            self.ssrc = packet.ssrc
            baseSequence = UInt32(packet.sequence)
            maxSequence = packet.sequence
            received = 1
            return
        }
        guard packet.ssrc == ssrc else { return }
        received &+= 1
        let delta = packet.sequence &- maxSequence
        if delta != 0 && delta < 0x8000 {
            if packet.sequence < maxSequence { cycles &+= 1 << 16 }
            maxSequence = packet.sequence
        }
    }

    var extendedHighestSequence: UInt32 { cycles &+ UInt32(maxSequence) }
    var expected: UInt32 { ssrc == nil ? 0 : extendedHighestSequence &- baseSequence &+ 1 }
    var cumulativeLost: Int32 { Int32(clamping: max(0, Int64(expected) - Int64(received))) }

    /// Loss since the last call, in 1/256ths.
    mutating func takeFractionLost() -> UInt8 {
        let expectedInterval = Int64(expected) - Int64(expectedPrior)
        let receivedInterval = Int64(received) - Int64(receivedPrior)
        expectedPrior = expected
        receivedPrior = received
        let lost = expectedInterval - receivedInterval
        guard expectedInterval > 0, lost > 0 else { return 0 }
        return UInt8(min(255, (lost << 8) / expectedInterval))
    }
}

/// RTP and RTCP on a local even/odd UDP port pair (SETUP's `client_port`). Datagrams arrive as
/// flows on two listeners, from whatever port the camera sends from; receiver reports go back on
/// the camera's RTCP flow once it has sent one. Everything runs on the client's queue.
final class RTSPUDPReceiver: @unchecked Sendable {
    private let queue: DispatchQueue
    private var listeners: [NWListener] = []
    private var flows: [NWConnection] = []
    private var rtcpFlow: NWConnection?
    private var cancelled = false
    private(set) var ports: (rtp: UInt16, rtcp: UInt16)?
    var onRTP: ((Data) -> Void)?
    var onRTCP: ((Data) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    /// Binds a free port pair, trying a few random ones; `completion(true)` once both listen.
    func bind(tries: Int = 8, completion: @escaping (Bool) -> Void) {
        guard !cancelled else { return }
        dropListeners()
        let rtp = UInt16.random(in: 25_000...32_700) * 2
        let pair: [NWListener]
        do {
            pair = try [rtp, rtp + 1].map { port in
                let params = NWParameters.udp
                params.prohibitedInterfaceTypes = [.cellular]
                return try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
            }
        } catch {
            queue.async { tries > 1 ? self.bind(tries: tries - 1, completion: completion) : completion(false) }
            return
        }
        listeners = pair
        final class Progress { var ready = 0; var settled = false }
        let progress = Progress()
        for (i, listener) in pair.enumerated() {
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn, rtcp: i == 1) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !progress.settled, !self.cancelled else { return }
                switch state {
                case .ready:
                    progress.ready += 1
                    if progress.ready == 2 {
                        progress.settled = true
                        self.ports = (rtp, rtp + 1)
                        completion(true)
                    }
                case .failed, .cancelled:
                    progress.settled = true
                    self.dropListeners()
                    if tries > 1 { self.bind(tries: tries - 1, completion: completion) } else { completion(false) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Sends on the camera's RTCP flow; false until the camera has sent RTCP.
    @discardableResult
    func sendRTCP(_ data: Data) -> Bool {
        guard let rtcpFlow, !cancelled else { return false }
        rtcpFlow.send(content: data, completion: .idempotent)
        return true
    }

    func cancel() {
        cancelled = true
        onRTP = nil
        onRTCP = nil
        dropListeners()
        flows.forEach { $0.cancel() }
        flows = []
        rtcpFlow = nil
    }

    private func dropListeners() {
        for l in listeners {
            l.stateUpdateHandler = nil
            l.newConnectionHandler = nil
            l.cancel()
        }
        listeners = []
    }

    private func accept(_ conn: NWConnection, rtcp: Bool) {
        guard !cancelled else { return conn.cancel() }
        flows.append(conn)
        if rtcp { rtcpFlow = conn }
        conn.start(queue: queue)
        read(conn, rtcp: rtcp)
    }

    private func read(_ conn: NWConnection, rtcp: Bool) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.cancelled else { return }
            if let data, !data.isEmpty { (rtcp ? self.onRTCP : self.onRTP)?(data) }
            if error == nil { self.read(conn, rtcp: rtcp) }
        }
    }
}

// MARK: - The client

/// One live RTSP session: OPTIONS → DESCRIBE → SETUP → PLAY, a keepalive every 25 s (or half
/// the session timeout), TEARDOWN on stop. RTP comes over UDP (client ports + RTCP receiver
/// reports) or interleaved on the RTSP connection; `transports` is the order to try, and a
/// transport that is refused at SETUP or brings no video within `firstPacketTimeout` is torn
/// down for the next one — what the vendor app does. Frames and state arrive on
/// `callbackQueue` (main by default); nothing arrives after `stop()`.
final class DashcamRTSPClient: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case connecting
        case playing          // the first frame is out
        case failed(String)
    }

    enum Transport: String, Sendable, CaseIterable {
        case udp = "UDP"
        case tcp = "TCP"
        var other: Transport { self == .udp ? .tcp : .udp }
    }

    let url: URL
    let transports: [Transport]
    var onState: ((State) -> Void)?
    var onFrame: ((CMSampleBuffer) -> Void)?
    var callbackQueue: DispatchQueue = .main
    var connectTimeout: TimeInterval = 10
    /// No RTP at all this long after PLAY: the transport isn't getting through, try the next.
    var firstPacketTimeout: TimeInterval = 4
    var stallTimeout: TimeInterval = 10
    var rtcpInterval: TimeInterval = 5

    /// The transport that delivered the first frame.
    var activeTransport: Transport? {
        lock.lock(); defer { lock.unlock() }
        return _activeTransport
    }

    private let queue = DispatchQueue(label: "jc.dashcam.rtsp", qos: .userInitiated)
    private let configuredKeepalive: TimeInterval
    private let requestURL: String
    private let user: String?
    private let password: String?
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private let lock = NSLock()
    private var alive = true
    private var _activeTransport: Transport?
    // The whole session.
    private var started = false
    private var finished = false
    private var deliveredFirst = false
    private var attempt = 0
    private var cseq = 0
    private var challenge: DashcamRTSP.Challenge?
    private var nonceCount = 0
    // One attempt (one RTSP connection, one transport).
    private var connection: NWConnection?
    private var parser = RTSPMessageParser()
    private var pending: [Int: (RTSPResponse) -> Void] = [:]
    private var session: String?
    private var baseURL: String
    private var playURL: String
    private var pipeline: RTSPVideoPipeline?
    private var using: Transport = .tcp
    private var videoChannel: UInt8 = 0
    private var refusedRetries = 0
    private var udp: RTSPUDPReceiver?
    private var reorder = RTPReorderBuffer()
    private var stats = RTPReceiveStats()
    private var lastSR: (middle: UInt32, at: Date)?
    private var keepaliveInterval: TimeInterval
    private var useGetParameter = true
    private var timers: [DispatchSourceTimer] = []
    private var connected = false
    private var setupSent = false
    private var playing = false
    private var packets = 0
    private var attemptStartedAt = Date()
    private var playStartedAt = Date()
    private var lastProgress = Date()
    private var lastError: String?

    init(url: URL, transports: [Transport] = [.udp, .tcp], keepaliveInterval: TimeInterval = 25) {
        self.url = url
        self.transports = transports.isEmpty ? [.tcp] : transports
        configuredKeepalive = keepaliveInterval
        self.keepaliveInterval = keepaliveInterval
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        user = c?.user.flatMap { $0.removingPercentEncoding ?? $0 }
        password = c?.password.flatMap { $0.removingPercentEncoding ?? $0 }
        c?.user = nil
        c?.password = nil
        requestURL = c?.string ?? url.absoluteString
        baseURL = requestURL
        playURL = requestURL
    }

    deinit {
        timers.forEach { $0.cancel() }
        udp?.cancel()
        connection?.cancel()
    }

    func start() {
        queue.async { [self] in
            guard !started, !finished else { return }
            started = true
            emit(.connecting)
            guard let host = url.host, !host.isEmpty else { return fail("That isn't a stream address: \(url.absoluteString)") }
            beginAttempt()
        }
    }

    func stop() {
        lock.lock(); alive = false; lock.unlock()
        queue.async { [self] in
            let live = !finished
            finished = true
            endAttempt(teardown: live)
        }
    }

    /// After the display had to flush its decoder: drop frames until the next keyframe.
    func requestKeyframe() {
        queue.async { [self] in pipeline?.waitForKeyframe() }
    }

    // MARK: Callbacks

    private var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return alive
    }

    private func emit(_ state: State) {
        callbackQueue.async { [weak self] in
            guard let self, self.isAlive else { return }
            self.onState?(state)
        }
    }

    private func deliver(_ frame: CMSampleBuffer) {
        lastProgress = Date()
        if !deliveredFirst {
            deliveredFirst = true
            lock.lock(); _activeTransport = using; lock.unlock()
            JcLog.devices.notice("Dashcam live: playing over \(self.using.rawValue, privacy: .public)")
            DashcamLiveTrace.log("first frame delivered over \(using.rawValue)")
            emit(.playing)
        }
        callbackQueue.async { [weak self] in
            guard let self, self.isAlive else { return }
            self.onFrame?(frame)
        }
    }

    /// Ends the session — or, when `canFallBack` and nothing has played yet, moves on to the
    /// next transport.
    private func fail(_ message: String, canFallBack: Bool = false) {
        guard !finished else { return }
        DashcamLiveTrace.log("FAIL: \(message) (packets \(packets), connected \(connected), setup \(setupSent), playing \(playing))")
        if canFallBack, !deliveredFirst, attempt + 1 < transports.count {
            JcLog.devices.notice("Dashcam live: \(self.using.rawValue, privacy: .public) gave nothing (\(message, privacy: .public)); trying \(self.transports[self.attempt + 1].rawValue, privacy: .public)")
            endAttempt(teardown: true)
            attempt += 1
            beginAttempt()
            return
        }
        finished = true
        endAttempt(teardown: true)
        let tried = transports.prefix(attempt + 1).map(\.rawValue).joined(separator: " and ")
        JcLog.devices.notice("Dashcam live failed: \(message, privacy: .public) (tried \(tried, privacy: .public))")
        emit(.failed(attempt > 0 ? "\(message) (tried \(tried))" : message))
    }

    // MARK: Attempts

    private func beginAttempt() {
        parser = RTSPMessageParser()
        pending = [:]
        session = nil
        baseURL = requestURL
        playURL = requestURL
        pipeline = nil
        using = transports[attempt]
        videoChannel = 0
        reorder = RTPReorderBuffer()
        stats = RTPReceiveStats()
        lastSR = nil
        keepaliveInterval = configuredKeepalive
        useGetParameter = true
        connected = false
        setupSent = false
        playing = false
        packets = 0
        lastError = nil
        attemptStartedAt = Date()
        JcLog.devices.notice("Dashcam live: RTSP over \(self.using.rawValue, privacy: .public) to \(self.requestURL, privacy: .public)")
        DashcamLiveTrace.log("attempt \(attempt + 1)/\(transports.count): \(using.rawValue) \(requestURL)")
        watchdog()
        guard using == .udp else { return connect() }
        let receiver = RTSPUDPReceiver(queue: queue)
        receiver.onRTP = { [weak self] data in self?.receivedUDP(data) }
        receiver.onRTCP = { [weak self] data in self?.receivedRTCP(data) }
        udp = receiver
        receiver.bind { [weak self, weak receiver] ok in
            guard let self, let receiver, receiver === self.udp, !self.finished else { return }
            let bound = receiver.ports.map { "\($0.rtp)-\($0.rtcp)" } ?? "none"
            DashcamLiveTrace.log("udp ports: \(ok ? bound : "FAILED to bind")")
            if ok { self.connect() } else { self.fail("Couldn't open local ports for the video", canFallBack: true) }
        }
    }

    private func endAttempt(teardown: Bool) {
        timers.forEach { $0.cancel() }
        timers = []
        pending = [:]
        udp?.cancel()
        udp = nil
        guard let conn = connection else { return }
        connection = nil
        if teardown, session != nil, connected {
            cseq += 1
            conn.send(content: Data(request("TEARDOWN", playURL, cseq: cseq).utf8),
                      completion: .contentProcessed { _ in conn.cancel() })
            queue.asyncAfter(deadline: .now() + 1) { conn.cancel() }
        } else {
            conn.cancel()
        }
        session = nil
    }

    // MARK: Connection

    private func connect() {
        guard let host = url.host else { return }
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]   // the camera only exists on its own Wi‑Fi
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? 554) ?? 554) ?? 554,
                                using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in self?.connectionChanged(state, conn) }
        conn.start(queue: queue)
        receive(conn)
    }

    private func connectionChanged(_ state: NWConnection.State, _ conn: NWConnection) {
        guard conn === connection, !finished else { return }
        DashcamLiveTrace.log("rtsp tcp: \(state)")
        switch state {
        case .ready:
            connected = true
            options()
        case .waiting(let error):
            lastError = Self.describe(error)   // keeps retrying until the watchdog gives up
        case .failed(let error):
            // After a lens switch the A4 restarts its RTSP server and refuses connections for a moment.
            if !setupSent, refusedRetries < 8, case .posix(let code) = error, code == .ECONNREFUSED {
                refusedRetries += 1
                DashcamLiveTrace.log("connection refused (camera restarting its stream?) — retry \(refusedRetries)")
                conn.cancel()
                connection = nil
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, !self.finished, self.connection == nil else { return }
                    self.attemptStartedAt = Date()
                    self.connect()
                }
                return
            }
            fail("Couldn't reach the camera's video stream (\(Self.describe(error)))", canFallBack: setupSent)
        default:
            break
        }
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, complete, error in
            guard let self, conn === self.connection, !self.finished else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                self.drain(conn)
            }
            guard conn === self.connection, !self.finished else { return }   // a reply may have moved on
            if let error { return self.fail("Lost the camera's video stream (\(Self.describe(error)))", canFallBack: self.setupSent) }
            if complete {
                return self.fail(self.playing ? "The camera closed the video stream" : "The camera hung up before the video started",
                                 canFallBack: self.setupSent)
            }
            self.receive(conn)
        }
    }

    private func drain(_ conn: NWConnection) {
        while !finished, conn === connection, let message = parser.next() {
            switch message {
            case .interleaved(let channel, let payload):
                DashcamLiveTrace.capture(channel: channel, payload)
                if let n = Self.tracePackets.next() {
                    DashcamLiveTrace.log("tcp rtp #\(n) ch=\(channel) \(payload.count) B head=" + payload.prefix(16).map { String(format: "%02x", $0) }.joined())
                }
                // Video is whatever even channel carries the video payload type: the A4 agrees to
                // interleaved=0-1 and then sends the video on channel 2.
                guard channel % 2 == 0, let sdp = pipeline?.sdp, let packet = RTPPacket.parse(payload),
                      packet.payloadType == sdp.payloadType else { continue }
                if channel != videoChannel {
                    DashcamLiveTrace.log("video arrives on channel \(channel), not \(videoChannel): following it")
                    videoChannel = channel
                }
                packets += 1
                feed(packet)
            case .response(let response):
                guard let seq = response.cseq, let handler = pending.removeValue(forKey: seq) else { continue }
                handler(response)
            case .request(_, let seq):
                conn.send(content: Data("RTSP/1.0 200 OK\r\nCSeq: \(seq ?? 0)\r\n\r\n".utf8), completion: .idempotent)
            }
        }
    }

    private func feed(_ packet: RTPPacket) {
        for frame in pipeline?.push(packet) ?? [] { deliver(frame) }
    }

    static let tracePackets = DashcamLiveTrace.Sampler(first: 30, every: 1000)

    private func receivedUDP(_ data: Data) {
        if let n = Self.tracePackets.next() {
            DashcamLiveTrace.log("udp rtp #\(n) \(data.count) B head=" + data.prefix(16).map { String(format: "%02x", $0) }.joined())
        }
        guard !finished, using == .udp, pipeline != nil, let packet = RTPPacket.parse(data),
              !(72...76).contains(packet.payloadType) else { return }
        packets += 1
        stats.record(packet)
        for p in reorder.push(packet) { feed(p) }
    }

    private func receivedRTCP(_ data: Data) {
        guard !finished, let sr = DashcamRTSP.senderReport(data) else { return }
        lastSR = (sr.middleNTP, Date())
    }

    /// Fails (or falls back) when the session doesn't start, brings no video, or stalls.
    private func watchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            let now = Date()
            if !self.playing {
                if now.timeIntervalSince(self.attemptStartedAt) > self.connectTimeout {
                    self.fail(self.connected ? "The camera didn't start its video stream"
                                             : "Couldn't reach the camera's video stream" + (self.lastError.map { " (\($0))" } ?? ""),
                              canFallBack: self.setupSent)
                }
            } else if !self.deliveredFirst {
                let waited = now.timeIntervalSince(self.playStartedAt)
                if self.packets == 0, waited > self.firstPacketTimeout, self.attempt + 1 < self.transports.count {
                    self.fail("No video arrived over \(self.using.rawValue)", canFallBack: true)
                } else if waited > self.stallTimeout {
                    self.fail(self.packets == 0 ? "No video from the camera" : "No picture from the camera", canFallBack: true)
                }
            } else if now.timeIntervalSince(self.lastProgress) > self.stallTimeout {
                self.fail("The camera stopped sending video")
            }
        }
        t.resume()
        timers.append(t)
    }

    /// RTCP receiver reports on the camera's RTCP flow, so it knows we're still listening.
    private func startReceiverReports() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + rtcpInterval, repeating: rtcpInterval)
        t.setEventHandler { [weak self] in
            guard let self, !self.finished, let udp = self.udp, let source = self.stats.ssrc else { return }
            let delay = self.lastSR.map { UInt32(min(Double(UInt32.max), Date().timeIntervalSince($0.at) * 65536)) } ?? 0
            let report = DashcamRTSP.receiverReport(ssrc: self.ssrc, sourceSSRC: source, fractionLost: self.stats.takeFractionLost(),
                                                    cumulativeLost: self.stats.cumulativeLost,
                                                    extendedHighestSequence: self.stats.extendedHighestSequence,
                                                    lastSR: self.lastSR?.middle ?? 0, delaySinceLastSR: delay)
            udp.sendRTCP(report)
        }
        t.resume()
        timers.append(t)
    }

    // MARK: RTSP

    private func request(_ method: String, _ target: String, cseq: Int, headers: [(String, String)] = []) -> String {
        var text = "\(method) \(target) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: JarvisCopilot\r\n"
        if let session { text += "Session: \(session)\r\n" }
        if let challenge, let user {
            nonceCount += 1
            text += "Authorization: " + DashcamRTSP.authorization(challenge, user: user, password: password ?? "",
                                                                  method: method, uri: target, nc: nonceCount) + "\r\n"
        }
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        return text + "\r\n"
    }

    private func send(_ method: String, _ target: String, headers: [(String, String)] = [], authRetry: Bool = true,
                      then: @escaping (RTSPResponse) -> Void) {
        guard let conn = connection, !finished else { return }
        cseq += 1
        DashcamLiveTrace.log("-> \(method) \(target) " + headers.map { "\($0.0): \($0.1)" }.joined(separator: "; "))
        pending[cseq] = { [weak self] response in
            guard let self else { return }
            let shown = response.headers.map { "\($0.name): \($0.value)" }.joined(separator: " | ")
            let body = response.body.isEmpty ? "" : "\n" + String(decoding: response.body.prefix(1500), as: UTF8.self)
            DashcamLiveTrace.log("<- \(response.status) \(response.reason) | \(shown)\(body)")
            if response.status == 401 && authRetry {
                let offered = response.headers("www-authenticate").compactMap { DashcamRTSP.Challenge(header: $0) }
                guard self.user != nil, let challenge = offered.first(where: { $0.scheme == .digest }) ?? offered.first else {
                    return self.fail(self.user == nil ? "The camera's live stream wants a password"
                                                      : "The camera didn't accept the stream's password")
                }
                self.challenge = challenge
                self.send(method, target, headers: headers, authRetry: false, then: then)
                return
            }
            if response.status == 401 { return self.fail("The camera didn't accept the stream's password") }
            then(response)
        }
        conn.send(content: Data(request(method, target, cseq: cseq, headers: headers).utf8), completion: .contentProcessed { [weak self] error in
            guard let error, let self else { return }
            self.queue.async {
                guard conn === self.connection else { return }
                self.fail("Couldn't talk to the camera (\(Self.describe(error)))", canFallBack: self.setupSent)
            }
        })
    }

    private func options() {
        send("OPTIONS", requestURL) { [weak self] response in
            guard let self else { return }
            if let methods = response.header("public") { self.useGetParameter = methods.uppercased().contains("GET_PARAMETER") }
            self.describe()   // some cameras answer OPTIONS with an error and still stream
        }
    }

    private func describe(tries: Int = 0) {
        send("DESCRIBE", requestURL, headers: [("Accept", "application/sdp")]) { [weak self] response in
            guard let self else { return }
            guard response.status == 200 else { return self.fail("The camera refused the stream (\(response.status) \(response.reason))") }
            // Right after `enterrecorder` the A4 answers DESCRIBE with an empty description; a moment later it's there.
            if response.body.isEmpty, tries < 6 {
                self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, !self.finished, self.connection != nil else { return }
                    self.describe(tries: tries + 1)
                }
                return
            }
            guard let sdp = DashcamRTSP.parseSDP(String(decoding: response.body, as: UTF8.self)) else {
                return self.fail("The camera's stream isn't H.264 or H.265 video")
            }
            let base = (response.header("content-base") ?? response.header("content-location") ?? "").trimmingCharacters(in: .whitespaces)
            self.baseURL = base.isEmpty ? self.requestURL : base
            self.pipeline = RTSPVideoPipeline(sdp)
            self.setup(sdp)
        }
    }

    private func setup(_ sdp: RTSPSessionDescription) {
        let transport: String
        switch using {
        case .tcp:
            transport = "RTP/AVP/TCP;unicast;interleaved=0-1"
        case .udp:
            guard let ports = udp?.ports else { return fail("Couldn't open local ports for the video", canFallBack: true) }
            transport = "RTP/AVP;unicast;client_port=\(ports.rtp)-\(ports.rtcp)"
        }
        setupSent = true
        send("SETUP", DashcamRTSP.resolve(control: sdp.control, base: baseURL), headers: [("Transport", transport)]) { [weak self] response in
            guard let self else { return }
            guard response.status == 200 else {
                return self.fail(response.status == 461 ? "The camera won't stream over \(self.using.rawValue)"
                                                        : "The camera refused the video track (\(response.status) \(response.reason))",
                                 canFallBack: true)
            }
            if let header = response.header("session") {
                let s = DashcamRTSP.parseSession(header)
                self.session = s.id
                if let timeout = s.timeout, timeout > 0 { self.keepaliveInterval = min(self.keepaliveInterval, max(1, Double(timeout) / 2)) }
            }
            let reply = response.header("transport") ?? ""
            if let channel = DashcamRTSP.interleavedChannel(reply) {
                self.videoChannel = UInt8(clamping: channel)
                if self.using == .udp {   // asked for UDP, got interleaved: read it off the connection
                    self.udp?.cancel()
                    self.udp = nil
                    self.using = .tcp
                }
            }
            JcLog.devices.notice("Dashcam live: SETUP over \(self.using.rawValue, privacy: .public) — \(reply, privacy: .public)")
            self.play(sdp)
        }
    }

    private func play(_ sdp: RTSPSessionDescription) {
        playURL = DashcamRTSP.resolve(control: sdp.sessionControl, base: baseURL)
        send("PLAY", playURL, headers: [("Range", "npt=0.000-")]) { [weak self] response in
            guard let self else { return }
            guard response.status == 200 else {
                return self.fail("The camera wouldn't play the stream (\(response.status) \(response.reason))", canFallBack: true)
            }
            self.playing = true
            self.playStartedAt = Date()
            self.lastProgress = Date()
            self.startKeepalive()
            if self.using == .udp { self.startReceiverReports() }
        }
    }

    private func startKeepalive() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + keepaliveInterval, repeating: keepaliveInterval)
        t.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            if self.useGetParameter {
                self.send("GET_PARAMETER", self.playURL) { [weak self] response in
                    if [400, 405, 501].contains(response.status) { self?.useGetParameter = false }
                }
            } else {
                self.send("OPTIONS", self.requestURL) { _ in }
            }
        }
        t.resume()
        timers.append(t)
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return String(cString: strerror(code.rawValue))
        default: return "\(error)"
        }
    }
}
