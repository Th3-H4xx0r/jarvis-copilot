import AVFoundation

/// Turns a typed prompt into what the glasses' mic would carry: 16 kHz mono PCM16.
@MainActor
protocol MetaPromptSpeaking: AnyObject {
    func pcm16k(for text: String) async throws -> Data
}

/// Voices the sim prompt with the system voice — rendered to a buffer, never played.
/// `AVSpeechSynthesizer.write` hands back buffers (usually 22.05 kHz float); each is converted to
/// 16 kHz mono Int16. The end is the empty buffer `write` delivers last, with the delegate's
/// didFinish and a timeout as backstops.
@MainActor
final class MetaPromptVoice: NSObject, MetaPromptSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var collector: Collector?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func pcm16k(for text: String) async throws -> Data {
        collector?.finish()          // a newer prompt replaces an unfinished one
        let collector = Collector()
        self.collector = collector
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        return await withCheckedContinuation { continuation in
            collector.onDone = { continuation.resume(returning: $0) }
            synthesizer.write(utterance) { buffer in collector.append(buffer) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                collector.finish()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.collector?.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.collector?.finish() }
    }

    /// Gathers converted PCM from the synthesizer's callback queue; resumes the caller once.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var converter: AVAudioConverter?
        private var done = false
        var onDone: ((Data) -> Void)?
        private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                           channels: 1, interleaved: true)!

        func append(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { finish(); return }
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            if converter == nil || converter?.inputFormat != pcm.format {
                converter = AVAudioConverter(from: pcm.format, to: target)
            }
            guard let converter else { return }
            let ratio = target.sampleRate / pcm.format.sampleRate
            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return pcm
            }
            if error == nil, let channel = out.int16ChannelData, out.frameLength > 0 {
                data.append(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
            }
        }

        func finish() {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let result = data
            let callback = onDone
            onDone = nil
            lock.unlock()
            callback?(result)
        }
    }
}
