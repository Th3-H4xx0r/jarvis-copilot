import AVFoundation
import Foundation

/// PCM16 → Opus, using CoreAudio's own encoder through `AVAudioConverter`.
///
/// ## Why this exists
///
/// Live Jarvis keeps everything indefinitely, so the uplink rate IS the archive
/// rate. Raw PCM16 at 16 kHz is ~115 MB/hour; Opus at 24 kbps is ~11 MB/hour —
/// about 300 GB/year against 31 GB/year at eight hours a day. That is the
/// difference between a feature that can be left on and one that cannot.
///
/// No package dependency: `kAudioFormatOpus` is in CoreAudioTypes and
/// `AVAudioConverter` will encode to it.
///
/// ## Wire format
///
/// `encode` returns the packets of one input chunk, each prefixed with its length
/// as a 4-byte BIG-ENDIAN integer — the server's `opus-packets-len32@<rate>`
/// framing. Opus is inherently packetised and VBR, so a bare concatenation would
/// be undecodable; the length prefix is what makes a chunk self-delimiting.
///
/// ## Honesty
///
/// Everything here can fail on a given OS version, and a failure must NEVER be
/// papered over — sending PCM while claiming Opus would corrupt every stored
/// recording. `make()` returns nil when the format or the converter is refused,
/// `lastError` says why, and the caller falls back to PCM16 and declares PCM16.
@MainActor
final class AmbientOpusEncoder {

    /// Opus operates at 48 kHz internally; 48 kHz in is the case CoreAudio is
    /// happiest with, and the rate the server is told about.
    static let rate: Double = 48000
    /// 20 ms per packet at 48 kHz — the Opus default and the best size/latency
    /// trade for speech.
    static let framesPerPacket: UInt32 = 960
    /// Design §11's assumed archive rate.
    static let bitRate = 24000
    /// The largest an Opus packet can be.
    static let maxPacketBytes = 1275
    /// Packets one `convert` call may produce. An 85 ms tap chunk is ~5 packets;
    /// this leaves generous headroom.
    static let packetCapacity: UInt32 = 32

    /// What the caller declares in `hello`, and what the server uses to pick a
    /// decoder.
    var codecLabel: String { "opus-packets-len32@\(Int(Self.rate))" }

    /// Why encoding could not be set up, for the diagnostics and the status line.
    private(set) static var lastError = ""

    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    /// Input the converter asked for but that we could not supply yet. The encoder
    /// is stateful and packet-aligned: it pulls whole 20 ms frames, so a tap chunk
    /// that is not a whole number of packets leaves a remainder that belongs at the
    /// FRONT of the next chunk.
    private var pending = Data()

    /// Build an encoder, or nil when this OS will not do it.
    ///
    /// `sourceRate` is the rate the microphone path produces; the converter does the
    /// resample to 48 kHz as part of the same conversion.
    static func make(sourceRate: Double) -> AmbientOpusEncoder? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sourceRate,
                                         channels: 1,
                                         interleaved: true) else {
            lastError = "could not build a \(Int(sourceRate)) Hz mono PCM16 source format"
            return nil
        }
        guard let opus = opusFormat() else { return nil }
        guard let converter = AVAudioConverter(from: source, to: opus) else {
            lastError = "AVAudioConverter refused PCM16 \(Int(sourceRate)) Hz → Opus \(Int(rate)) Hz"
            return nil
        }
        // Best effort: an encoder that will not take a bitrate still encodes, just
        // at its own default.
        converter.bitRate = bitRate
        lastError = ""
        return AmbientOpusEncoder(converter: converter, source: source, opus: opus)
    }

    private init(converter: AVAudioConverter, source: AVAudioFormat, opus: AVAudioFormat) {
        self.converter = converter
        self.sourceFormat = source
        self.opusFormat = opus
    }

    /// The Opus output format. A compressed ASBD: only the rate, the format id, the
    /// channel count and the frames-per-packet are meaningful — every byte-size
    /// field stays 0 because the format is variable-bitrate.
    private static func opusFormat() -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = rate
        asbd.mFormatID = kAudioFormatOpus
        asbd.mFormatFlags = 0
        asbd.mBytesPerPacket = 0
        asbd.mFramesPerPacket = framesPerPacket
        asbd.mBytesPerFrame = 0
        asbd.mChannelsPerFrame = 1
        asbd.mBitsPerChannel = 0
        asbd.mReserved = 0
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            lastError = "this OS would not build an AVAudioFormat for kAudioFormatOpus"
            return nil
        }
        return format
    }

    /// Encode one chunk of mono PCM16 little-endian.
    ///
    /// Returns the length-prefixed packets it produced, which may be empty when the
    /// chunk did not complete a packet — that is normal, not a failure. Returns nil
    /// only when the encoder itself errored, which the caller treats as "stop
    /// claiming Opus".
    func encode(_ pcm: Data) -> Data? {
        pending.append(pcm)
        var out = Data()
        // Drain whole packets while there is enough input for one.
        while pending.count >= bytesPerPacketOfInput {
            guard let packets = convertOnePacket() else { return nil }
            if packets.isEmpty { break }
            out.append(packets)
        }
        return out
    }

    /// Flush whatever is buffered at the end of an utterance or a session, padded to
    /// a packet boundary so the tail is not lost.
    func flush() -> Data {
        guard !pending.isEmpty else { return Data() }
        let short = bytesPerPacketOfInput - pending.count
        if short > 0 { pending.append(Data(repeating: 0, count: short)) }
        let packets = convertOnePacket() ?? Data()
        pending.removeAll()
        return packets
    }

    /// How many source bytes make one 20 ms output packet, at the SOURCE rate.
    private var bytesPerPacketOfInput: Int {
        let framesIn = Double(Self.framesPerPacket) * sourceFormat.sampleRate / Self.rate
        return max(Int(framesIn.rounded()) * 2, 2)
    }

    private func convertOnePacket() -> Data? {
        let take = min(bytesPerPacketOfInput, pending.count)
        let chunk = pending.prefix(take)
        pending.removeFirst(take)

        let frames = AVAudioFrameCount(take / 2)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { return Data() }
        input.frameLength = frames
        chunk.withUnsafeBytes { bytes in
            if let dst = input.int16ChannelData?[0], let src = bytes.baseAddress {
                memcpy(dst, src, take)
            }
        }

        let compressed = AVAudioCompressedBuffer(format: opusFormat,
                                                 packetCapacity: Self.packetCapacity,
                                                 maximumPacketSize: Self.maxPacketBytes)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: compressed, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            Self.lastError = error?.localizedDescription ?? "the Opus encoder failed"
            return nil
        }
        return Self.lengthPrefixed(compressed)
    }

    /// Pull the packets out of a compressed buffer and length-prefix each one.
    ///
    /// `packetDescriptions` is the authority for a VBR format: the packets are laid
    /// end to end in `data` and only the descriptions say where each begins and ends.
    private static func lengthPrefixed(_ buffer: AVAudioCompressedBuffer) -> Data {
        var out = Data()
        let count = Int(buffer.packetCount)
        guard count > 0 else { return out }
        let base = buffer.data.assumingMemoryBound(to: UInt8.self)

        if let descriptions = buffer.packetDescriptions {
            for index in 0..<count {
                let description = descriptions[index]
                let size = Int(description.mDataByteSize)
                guard size > 0 else { continue }
                out.append(bigEndian32(UInt32(size)))
                out.append(Data(bytes: base + Int(description.mStartOffset), count: size))
            }
            return out
        }
        // No descriptions means constant-size packets, which Opus can also produce.
        let size = Int(buffer.byteLength) / count
        guard size > 0 else { return out }
        for index in 0..<count {
            out.append(bigEndian32(UInt32(size)))
            out.append(Data(bytes: base + index * size, count: size))
        }
        return out
    }

    static func bigEndian32(_ value: UInt32) -> Data {
        var out = Data(capacity: 4)
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
        return out
    }

    /// Split a length-prefixed payload back into packets. The tests' proof that the
    /// framing is self-delimiting; the server does the same thing.
    static func packets(in payload: Data) -> [Data]? {
        var packets: [Data] = []
        var index = payload.startIndex
        while index < payload.endIndex {
            guard payload.distance(from: index, to: payload.endIndex) >= 4 else { return nil }
            var length: UInt32 = 0
            for offset in 0..<4 { length = (length << 8) | UInt32(payload[index + offset]) }
            index = payload.index(index, offsetBy: 4)
            let size = Int(length)
            guard size > 0, payload.distance(from: index, to: payload.endIndex) >= size else {
                return nil
            }
            packets.append(payload.subdata(in: index..<payload.index(index, offsetBy: size)))
            index = payload.index(index, offsetBy: size)
        }
        return packets
    }
}
