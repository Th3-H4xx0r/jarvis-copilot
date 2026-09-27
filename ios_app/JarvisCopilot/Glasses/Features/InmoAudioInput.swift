import AVFoundation
import Foundation

/// Receives only GO3 PCM. A missing stream remains missing; it cannot open a phone mic.
@MainActor
final class InmoAudioInput: AudioInput {
    var onFrame: ((Data) -> Void)?
    private(set) var isRunning = false
    func requestPermission() async -> Bool { true }
    func start(sampleRate: Int) async throws {
        guard sampleRate == 16000 else { throw InmoAudioError.unsupportedFormat }
        isRunning = true
    }
    func stop() async { isRunning = false }
    func receive(_ pcm: Data) { if isRunning { onFrame?(pcm) } }
}

enum InmoAudioError: Error { case unsupportedFormat, invalidPacket, decoderUnavailable, decodeFailed }

/// Raw Opus packets, not an Ogg file. The converter owns codec state across packets.
final class InmoOpusDecoder {
    private let converter: AVAudioConverter
    private let compressed: AVAudioFormat
    private let pcm: AVAudioFormat
    init() throws {
        var description = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                         channels: 1, interleaved: true),
              let decoder = AVAudioConverter(from: input, to: output) else {
            throw InmoAudioError.decoderUnavailable
        }
        compressed = input; pcm = output; converter = decoder
    }
    func decode(_ packet: Data) throws -> Data {
        guard !packet.isEmpty, packet.count <= 1275 else { throw InmoAudioError.invalidPacket }
        let input = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
        input.byteLength = UInt32(packet.count); input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0,
            mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 5760) else {
            throw InmoAudioError.decodeFailed
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard error == nil, result != .error, output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else { throw InmoAudioError.decodeFailed }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}
