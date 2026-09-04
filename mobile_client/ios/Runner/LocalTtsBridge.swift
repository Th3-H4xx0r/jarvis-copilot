import Foundation
import AVFoundation
import Flutter

// The phone's own synthesizer, for local acks (plan 4.4).
//
// A device action handled in Lane 0 ("flashlight on") must be confirmed out
// loud in the same breath. Going to /api/voice/synthesize for that would add a
// whole tunnel round-trip to an action that already finished — so the ack is
// spoken by AVSpeechSynthesizer instead. Real replies still use the JARVIS
// voice from the server.
//
// Contract — MethodChannel `jarviscopilot/local_tts`:
//   speak({text, rate}) -> Bool   (false when we couldn't say it)
//   stop()              -> nil
//
// Audio session: deliberately NOT configured here. VoiceController owns the
// AVAudioSession for the whole conversation (.playAndRecord + .videoChat) and
// past regressions all came from a second owner reconfiguring it. The
// synthesizer just plays into whatever session is already active, which is the
// speaker route we want.
final class LocalTtsBridge: NSObject {

    static let shared = LocalTtsBridge()

    private let synthesizer = AVSpeechSynthesizer()

    static func register(messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(
            name: "jarviscopilot/local_tts", binaryMessenger: messenger
        ).setMethodCallHandler { call, result in
            shared.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "speak":
            let text = (args["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { result(false); return }
            let rate = (args["rate"] as? NSNumber)?.floatValue
                ?? AVSpeechUtteranceDefaultSpeechRate
            speak(text: text, rate: rate)
            result(true)
        case "stop":
            synthesizer.stopSpeaking(at: .immediate)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func speak(text: String, rate: Float) {
        // An ack is only ever about the turn happening right now — anything
        // still being said is stale.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        // Clamp into the API's legal range; Dart's default (0.52) sits just
        // above Apple's default, which reads short confirmations naturally.
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        utterance.voice = Self.preferredVoice()
        synthesizer.speak(utterance)
    }

    /// Prefer an enhanced/premium voice for the user's own locale — the
    /// compact default sounds noticeably more robotic than the server voice,
    /// and these ship on-device with no download when present.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
        if #available(iOS 16.0, *) {
            if let premium = candidates.first(where: { $0.quality == .premium }) {
                return premium
            }
        }
        if let enhanced = candidates.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: language) ?? candidates.first
    }
}
