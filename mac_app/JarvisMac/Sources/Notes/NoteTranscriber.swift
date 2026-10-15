import AVFoundation
import Speech

/// Writes one stretch of a call (≤ ~18 s of 16 kHz mono) as timed words with the
/// on-device recognizer. Each stretch is its own short request, so a long call
/// never runs into the recognizer's limits, and the audio is dropped as soon as
/// its words are back.
enum ChunkTranscriber {
    static let timeout: Duration = .seconds(30)

    static func transcribe(_ samples: [Float], with recognizer: SFSpeechRecognizer) async -> [TimedWord] {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Resampler16k.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()
        let duration = Double(samples.count) / ChannelBuffer.sampleRate
        return await withCheckedContinuation { (c: CheckedContinuation<[TimedWord], Never>) in
            let once = ResumeOnceWords(c)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.resume(words(from: result.bestTranscription, duration: duration))
                } else if error != nil {
                    once.resume([])
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                task.cancel()
                once.resume([])
            }
        }
    }

    /// The recognizer's segments as timed words; when it gives no times, the words
    /// are spread over the stretch so lines still split on the right side.
    static func words(from transcription: SFTranscription, duration: Double) -> [TimedWord] {
        let segments = transcription.segments
        guard !segments.isEmpty else {
            let parts = transcription.formattedString.split(whereSeparator: \.isWhitespace).map(String.init)
            return spread(parts, over: duration)
        }
        if segments.allSatisfy({ $0.duration == 0 && $0.timestamp == 0 }) {
            return spread(segments.map(\.substring), over: duration)
        }
        return segments.map { TimedWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
    }

    static func spread(_ parts: [String], over duration: Double) -> [TimedWord] {
        guard !parts.isEmpty else { return [] }
        let step = duration / Double(parts.count)
        return parts.enumerated().map { i, text in
            TimedWord(text: text, start: Double(i) * step, end: Double(i + 1) * step)
        }
    }
}

final class ResumeOnceWords: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TimedWord], Never>?

    init(_ c: CheckedContinuation<[TimedWord], Never>) { continuation = c }

    func resume(_ words: [TimedWord]) {
        let c: CheckedContinuation<[TimedWord], Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: words)
    }
}
