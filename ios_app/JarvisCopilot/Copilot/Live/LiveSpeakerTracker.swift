import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Hears who is speaking, frame by frame, for the whole of one recording.
///
/// A protocol so the store's line-splitting is testable without CoreML.
protocol LiveSpeakerTracking: AnyObject, Sendable {
    /// One captured frame (16 kHz mono int16), at its place on the session clock.
    func feed(_ pcm16: Data, atMs: Int)
    /// Who spoke when over a stretch of the session clock, as far as heard so
    /// far. Nil before any audio, or for a stretch it never heard.
    func activity(fromMs: Int, toMs: Int) async -> LiveSpeakerActivity?
}

#if canImport(FluidAudio)
/// Sortformer, streaming, on its own queue: the model runs on every second
/// of audio, which must never be the main actor's time between frames.
final class SortformerSpeakerTracker: LiveSpeakerTracking, @unchecked Sendable {
    /// The default streaming variant, palettized: 106 MB against 469 MB, and
    /// on his overlap clip it found the second voice at the same frames, 38x
    /// faster than real time on the Mac and loading in 0.1 s once cached.
    static let config: SortformerConfig = {
        var config = SortformerConfig.default
        config.precision = .palettized
        return config
    }()

    private static let rate = 16_000
    /// Run the model once a second of audio has gathered.
    private static let processEverySamples = rate
    /// A gap in the frames longer than this (an interruption) is not replayed
    /// as silence in full; the clock is simply moved on by this much.
    private static let maxGapMs = 30_000

    private let queue = DispatchQueue(label: "jc.live.speakers", qos: .utility)
    private let diarizer: SortformerDiarizer
    private let frameMs: Int
    private let slots: Int
    // Touched only on `queue`.
    private var originMs: Int?
    private var fedSamples = 0
    private var processedSamples = 0

    init(models: SortformerModels) {
        diarizer = SortformerDiarizer(config: Self.config)
        diarizer.initialize(models: models)
        frameMs = max(1, Int((Self.config.frameDurationSeconds * 1000).rounded()))
        slots = Self.config.numSpeakers
    }

    func feed(_ pcm16: Data, atMs: Int) {
        let samples = pcm16.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        queue.async { [self] in
            let origin = originMs ?? atMs
            originMs = origin
            // Keep the model's clock on the session's: frames that never came
            // (an interruption) become silence of the same length, rather than
            // sliding everything after them earlier.
            let reachedMs = origin + fedSamples * 1000 / Self.rate
            let gapMs = atMs - reachedMs
            if gapMs > frameMs {
                let pad = min(gapMs, Self.maxGapMs) * Self.rate / 1000
                diarizer.addAudio([Float](repeating: 0, count: pad))
                fedSamples += pad
            }
            diarizer.addAudio(samples)
            fedSamples += samples.count
            if fedSamples - processedSamples >= Self.processEverySamples { process() }
        }
    }

    func activity(fromMs: Int, toMs: Int) async -> LiveSpeakerActivity? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if fedSamples > processedSamples { process() }
                let timeline = diarizer.timeline
                let count = timeline.numFrames
                guard let origin = originMs, count > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let first = max(0, (fromMs - origin) / frameMs)
                let last = min(count - 1, max(0, (toMs - origin) / frameMs))
                guard first <= last else {
                    continuation.resume(returning: nil)
                    return
                }
                let frames = (first...last).map { frame in
                    (0..<slots).map { timeline.probability(speaker: $0, frame: frame) }
                }
                continuation.resume(returning: LiveSpeakerActivity(
                    startMs: origin + first * frameMs, frameMs: frameMs, frames: frames))
            }
        }
    }

    private func process() {
        do { _ = try diarizer.process() } catch { JcLog.dropped(JcLog.voice, "track speakers", error) }
        processedSamples = fedSamples
    }
}
#endif
