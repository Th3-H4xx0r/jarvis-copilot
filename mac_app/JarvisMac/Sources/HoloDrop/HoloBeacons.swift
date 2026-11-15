import AppKit
import AVFoundation

/// The Mac's direction beacons, played only when a phone's open popup asks (`beacon` frames):
/// an inaudible chirp the phone hears ("hear it") and a faint full-screen flash its camera sees
/// ("look at it"). Codes in `HoloBeaconCode`.
@MainActor
final class HoloBeacons {
    private var engine: AVAudioEngine?
    private var flashWindows: [NSWindow] = []
    private var flashTask: Task<Void, Never>?

    func handle(mode: String, nonce: String) {
        switch mode {
        case "chirp": chirp(nonce)
        case "flash": flash(nonce)
        case "stop": stop()
        default: break
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        flashTask?.cancel()
        flashTask = nil
        for w in flashWindows { w.orderOut(nil) }
        flashWindows = []
    }

    // MARK: chirp

    /// The chirp's samples (mono, `rate` Hz): one tone per bit, soft edges so it doesn't click.
    nonisolated static func chirpSamples(_ nonce: String, rate: Double, amplitude: Float = 0.25) -> [Float] {
        let perSymbol = Int(rate * HoloBeaconCode.chirpSymbol)
        let ramp = max(1, Int(rate * 0.002))
        var out = [Float](repeating: 0, count: perSymbol * HoloBeaconCode.chirpBits(nonce).count)
        var phase = 0.0
        for (i, bit) in HoloBeaconCode.chirpBits(nonce).enumerated() {
            let step = 2 * Double.pi * (bit ? HoloBeaconCode.oneHz : HoloBeaconCode.zeroHz) / rate
            for n in 0..<perSymbol {
                let edge = min(n, perSymbol - 1 - n)
                let gain = edge >= ramp ? 1.0 : 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(ramp))
                out[i * perSymbol + n] = amplitude * Float(gain * sin(phase))
                phase += step
            }
        }
        return out
    }

    private func chirp(_ nonce: String) {
        engine?.stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate >= 40_000, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let samples = Self.chirpSamples(nonce, rate: rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            NSLog("Jarvis: Holo Drop chirp couldn't start audio: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        player.scheduleBuffer(buffer) { [weak self, weak engine] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    engine.stop()
                    self.engine = nil
                }
            }
        }
        player.play()
    }

    // MARK: flash

    private func flash(_ nonce: String) {
        stop()
        let frames = HoloBeaconCode.flashFrames(nonce)
        flashWindows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.white.cgColor
            v.alphaValue = 0
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            return w
        }
        flashTask = Task { @MainActor [weak self] in
            for bit in frames {
                guard let self, !Task.isCancelled else { return }
                for w in self.flashWindows { w.contentView?.alphaValue = bit ? 0.10 : 0 }
                try? await Task.sleep(for: .milliseconds(Int(1000 / HoloBeaconCode.flashHz)))
            }
            self?.stop()
        }
    }
}
