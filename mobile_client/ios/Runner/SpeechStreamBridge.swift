import Foundation
import AVFoundation
import Flutter
#if canImport(Speech)
import Speech
#endif

// Streaming on-device speech recognition (plan 4.1).
//
// The batch `transcribe` in OnDeviceAIPlugin can only start once the user has
// STOPPED talking, so its 300–800 ms lands entirely inside their wait. This
// bridge instead consumes the SAME mic frames Dart is already streaming to the
// server, so the final transcript is ready ~0 ms after the endpointer fires and
// `end_turn` can carry `text` (the server then skips its own STT).
//
// Contract — MethodChannel `jarviscopilot/speech_stream`:
//   start({id, sample_rate, prompt}) -> Bool    false = not available here
//   feed({id, pcm})                  -> nil     PCM16 mono LE
//   stop({id})                       -> String  final transcript ("" if none)
//   cancel({id})                     -> nil
// EventChannel `jarviscopilot/speech_stream/partials` carries
//   {id, type: "partial"|"final"|"error", text}.
//
// WIRING: needs `NSSpeechRecognitionUsageDescription` in Info.plist (already
// required by the batch path).
//
// Privacy: recognition is forced ON-DEVICE (`requiresOnDeviceRecognition`); if
// the device can't do that we return false and Dart falls back to server STT.
// We never log recognized text.
final class SpeechStreamBridge: NSObject {

    static let shared = SpeechStreamBridge()

    private let events = SpeechStreamHandler()
    // Everything touching the recognizer runs here, so `feed` from the Flutter
    // platform thread can never race `stop`.
    private let queue = DispatchQueue(label: "jc.speech.stream")

    #if canImport(Speech)
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var format: AVAudioFormat?
    #endif

    private var sessionId: String?
    private var latest: String = ""
    private var finalCompletion: ((String) -> Void)?

    static func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "jarviscopilot/speech_stream", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            shared.handle(call, result: result)
        }
        FlutterEventChannel(
            name: "jarviscopilot/speech_stream/partials", binaryMessenger: messenger
        ).setStreamHandler(shared.events)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let id = (args["id"] as? String) ?? ""
        switch call.method {
        case "start":
            let rate = (args["sample_rate"] as? Int)
                ?? (args["sample_rate"] as? NSNumber)?.intValue ?? 16_000
            // `prompt` false = only take the session if Speech permission was
            // already granted, so a user who never opted into on-device AI is
            // never surprised by a permission sheet.
            let prompt = (args["prompt"] as? Bool) ?? false
            start(id: id, sampleRate: rate, prompt: prompt, result: result)
        case "feed":
            if let data = args["pcm"] as? FlutterStandardTypedData {
                feed(id: id, pcm: data.data)
            }
            result(nil)
        case "stop":
            stop(id: id, result: result)
        case "cancel":
            cancel(id: id)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: start

    private func start(id: String, sampleRate: Int, prompt: Bool,
                       result: @escaping FlutterResult) {
        #if canImport(Speech)
        guard #available(iOS 13.0, *) else { result(false); return }

        let begin: (Bool) -> Void = { [weak self] authorized in
            guard let self = self, authorized else { Self.main { result(false) }; return }
            self.queue.async {
                self.teardown(deliver: "")
                guard let recognizer = SFSpeechRecognizer(),
                      recognizer.isAvailable,
                      recognizer.supportsOnDeviceRecognition,
                      let format = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: Double(sampleRate),
                        channels: 1,
                        interleaved: false)
                else { Self.main { result(false) }; return }

                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                // Dictation is the closest hint to short spoken commands;
                // harmless on OS versions that ignore it.
                request.taskHint = .dictation

                self.recognizer = recognizer
                self.request = request
                self.format = format
                self.sessionId = id
                self.latest = ""

                self.task = recognizer.recognitionTask(with: request) { [weak self] rec, error in
                    guard let self = self, self.sessionId == id else { return }
                    if let rec = rec {
                        let text = rec.bestTranscription.formattedString
                        self.latest = text
                        self.emit(id: id, type: rec.isFinal ? "final" : "partial", text: text)
                        if rec.isFinal { self.finish(text) }
                    } else if error != nil {
                        // Deliver whatever we heard; "" makes Dart fall back.
                        self.emit(id: id, type: "error", text: "")
                        self.finish(self.latest)
                    }
                }
                Self.main { result(true) }
            }
        }

        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            begin(true)
        } else if status == .notDetermined && prompt {
            SFSpeechRecognizer.requestAuthorization { begin($0 == .authorized) }
        } else {
            result(false)
        }
        #else
        result(false)
        #endif
    }

    // MARK: feed

    private func feed(id: String, pcm: Data) {
        #if canImport(Speech)
        queue.async { [weak self] in
            guard let self = self,
                  self.sessionId == id,
                  let request = self.request,
                  let format = self.format,
                  let buffer = Self.makeBuffer(pcm: pcm, format: format)
            else { return }
            request.append(buffer)
        }
        #endif
    }

    // MARK: stop / cancel

    private func stop(id: String, result: @escaping FlutterResult) {
        #if canImport(Speech)
        queue.async { [weak self] in
            guard let self = self, self.sessionId == id else {
                Self.main { result("") }; return
            }
            let once = OnceString { text in Self.main { result(text) } }
            self.finalCompletion = { text in once.fire(text) }
            // Ask for the final result; the recognition callback above resolves
            // it. Dart also applies its own timeout, so a recognizer that never
            // answers can't hold the turn.
            self.request?.endAudio()
        }
        #else
        result("")
        #endif
    }

    private func cancel(id: String) {
        #if canImport(Speech)
        queue.async { [weak self] in
            guard let self = self, self.sessionId == id else { return }
            self.teardown(deliver: "")
        }
        #endif
    }

    /// Resolve a pending `stop` and release the recognizer. Must run on [queue].
    private func finish(_ text: String) {
        let completion = finalCompletion
        finalCompletion = nil
        teardown(deliver: nil)
        completion?(text)
    }

    /// Release recognizer state. `deliver` non-nil resolves a pending stop.
    private func teardown(deliver: String?) {
        #if canImport(Speech)
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        format = nil
        #endif
        sessionId = nil
        latest = ""
        if let deliver = deliver {
            let completion = finalCompletion
            finalCompletion = nil
            completion?(deliver)
        }
    }

    private func emit(id: String, type: String, text: String) {
        Self.main { [weak self] in
            self?.events.send(["id": id, "type": type, "text": text])
        }
    }

    // MARK: helpers

    #if canImport(Speech)
    /// PCM16 mono LE bytes → the Float32 buffer SFSpeechAudioBufferRecognitionRequest wants.
    private static func makeBuffer(pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        // Copy into an aligned [Int16] first: Data's bytes aren't guaranteed to
        // be 2-byte aligned, so binding them in place would be UB.
        var samples = [Int16](repeating: 0, count: frames)
        _ = samples.withUnsafeMutableBytes { dst in
            pcm.copyBytes(to: dst, count: frames * MemoryLayout<Int16>.size)
        }
        for i in 0..<frames {
            channel[i] = Float(Int16(littleEndian: samples[i])) / 32768.0
        }
        return buffer
    }
    #endif

    private static func main(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// Fires at most once — the recognition callback and a teardown can both
    /// try to resolve the same `stop`.
    private final class OnceString {
        private var closure: ((String) -> Void)?
        private let lock = NSLock()
        init(_ closure: @escaping (String) -> Void) { self.closure = closure }
        func fire(_ value: String) {
            lock.lock()
            let c = closure
            closure = nil
            lock.unlock()
            c?(value)
        }
    }
}

/// Retains the sink between onListen/onCancel so partials can be pushed at any
/// time. All sends are already hopped to the main thread by the bridge.
final class SpeechStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    func send(_ payload: [String: Any]) {
        sink?(payload)
    }
}
