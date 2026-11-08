import AVFoundation

/// One mic tap buffer on its way to the server, for both mic engines (voice and Live). Runs on
/// the render thread, so it allocates only its output and touches no actor state.
enum MicPCM {
    /// Mix `buffer` down to one channel of `format`.
    ///
    /// Which fold is right depends on what produced the buffer, and the two
    /// cases want opposite things:
    ///
    ///  * **Voice processing on.** The unit hands back a nine-channel buffer
    ///    with its processed, echo-cancelled, gain-controlled stream in channel
    ///    0 and silence in the rest. Averaging that divides the only real signal
    ///    by nine — 19 dB thrown away right before the endpointer measures it.
    ///    Take channel 0.
    ///  * **Voice processing off.** The bare MacBook mic is a three-element
    ///    array and every channel is live: the same sound a few centimetres
    ///    apart. Average them (which also buys a little noise rejection).
    ///
    /// Chosen once at engine start, not per buffer: a divisor that changes with
    /// whichever channels happen to be above a threshold this millisecond is an
    /// amplitude modulation on the audio the server has to transcribe.
    nonisolated static func mono(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, processed: Bool) -> AVAudioPCMBuffer? {
        guard let input = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData
        else { return nil }
        let frames = Int(buffer.frameLength)
        out.frameLength = buffer.frameLength

        if processed {
            dst[0].update(from: input[0], count: frames)
            return out
        }
        let channels = Int(buffer.format.channelCount)
        let scale = 1 / Float(channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += input[c][i] }
            dst[0][i] = sum * scale
        }
        return out
    }

    /// Loudest sample across every channel, from every 16th sample: a peak detector does not
    /// need every one.
    nonisolated static func peak(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            let samples = channels[c]
            for i in stride(from: 0, to: Int(buffer.frameLength), by: 16) {
                peak = max(peak, abs(samples[i]))
            }
        }
        return Double(peak)
    }

    /// One tap buffer → mono PCM16 LE at the target rate.
    nonisolated static func pcm16(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                      target: AVAudioFormat, ratio: Double) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0,
              let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    }
}
