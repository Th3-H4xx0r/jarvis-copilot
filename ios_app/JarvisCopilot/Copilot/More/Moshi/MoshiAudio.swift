import AVFoundation
import Foundation

/// Microphone → fixed 80 ms frames at 24 kHz mono, handed to a worker via a
/// blocking queue; and a ring-buffer speaker for Moshi's reply. Adapted from
/// Kyutai's demo (`Moshi/AudioRT.swift`) with locks instead of `Atomic`, so it
/// builds on iOS 17.
final class MoshiFrameQueue {
    private var frames: [[Float]] = []
    private let lock = NSCondition()
    private var closed = false

    func push(_ frame: [Float]) {
        lock.lock(); frames.append(frame); lock.signal(); lock.unlock()
    }

    /// Blocks until a frame is available; nil once closed.
    func pop() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        while frames.isEmpty && !closed { lock.wait() }
        return frames.isEmpty ? nil : frames.removeFirst()
    }

    var depth: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    func close() { lock.lock(); closed = true; lock.broadcast(); unlockAndClear() }
    private func unlockAndClear() { frames.removeAll(); lock.unlock() }
}

final class MoshiMicrophone {
    private let engine = AVAudioEngine()
    private var pending: [Float] = []
    let frames = MoshiFrameQueue()
    private let frameSize: Int
    private let sampleRate: Double
    /// Peak level of the last buffer, 0…1, for the UI meter.
    private(set) var level: Float = 0

    init(sampleRate: Double, frameSize: Int) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
    }

    func start(echoCancellation: Bool) throws {
        let input = engine.inputNode
        if echoCancellation {
            // Lets Moshi talk over the speaker without hearing itself.
            try? input.setVoiceProcessingEnabled(true)
        }
        let inputFormat = input.inputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw MoshiAudioError.format
        }
        input.installTap(onBus: 0, bufferSize: 1920, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var error: NSError?
            var consumed = false
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            self.level = samples.reduce(0) { max($0, abs($1)) }
            self.pending += samples
            while self.pending.count >= self.frameSize {
                self.frames.push(Array(self.pending[0..<self.frameSize]))
                self.pending.removeFirst(self.frameSize)
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        frames.close()
    }
}

enum MoshiAudioError: LocalizedError {
    case format
    var errorDescription: String? { "Couldn't configure the microphone format." }
}

final class MoshiSpeaker {
    private let engine = AVAudioEngine()
    private var ring: [Float]
    private var readIndex = 0, writeIndex = 0, count = 0
    private let lock = NSLock()
    private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        ring = [Float](repeating: 0, count: Int(sampleRate * 4))
    }

    var bufferedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(count) / sampleRate }

    func start() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, list -> OSStatus in
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
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    func stop() { engine.stop() }

    /// Drops audio that won't fit rather than blocking the model thread.
    func send(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for s in samples where count < ring.count {
            ring[writeIndex] = s
            writeIndex = (writeIndex + 1) % ring.count
            count += 1
        }
    }
}
