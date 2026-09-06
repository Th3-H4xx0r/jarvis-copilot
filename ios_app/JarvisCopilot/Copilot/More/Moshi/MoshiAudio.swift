import AVFoundation
import Foundation

/// Blocking queue of fixed-size mic frames feeding the model thread.
final class MoshiFrameQueue {
    private var frames: [[Float]] = []
    private let lock = NSCondition()
    private var closed = false

    /// Frames dropped because the model fell behind.
    private(set) var dropped = 0
    /// Keep at most this much backlog (in frames) so a slow model answers what
    /// was said just now, not several seconds ago.
    var maxDepth = 10

    func push(_ frame: [Float]) {
        lock.lock()
        frames.append(frame)
        if frames.count > maxDepth {
            let excess = frames.count - maxDepth / 2
            frames.removeFirst(excess)
            dropped += excess
        }
        lock.signal(); lock.unlock()
    }

    /// Blocks until a frame is available; nil once closed.
    func pop() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        while frames.isEmpty && !closed { lock.wait() }
        return frames.isEmpty ? nil : frames.removeFirst()
    }

    var depth: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    func close() { lock.lock(); closed = true; frames.removeAll(); lock.broadcast(); lock.unlock() }
}

enum MoshiAudioError: LocalizedError {
    case format
    var errorDescription: String? { "Couldn't configure the microphone format." }
}

/// Mic in and speaker out on ONE `AVAudioEngine`. iOS echo cancellation
/// (voice processing) is a property of the engine's paired input/output nodes,
/// and enabling it reconfigures the session — a second engine for playback gets
/// stopped underneath us, which is why a split design plays nothing.
///
/// Input: tap → resample to 24 kHz mono → 1920-sample (80 ms) frames on `frames`.
/// Output: a source node draining a ring buffer of Moshi's reply samples.
final class MoshiAudioIO {
    let frames = MoshiFrameQueue()
    /// Peak of the last mic buffer, 0…1.
    private(set) var level: Float = 0
    /// Total reply audio handed to the speaker, in seconds.
    private(set) var playedSeconds: Double = 0
    /// Mic frames delivered to the model queue.
    private(set) var capturedFrames = 0
    /// Whether echo cancellation actually came on.
    private(set) var voiceProcessing = false

    private let engine = AVAudioEngine()
    private let sampleRate: Double
    private let frameSize: Int
    private var pending: [Float] = []
    private var ring: [Float]
    private var readIndex = 0, writeIndex = 0, count = 0
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    init(sampleRate: Double, frameSize: Int) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        ring = [Float](repeating: 0, count: Int(sampleRate * 6))
    }

    var bufferedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(count) / sampleRate }

    /// Session setup per Apple's voice-processing engine sample: play-and-record
    /// in voice-chat mode, speaker by default, and the whole route pinned to
    /// 48 kHz so the voice-IO input and output formats can be identical.
    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
    }

    func start(echoCancellation: Bool) throws {
        let input = engine.inputNode
        // Per AVAudioIONode.h: voice processing can only be toggled while the
        // engine is stopped, and enabling it on the input node enables it on
        // the output node too (both must share a format). Do it before any
        // connection or tap so the graph is built against the final formats.
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessing = true
            } catch {
                NSLog("[moshi] voice processing unavailable: \(error)")
            }
        }
        // Per AVAudioNode.h, a tap observes a node's OUTPUT bus, and its format
        // must be that bus's format. `inputFormat(forBus:)` is the hardware
        // side, which differs once voice processing is on — a tap installed
        // with it never fires.
        let tapFormat = input.outputFormat(forBus: 0)
        NSLog("[moshi] mic tap format: \(tapFormat), hardware: \(input.inputFormat(forBus: 0))")
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: tapFormat, to: target) else {
            throw MoshiAudioError.format
        }

        // Speaker: source node → mixer at 24 kHz mono. The mixer → output link is
        // made in the voice-IO format (the input node's output format): per
        // AVAudioIONode.h the output node's input format must equal it, and
        // leaving it to the route (2 ch 44.1 kHz) breaks the voice-IO unit —
        // the engine reports running but the tap never fires.
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let voiceIOFormat = voiceProcessing ? tapFormat : engine.outputNode.inputFormat(forBus: 0)
        let source = AVAudioSourceNode(format: outFormat) { [weak self] _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let self, let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.lock.lock()
            for i in 0..<Int(frameCount) {
                if self.count > 0 {
                    out[i] = self.ring[self.readIndex]
                    self.readIndex = (self.readIndex + 1) % self.ring.count
                    self.count -= 1
                } else {
                    out[i] = 0
                }
            }
            self.lock.unlock()
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: outFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: voiceIOFormat)

        input.installTap(onBus: 0, bufferSize: 2400, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / tapFormat.sampleRate + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var error: NSError?
            var consumed = false
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if let error { NSLog("[moshi] mic convert error: \(error)"); return }
            guard out.frameLength > 0, let data = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            self.level = samples.reduce(0) { max($0, abs($1)) }
            self.pending += samples
            while self.pending.count >= self.frameSize {
                self.frames.push(Array(self.pending[0..<self.frameSize]))
                self.pending.removeFirst(self.frameSize)
                self.capturedFrames += 1
            }
        }

        // A route change (headphones, speaker toggle) stops the engine; restart it.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            try? self.engine.start()
        }

        engine.prepare()
        try engine.start()
        NSLog("[moshi] engine running=\(engine.isRunning) vp=\(voiceProcessing) out=\(engine.outputNode.inputFormat(forBus: 0))")
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        frames.close()
    }

    /// Queue reply audio; drops what won't fit rather than blocking the model thread.
    func play(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for s in samples where count < ring.count {
            ring[writeIndex] = s
            writeIndex = (writeIndex + 1) % ring.count
            count += 1
        }
        playedSeconds += Double(samples.count) / sampleRate
    }
}
