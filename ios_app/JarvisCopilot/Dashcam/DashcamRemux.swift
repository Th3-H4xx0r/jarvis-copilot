import AVFoundation
import CoreMedia
import Foundation

/// The A4 records MPEG transport streams (`.ts`), which AVFoundation can only play inside HLS.
/// This turns one into an MP4 by copying the H.264/H.265 frames and AAC audio as they are (no
/// re-encoding, so it is fast and lossless), and collects the Viidure `VV-GPSINFO` GPS lines from
/// the same pass (protocol.md §5: GPS rides in its own 188-byte TS packets).
enum DashcamRemux {
    struct Result: Equatable {
        let output: URL
        let duration: Double
        let fixes: [DashcamFix]
        let codec: String          // "h264" | "hevc"
        let hasAudio: Bool
    }

    enum Failure: LocalizedError, Equatable {
        case notTransportStream, noVideo, unsupported(String), writer(String)
        var errorDescription: String? {
            switch self {
            case .notTransportStream: return "not an MPEG transport stream"
            case .noVideo: return "no video in this clip"
            case .unsupported(let s): return "unsupported video (\(s))"
            case .writer(let s): return "couldn't write the MP4: \(s)"
            }
        }
    }

    static let packet = 188
    static let gpsMarker = Array("VV-GPSINFO".utf8)

    // MARK: GPS only

    /// GPS lines from any slice of a transport stream (a whole file or a window read off the camera).
    static func gpsLines(in data: Data) -> [String] {
        let b = [UInt8](data)
        guard b.count >= packet else { return [] }
        // Packet alignment: a sync byte that repeats every 188 bytes (three in a row when the window allows,
        // since 0x47 also turns up inside payloads).
        var start = -1
        for i in 0..<min(packet, b.count - packet) where b[i] == 0x47 && b[i + packet] == 0x47
            && (i + 2 * packet >= b.count || b[i + 2 * packet] == 0x47) {
            start = i; break
        }
        guard start >= 0 else { return [] }
        var out: [String] = []
        var off = start
        while off + packet <= b.count {
            if b[off] == 0x47, b[off + 20] == 0x56, Array(b[(off + 20)..<(off + 30)]) == gpsMarker {
                var end = off + 31
                while end < min(b.count, off + 31 + 160), b[end] != 0 { end += 1 }
                let line = String(decoding: b[(off + 31)..<end], as: UTF8.self)
                if DashcamGPS.lineValid(line) { out.append(line) }
            }
            off += packet
        }
        return out
    }

    /// The GPS block at the end of a local clip (the same one the sync reads off the camera with range requests).
    static func tailFixes(_ url: URL) -> [DashcamFix] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard let total = try? h.seekToEnd(), total >= 8,
              (try? h.seek(toOffset: total - 8)) != nil, let last = try? h.read(upToCount: 8),
              let (marker, size) = DashcamGPS.parseTail(last), UInt64(size) <= total,
              (try? h.seek(toOffset: total - UInt64(size))) != nil, let block = try? h.read(upToCount: size)
        else { return [] }
        return DashcamGPS.parseBlock(block, marker: marker)
    }

    // MARK: Transport stream parsing

    /// One elementary-stream unit (a PES packet's payload) with its timestamps (90 kHz).
    struct PES { var data = [UInt8](); var pts: Int64?; var dts: Int64? }

    enum StreamKind { case h264, hevc, aac }

    /// A streaming TS demuxer: feed bytes, get PES units per elementary stream.
    final class Demuxer {
        private var pmtPID: Int?
        private(set) var streams: [Int: StreamKind] = [:]
        private var pending: [Int: PES] = [:]
        private var carry = [UInt8]()
        private var lost = false
        private(set) var gps: [String] = []
        var onPES: (StreamKind, PES) -> Void = { _, _ in }

        func feed(_ chunk: Data) {
            carry.append(contentsOf: chunk)
            var off = 0
            while off + DashcamRemux.packet <= carry.count {
                guard carry[off] == 0x47 else { lost = true; off += 1; continue }
                // After losing sync (the A4 ends every clip with GPS boxes that aren't TS packets), only a
                // sync byte the next packet confirms counts.
                if lost {
                    guard off + DashcamRemux.packet < carry.count, carry[off + DashcamRemux.packet] == 0x47 else { off += 1; continue }
                    lost = false
                }
                parse(carry, at: off)
                off += DashcamRemux.packet
            }
            carry.removeFirst(off)
        }

        func finish() {
            for (pid, pes) in pending { if let kind = streams[pid], !pes.data.isEmpty { onPES(kind, pes) } }
            pending.removeAll()
        }

        private func parse(_ b: [UInt8], at o: Int) {
            if b[o + 20] == 0x56, Array(b[(o + 20)..<(o + 30)]) == DashcamRemux.gpsMarker {
                var end = o + 31
                while end < min(b.count, o + 31 + 156), b[end] != 0 { end += 1 }
                let line = String(decoding: b[(o + 31)..<end], as: UTF8.self)
                if DashcamGPS.lineValid(line) { gps.append(line) }
                return
            }
            let pusi = b[o + 1] & 0x40 != 0
            let pid = Int(b[o + 1] & 0x1F) << 8 | Int(b[o + 2])
            let afc = (b[o + 3] >> 4) & 0x3
            var p = o + 4
            if afc == 2 || afc == 0 { return }               // no payload
            if afc == 3 { p += 1 + Int(b[o + 4]) }           // skip adaptation field
            let end = o + DashcamRemux.packet
            guard p < end else { return }
            if pid == 0 {
                if pusi { p += 1 + Int(b[p]) }               // pointer field
                parsePAT(Array(b[p..<end]))
            } else if pid == pmtPID {
                if pusi { p += 1 + Int(b[p]) }
                parsePMT(Array(b[p..<end]))
            } else if streams[pid] != nil {
                if pusi {
                    if let done = pending[pid], let kind = streams[pid], !done.data.isEmpty { onPES(kind, done) }
                    pending[pid] = Self.pesHeader(Array(b[p..<end]))
                } else if pending[pid] != nil {
                    pending[pid]!.data.append(contentsOf: b[p..<end])
                }
            }
        }

        private func parsePAT(_ s: [UInt8]) {
            guard s.count >= 12, s[0] == 0x00 else { return }
            let length = Int(s[1] & 0x0F) << 8 | Int(s[2])
            var i = 8
            while i + 4 <= min(s.count, 3 + length - 4) {
                let program = Int(s[i]) << 8 | Int(s[i + 1])
                let pid = Int(s[i + 2] & 0x1F) << 8 | Int(s[i + 3])
                if program != 0 { pmtPID = pid; return }
                i += 4
            }
        }

        private func parsePMT(_ s: [UInt8]) {
            guard s.count >= 12, s[0] == 0x02 else { return }
            let length = Int(s[1] & 0x0F) << 8 | Int(s[2])
            let infoLength = Int(s[10] & 0x0F) << 8 | Int(s[11])
            var i = 12 + infoLength
            let stop = min(s.count, 3 + length - 4)
            while i + 5 <= stop {
                let type = s[i]
                let pid = Int(s[i + 1] & 0x1F) << 8 | Int(s[i + 2])
                let esInfo = Int(s[i + 3] & 0x0F) << 8 | Int(s[i + 4])
                switch type {
                case 0x1B: streams[pid] = .h264
                case 0x24: streams[pid] = .hevc
                case 0x0F: streams[pid] = .aac
                default: break
                }
                i += 5 + esInfo
            }
        }

        static func pesHeader(_ s: [UInt8]) -> PES {
            guard s.count >= 9, s[0] == 0, s[1] == 0, s[2] == 1 else { return PES(data: s) }
            let flags = s[7]
            let headerLength = Int(s[8])
            func ts(_ i: Int) -> Int64? {
                guard i + 5 <= s.count else { return nil }
                let a = Int64(s[i] & 0x0E) << 29
                let b = Int64(s[i + 1]) << 22 | Int64(s[i + 2] & 0xFE) << 14
                let c = Int64(s[i + 3]) << 7 | Int64(s[i + 4] >> 1)
                return a | b | c
            }
            var pes = PES()
            if flags & 0x80 != 0 { pes.pts = ts(9) }
            if flags & 0x40 != 0 { pes.dts = ts(14) }
            let start = min(s.count, 9 + headerLength)
            pes.data = Array(s[start...])
            return pes
        }
    }

    // MARK: Elementary streams

    /// Annex B → NAL units (start codes 00 00 01 / 00 00 00 01).
    static func nalUnits(_ d: [UInt8]) -> [ArraySlice<UInt8>] {
        var out: [ArraySlice<UInt8>] = []
        var i = 0, start = -1
        while i + 2 < d.count {
            if d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 {
                if start >= 0 {
                    var e = i
                    if e > start, d[e - 1] == 0 { e -= 1 }   // 4-byte start code
                    if e > start { out.append(d[start..<e]) }
                }
                i += 3; start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < d.count { out.append(d[start...]) }
        return out
    }

    static func nalType(_ n: ArraySlice<UInt8>, _ kind: StreamKind) -> Int {
        guard let f = n.first else { return -1 }
        return kind == .h264 ? Int(f & 0x1F) : Int((f >> 1) & 0x3F)
    }

    static func isParameterSet(_ t: Int, _ kind: StreamKind) -> Bool {
        kind == .h264 ? (t == 7 || t == 8) : (t >= 32 && t <= 34)
    }

    static func isKeyframe(_ t: Int, _ kind: StreamKind) -> Bool {
        kind == .h264 ? t == 5 : (t >= 16 && t <= 21)
    }

    static func isDelimiter(_ t: Int, _ kind: StreamKind) -> Bool {
        kind == .h264 ? t == 9 : t == 35
    }

    /// Parameter sets in the order CoreMedia wants: H.264 SPS, PPS; HEVC VPS, SPS, PPS.
    static func formatDescription(_ sets: [Int: [UInt8]], _ kind: StreamKind) -> CMVideoFormatDescription? {
        let order = kind == .h264 ? [7, 8] : [32, 33, 34]
        let ps = order.compactMap { sets[$0] }
        guard ps.count == order.count else { return nil }
        var desc: CMVideoFormatDescription?
        let pointers = ps.map { set -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return UnsafePointer(p)
        }
        defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        let sizes = ps.map(\.count)
        let status: OSStatus = kind == .h264
            ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: ps.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: ps.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        return status == noErr ? desc : nil
    }

    /// ADTS frames → (AAC payloads, sample rate, channels, AudioSpecificConfig).
    static func adtsFrames(_ d: [UInt8]) -> (frames: [ArraySlice<UInt8>], rate: Double, channels: UInt32, asc: [UInt8])? {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        var frames: [ArraySlice<UInt8>] = []
        var info: (Double, UInt32, [UInt8])?
        var i = 0
        while i + 7 <= d.count {
            guard d[i] == 0xFF, d[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
            let protectionAbsent = d[i + 1] & 0x01 == 1
            let profile = (d[i + 2] >> 6) & 0x3
            let freqIndex = Int((d[i + 2] >> 2) & 0xF)
            let channels = UInt32((d[i + 2] & 0x1) << 2 | (d[i + 3] >> 6))
            let length = Int(d[i + 3] & 0x3) << 11 | Int(d[i + 4]) << 3 | Int(d[i + 5] >> 5)
            let header = protectionAbsent ? 7 : 9
            guard length > header, i + length <= d.count, freqIndex < rates.count else { break }
            if info == nil {
                let objectType = UInt8(profile + 1)
                let asc = [objectType << 3 | UInt8(freqIndex >> 1), UInt8(freqIndex & 1) << 7 | UInt8(channels) << 3]
                info = (rates[freqIndex], max(channels, 1), asc)
            }
            frames.append(d[(i + header)..<(i + length)])
            i += length
        }
        guard let info else { return nil }
        return (frames, info.0, info.1, info.2)
    }

    /// CoreMedia's AAC magic cookie is an MPEG-4 ES_Descriptor around the AudioSpecificConfig. Given the bare
    /// two-byte config, AVAssetWriter writes an `esds` AVFoundation can't read and the audio track vanishes.
    static func esds(_ asc: [UInt8]) -> [UInt8] {
        let specific: [UInt8] = [0x05, UInt8(asc.count)] + asc
        // objectType 0x40 (MPEG-4 audio), streamType audio, then buffer size / max / average bitrate left at 0.
        let decoder: [UInt8] = [0x04, UInt8(13 + specific.count), 0x40, 0x15] + [UInt8](repeating: 0, count: 11) + specific
        let body: [UInt8] = [0, 0, 0] + decoder + [0x06, 0x01, 0x02]   // ES_ID 0, no flags; SL config "MP4"
        return [0x03, UInt8(body.count)] + body
    }

    // MARK: Remux

    /// `.ts` → `.mp4` at `mp4` (written beside it as a hidden part file, moved into place only when complete).
    static func remux(ts: URL, to mp4: URL, chunk: Int = 1 << 20) async throws -> Result {
        try await Task.detached(priority: .userInitiated) { try remuxSync(ts: ts, to: mp4, chunk: chunk) }.value
    }

    static func remuxSync(ts: URL, to mp4: URL, chunk: Int = 1 << 20) throws -> Result {
        let handle = try FileHandle(forReadingFrom: ts)
        defer { try? handle.close() }
        let first = try handle.read(upToCount: packet * 2) ?? Data()
        guard first.count >= packet * 2, first[0] == 0x47, first[packet] == 0x47 else { throw Failure.notTransportStream }
        try handle.seek(toOffset: 0)

        let tmp = mp4.deletingLastPathComponent().appendingPathComponent(".\(mp4.lastPathComponent).part")
        try FileManager.default.createDirectory(at: mp4.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: tmp)
        let muxer = Muxer(output: tmp)
        let demux = Demuxer()
        demux.onPES = { kind, pes in muxer.take(kind, pes, audioExpected: demux.streams.values.contains(.aac)) }
        while muxer.failure == nil, let data = try handle.read(upToCount: chunk), !data.isEmpty {
            autoreleasepool { demux.feed(data) }
        }
        demux.finish()
        let done = try muxer.finish()
        try? FileManager.default.removeItem(at: mp4)
        try FileManager.default.moveItem(at: tmp, to: mp4)
        var fixes = demux.gps.compactMap { DashcamGPS.parseLine($0) }
        if fixes.isEmpty { fixes = tailFixes(ts) }
        return Result(output: mp4, duration: done.duration, fixes: fixes, codec: done.codec, hasAudio: done.hasAudio)
    }

    /// Elementary-stream units in, MP4 out. Formats are learnt from the stream (SPS/PPS, ADTS headers),
    /// so samples wait in a backlog until the writer can start.
    final class Muxer {
        let output: URL
        private(set) var failure: Error?
        private var videoKind: StreamKind?
        private var sets: [Int: [UInt8]] = [:]
        private var videoFormat: CMVideoFormatDescription?
        private var audioFormat: CMAudioFormatDescription?
        private var audioRate = 0.0
        private var writer: AVAssetWriter?
        private var videoInput: AVAssetWriterInput?
        private var audioInput: AVAssetWriterInput?
        private var videoQueue: [CMSampleBuffer] = []
        private var audioQueue: [CMSampleBuffer] = []
        private var lastVideo: (data: [UInt8], pts: Int64, dts: Int64, key: Bool)?
        private var lastVideoDuration: Int64 = 3000
        private var firstPTS: Int64?
        private var lastPTS: Int64 = 0
        private var wrap: [Int: (last: Int64, add: Int64)] = [:]

        init(output: URL) { self.output = output }

        /// 33-bit PTS/DTS wrap (every ~26.5 h of camera uptime) → a monotonic 90 kHz clock.
        private func unwrapped(_ t: Int64?, _ slot: Int) -> Int64? {
            guard let t else { return nil }
            var state = wrap[slot] ?? (t, 0)
            if t < state.last - (1 << 32) { state.add += 1 << 33 }
            state.last = t
            wrap[slot] = state
            return t + state.add
        }

        private static func time(_ t: Int64) -> CMTime { CMTime(value: t, timescale: 90000) }

        private static func block(_ bytes: [UInt8]) -> CMBlockBuffer? {
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                                     blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
                  let block,
                  bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                        offsetIntoDestination: 0, dataLength: bytes.count) }) == noErr
            else { return nil }
            return block
        }

        private func videoSample(_ v: (data: [UInt8], pts: Int64, dts: Int64, key: Bool), duration: Int64) -> CMSampleBuffer? {
            guard let videoFormat, let block = Self.block(v.data) else { return nil }
            var timing = CMSampleTimingInfo(duration: Self.time(duration), presentationTimeStamp: Self.time(v.pts),
                                            decodeTimeStamp: Self.time(v.dts))
            var size = v.data.count
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: videoFormat,
                                            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                  let sample else { return nil }
            if !v.key, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            return sample
        }

        private func audioSample(_ frame: ArraySlice<UInt8>, pts: Int64) -> CMSampleBuffer? {
            guard let audioFormat, let block = Self.block(Array(frame)) else { return nil }
            var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
            var sample: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                       formatDescription: audioFormat, sampleCount: 1,
                                                                       presentationTimeStamp: Self.time(pts), packetDescriptions: &desc,
                                                                       sampleBufferOut: &sample) == noErr else { return nil }
            return sample
        }

        func take(_ kind: StreamKind, _ pes: PES, audioExpected: Bool) {
            guard failure == nil else { return }
            switch kind {
            case .h264, .hevc: takeVideo(kind, pes)
            case .aac: takeAudio(pes)
            }
            // Don't hold more than a few seconds of video waiting for an audio format that may never parse.
            startIfReady(force: !audioExpected || videoQueue.count > 150)
            drain()
        }

        private func takeVideo(_ kind: StreamKind, _ pes: PES) {
            if videoKind == nil { videoKind = kind }
            guard kind == videoKind, let pts = unwrapped(pes.pts, 0) else { return }
            let dts = unwrapped(pes.dts, 1) ?? pts
            var avcc = [UInt8]()
            avcc.reserveCapacity(pes.data.count + 16)
            var key = false
            for nal in DashcamRemux.nalUnits(pes.data) {
                let t = DashcamRemux.nalType(nal, kind)
                if DashcamRemux.isParameterSet(t, kind) {
                    if videoFormat == nil, sets[t] != Array(nal) {
                        sets[t] = Array(nal)
                        videoFormat = DashcamRemux.formatDescription(sets, kind)
                    }
                    continue
                }
                if DashcamRemux.isDelimiter(t, kind) { continue }
                if DashcamRemux.isKeyframe(t, kind) { key = true }
                let n = UInt32(nal.count)
                avcc += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
                avcc += nal
            }
            guard !avcc.isEmpty, videoFormat != nil else { return }   // nothing decodable before the first parameter sets
            if firstPTS == nil { guard key else { return }; firstPTS = pts }
            lastPTS = max(lastPTS, pts)
            if let prev = lastVideo {
                lastVideoDuration = max(1, dts - prev.dts)
                if let s = videoSample(prev, duration: lastVideoDuration) { videoQueue.append(s) }
            }
            lastVideo = (avcc, pts, dts, key)
        }

        private func takeAudio(_ pes: PES) {
            guard let pts = unwrapped(pes.pts, 2), let parsed = DashcamRemux.adtsFrames(pes.data) else { return }
            if audioFormat == nil, writer == nil {
                audioRate = parsed.rate
                var asbd = AudioStreamBasicDescription(mSampleRate: parsed.rate, mFormatID: kAudioFormatMPEG4AAC,
                                                       mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                                       mBytesPerFrame: 0, mChannelsPerFrame: parsed.channels,
                                                       mBitsPerChannel: 0, mReserved: 0)
                var fmt: CMAudioFormatDescription?
                let cookie = DashcamRemux.esds(parsed.asc)
                _ = cookie.withUnsafeBytes { raw in
                    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                   magicCookieSize: cookie.count, magicCookie: raw.baseAddress,
                                                   extensions: nil, formatDescriptionOut: &fmt)
                }
                audioFormat = fmt
            }
            guard let start = firstPTS, audioFormat != nil, audioRate > 0 else { return }   // audio before the first keyframe is dropped
            for (n, frame) in parsed.frames.enumerated() {
                let t = pts + Int64(Double(n) * 1024 / audioRate * 90000)
                if t >= start, let s = audioSample(frame, pts: t) { audioQueue.append(s) }
            }
        }

        private func startIfReady(force: Bool) {
            guard writer == nil, failure == nil, let videoFormat, let start = firstPTS else { return }
            guard force || audioFormat != nil else { return }
            do {
                let w = try AVAssetWriter(outputURL: output, fileType: .mp4)
                w.shouldOptimizeForNetworkUse = true
                let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
                vi.expectsMediaDataInRealTime = false
                guard w.canAdd(vi) else { throw Failure.writer("video track refused") }
                w.add(vi)
                if let audioFormat {
                    let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
                    ai.expectsMediaDataInRealTime = false
                    if w.canAdd(ai) { w.add(ai); audioInput = ai }
                }
                guard w.startWriting() else { throw Failure.writer(w.error?.localizedDescription ?? "start") }
                w.startSession(atSourceTime: Self.time(start))
                writer = w
                videoInput = vi
                if audioInput == nil { audioQueue.removeAll() }
            } catch {
                failure = error
            }
        }

        /// Feed whichever track the writer is ready for. The writer interleaves, so it can refuse one track until
        /// the other catches up — waiting on a single track here could deadlock.
        private func drain(final: Bool = false) {
            guard let writer, failure == nil else { return }
            var idle = 0
            while failure == nil {
                var moved = false
                if let vi = videoInput, !videoQueue.isEmpty, vi.isReadyForMoreMediaData {
                    if !vi.append(videoQueue.removeFirst()) { failure = Failure.writer(writer.error?.localizedDescription ?? "video append") }
                    moved = true
                }
                if let ai = audioInput, !audioQueue.isEmpty, ai.isReadyForMoreMediaData {
                    if !ai.append(audioQueue.removeFirst()) { failure = Failure.writer(writer.error?.localizedDescription ?? "audio append") }
                    moved = true
                }
                if final {
                    // A finished track stops holding the other back.
                    if videoQueue.isEmpty, let vi = videoInput { vi.markAsFinished(); videoInput = nil }
                    if audioQueue.isEmpty, let ai = audioInput { ai.markAsFinished(); audioInput = nil }
                    if videoInput == nil && audioInput == nil { return }
                }
                if moved { idle = 0; continue }
                if !final && videoQueue.count + audioQueue.count < 600 { return }   // more input is coming; keep demuxing
                idle += 1
                if idle < 3000 { usleep(1000); continue }
                // ~3 s with nothing accepted: the writer is waiting on a track that has nothing to give.
                if !final, audioQueue.isEmpty, let ai = audioInput { ai.markAsFinished(); audioInput = nil; idle = 0; continue }
                failure = Failure.writer("writer stalled")
            }
        }

        func finish() throws -> (duration: Double, codec: String, hasAudio: Bool) {
            if let failure { throw failure }
            guard let kind = videoKind, videoFormat != nil, let start = firstPTS else { throw Failure.noVideo }
            if let prev = lastVideo, let s = videoSample(prev, duration: lastVideoDuration) { videoQueue.append(s) }
            lastVideo = nil
            startIfReady(force: true)
            guard let writer else { throw failure ?? Failure.writer("no writer") }
            let hasAudio = audioInput != nil
            drain(final: true)
            if let failure { writer.cancelWriting(); throw failure }
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else {
                throw Failure.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
            }
            return (Double(lastPTS - start + lastVideoDuration) / 90000, kind == .h264 ? "h264" : "hevc", hasAudio)
        }
    }
}

/// Playable MP4 copies of `.ts` clips, made when a clip is opened and kept in Caches (iOS may purge them;
/// they are remade in seconds). The `.ts` stays the copy that syncs and uploads.
enum DashcamPlayable {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DashcamPlayback", isDirectory: true)
    }
    static let keep = 8

    static func needsRemux(_ url: URL) -> Bool { url.pathExtension.lowercased() == "ts" }

    /// One cache name per clip: its path under the phone's dashcam folder, flattened.
    static func cacheURL(for local: URL, in dir: URL = directory) -> URL {
        let parts = local.deletingPathExtension().pathComponents.suffix(5)
        return dir.appendingPathComponent(parts.joined(separator: "_") + ".mp4")
    }

    /// A URL AVPlayer can play for this local clip, and the remux result when one was just made.
    static func prepare(_ local: URL, in dir: URL = directory) async throws -> (url: URL, made: DashcamRemux.Result?) {
        guard needsRemux(local) else { return (local, nil) }
        let out = cacheURL(for: local, in: dir)
        let fm = FileManager.default
        if let made = (try? out.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           let source = (try? local.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           made >= source {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: out.path)   // most recently used
            return (out, nil)
        }
        let result = try await DashcamRemux.remux(ts: local, to: out)
        prune(dir, keeping: out)
        return (out, result)
    }

    /// Oldest copies go once there are more than `keep`.
    static func prune(_ dir: URL, keeping: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let copies = names.filter { $0.pathExtension == "mp4" && $0.lastPathComponent != keeping.lastPathComponent }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
        for old in copies.dropFirst(max(0, keep - 1)) { try? fm.removeItem(at: old) }
    }
}
