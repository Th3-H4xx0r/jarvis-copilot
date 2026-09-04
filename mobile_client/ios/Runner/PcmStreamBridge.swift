import Foundation
import AVFoundation
import Flutter

// Gapless playback of the realtime reply PCM (24 kHz s16le mono) — plan 1.7.
//
// Feeding each arriving chunk to AVAudioPlayerNode.scheduleBuffer keeps ONE
// continuous render stream, so chunk seams are inaudible. The previous
// approach (a temp WAV file + a fresh play() per 160/500 ms slice) paid a
// player stop/start on every slice, which is the "cuts out every second"
// stutter heard on the phone.
//
// Contract — MethodChannel `jarviscopilot/pcm_stream`:
//   ping()                 -> true
//   start({sampleRate})    -> Bool
//   feed({bytes})          -> Bool   (Int16 little-endian mono)
//   flush()                -> nil    (drop what's queued, keep the stream open)
//   stop()                 -> nil
//
// Audio session: NOT configured here — VoiceController owns it
// (.playAndRecord + .videoChat). The engine renders into the active session.
final class PcmStreamBridge: NSObject {

    static let shared = PcmStreamBridge()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private let work = DispatchQueue(label: "jarviscopilot.pcmstream")

    static func register(messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(
            name: "jarviscopilot/pcm_stream", binaryMessenger: messenger
        ).setMethodCallHandler { call, result in
            shared.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "ping":
            result(true)
        case "start":
            let sr = (args["sampleRate"] as? NSNumber)?.doubleValue ?? 24_000
            work.async {
                let ok = self.start(sampleRate: sr)
                DispatchQueue.main.async { result(ok) }
            }
        case "feed":
            guard let typed = args["bytes"] as? FlutterStandardTypedData else {
                result(false); return
            }
            let data = typed.data
            work.async {
                let ok = self.feed(data)
                DispatchQueue.main.async { result(ok) }
            }
        case "flush":
            work.async {
                self.flush()
                DispatchQueue.main.async { result(nil) }
            }
        case "stop":
            work.async {
                self.stop()
                DispatchQueue.main.async { result(nil) }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func start(sampleRate: Double) -> Bool {
        stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false
        ) else { return false }
        engine.attach(player)
        // The mixer resamples 24 kHz mono to whatever the output runs at.
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return false
        }
        player.play()
        self.engine = engine
        self.player = player
        self.format = format
        return true
    }

    private func feed(_ data: Data) -> Bool {
        guard let player = player, let format = format, let engine = engine else { return false }
        let frames = data.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                channel[i] = Float(Int16(littleEndian: src[i])) / 32768.0
            }
        }
        if !engine.isRunning {
            // Media-services reset or an interruption stopped us; bring it back.
            do { try engine.start() } catch { return false }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
        return true
    }

    private func flush() {
        guard let player = player else { return }
        // stop() discards every scheduled buffer; play() re-arms for the next feed.
        player.stop()
        player.play()
    }

    private func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        format = nil
    }
}
