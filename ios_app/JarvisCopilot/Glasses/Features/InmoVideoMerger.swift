import AVFoundation
import Foundation
import ImageIO
import UIKit

/// The glasses' `.opus` sound files: raw Opus packets (16 kHz mono, 20 ms each) separated by the
/// three bytes `\n\n\n` — no Ogg container. The INMO app splits them the same way
/// (`FileUtils.convertOpusWithEnterFileToPcm`). Real files start with two empty pieces.
enum InmoOpusFile {
    static let separator: [UInt8] = [0x0a, 0x0a, 0x0a]
    /// One packet's worth of silence: 20 ms at 16 kHz, PCM16.
    static let silentPacket = Data(count: 320 * 2)

    /// A packet can itself end in 0x0a (about 1 in 256), giving a run of 4–5 newlines; a packet
    /// never starts with one (the glasses' TOC byte is 0xb8), so a run's leftover newlines belong
    /// to the end of the packet before it. Splitting at the first three would cut that packet short
    /// and start the next with a bogus TOC byte.
    static func packets(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var packets: [Data] = []
        var start = 0, i = 0
        while i < bytes.count {
            guard bytes[i] == 0x0a else { i += 1; continue }
            var end = i
            while end < bytes.count, bytes[end] == 0x0a { end += 1 }
            let run = end - i
            if run >= separator.count {
                let packetEnd = i + (start == 0 && i == 0 ? 0 : run % separator.count)
                if packetEnd > start { packets.append(Data(bytes[start..<packetEnd])) }
                start = end
            }
            i = end
        }
        if start < bytes.count { packets.append(Data(bytes[start...])) }
        return packets
    }

    /// PCM16 16 kHz mono. A packet that won't decode becomes 20 ms of silence so the sound stays
    /// in step with the picture; `failed` counts them.
    static func pcm(_ data: Data) throws -> (pcm: Data, packets: Int, failed: Int) {
        let decoder = try InmoOpusDecoder()
        let list = packets(data)
        var pcm = Data(), failed = 0
        for packet in list {
            if let decoded = try? decoder.decode(packet) { pcm.append(decoded) } else { pcm.append(silentPacket); failed += 1 }
        }
        return (pcm, list.count, failed)
    }
}

enum InmoVideoMerger {
    /// Writes one movie to `output`: the picture with the glasses' sound as AAC. Returns true when the
    /// sound made it in. On any failure the picture-only file is copied to `output` and it returns
    /// false — footage is never dropped because the sound couldn't be merged.
    static func merge(video: URL, opus: URL?, to output: URL) async -> Bool {
        try? FileManager.default.removeItem(at: output)
        let audio = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            guard let opus else { throw InmoMediaError(message: "No sound file") }
            let decoded = try InmoOpusFile.pcm(try Data(contentsOf: opus))
            guard decoded.packets > 0, decoded.failed < decoded.packets else { throw InmoMediaError(message: "Sound would not decode") }
            try writeAAC(decoded.pcm, to: audio)
            try await mux(video: video, audio: audio, to: output)
            return true
        } catch {
            try? FileManager.default.removeItem(at: output)
            do { try FileManager.default.copyItem(at: video, to: output) } catch { return false }
            return false
        }
    }

    private static func writeAAC(_ pcm: Data, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            throw InmoAudioError.unsupportedFormat
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = pcm.count / 2
        let chunk = 16000
        var offset = 0
        while offset < frames {
            let count = min(chunk, frames - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.int16ChannelData?[0] else { throw InmoAudioError.decodeFailed }
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<count { channel[i] = samples[offset + i] }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }

    /// Picture track as is (no re-encode) plus the sound, cut to the picture's length.
    private static func mux(video: URL, audio: URL, to output: URL) async throws {
        let picture = AVURLAsset(url: video), sound = AVURLAsset(url: audio)
        guard let videoTrack = try await picture.loadTracks(withMediaType: .video).first,
              let audioTrack = try await sound.loadTracks(withMediaType: .audio).first else {
            throw InmoMediaError(message: "Missing track")
        }
        let length = try await picture.load(.duration)
        let soundLength = try await sound.load(.duration)
        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw InmoMediaError(message: "Could not build the movie")
        }
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: videoTrack, at: .zero)
        v.preferredTransform = try await videoTrack.load(.preferredTransform)
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(length, soundLength)), of: audioTrack, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw InmoMediaError(message: "Could not export the movie")
        }
        if #available(iOS 18.0, *) {
            try await export.export(to: output, as: .mp4)
        } else {
            export.outputURL = output
            export.outputFileType = .mp4
            await export.export()
            if let error = export.error { throw error }
            guard export.status == .completed else { throw InmoMediaError(message: "Movie export did not finish") }
        }
    }
}

enum InmoMediaThumbnail {
    /// A small JPEG for the gallery tile, and a video's length.
    static func make(_ file: URL, kind: InmoGalleryKind, maxPixel: Int = 400) async throws -> (jpeg: Data, duration: Double?) {
        let image: CGImage
        var duration: Double?
        switch kind {
        case .photo:
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw InmoMediaError(message: "Could not read the photo")
            }
            image = thumb
        case .video:
            let asset = AVURLAsset(url: file)
            let seconds = try await asset.load(.duration).seconds
            duration = seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            let at = CMTime(seconds: min(0.5, seconds / 2), preferredTimescale: 600)
            image = try await generator.image(at: at).image
        }
        guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else {
            throw InmoMediaError(message: "Could not make a preview")
        }
        return (jpeg, duration)
    }
}
