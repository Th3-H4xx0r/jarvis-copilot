import AVFAudio
import CoreMotion
import Foundation

/// The phone-side music modes Magic Lantern has: the phone's microphone drives the lights (its
/// exact rule: a running baseline of loudness, and every sample 5 dB above it sends the next colour
/// of a fixed rotation, silence sends black), and "shake" picks a random colour.
@MainActor
final class CarLightsMusic: ObservableObject {
    static let shared = CarLightsMusic()
    private static let shakeKey = "jc.lights.shake"

    @Published private(set) var listening = false
    @Published private(set) var error: String?
    @Published var shakeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(shakeEnabled, forKey: Self.shakeKey)
            shakeEnabled ? startShake() : stopShake()
        }
    }

    private var engine: AVAudioEngine?
    private var targets: [String]?
    private var configObserver: NSObjectProtocol?
    private var meter = LoudnessRotation()
    private let motion = CMMotionManager()
    private var lastShake = Date.distantPast

    private init() {
        shakeEnabled = UserDefaults.standard.bool(forKey: Self.shakeKey)
        if shakeEnabled { startShake() }
    }

    // MARK: Phone microphone

    func startPhoneMic(for ids: [String]? = nil) {
        guard !listening else { return }
        error = nil
        // A Pod or glasses voice turn holds a session with no microphone: a tap on a 0 Hz input
        // raises an Objective-C exception Swift can't catch.
        guard !AudioSessionArbiter.shared.holds(.externalVoice) else {
            error = "The microphone is busy with a voice conversation."
            return
        }
        // As the app does on "Phone MIC": the lights' own microphone off first, or both fight.
        let manager = CarLightsManager.shared
        let micUnits = (ids ?? manager.controllers.map(\.id)).filter { id in
            manager.controllers.first { $0.id == id }?.capabilities.hasDeviceMic ?? false
        }
        if !micUnits.isEmpty { manager.apply(.deviceMic(on: false), to: micUnits) }
        let engine = AVAudioEngine()   // fresh each time: an old one keeps a stale input format
        do {
            try AudioSessionArbiter.shared.hold(.recording)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "CarLightsMusic", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
            }
            meter = LoudnessRotation()
            targets = ids
            // ~100 ms of audio per buffer: the app samples about ten times a second.
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                let n = Int(buffer.frameLength)
                guard n > 0 else { return }
                var sum: Double = 0
                for i in 0..<n {
                    let s = Double(samples[i]) * 32768   // the app's PCM16 scale
                    sum += s * s
                }
                let db = 10 * log10(max(sum / Double(n), 1))
                Task { @MainActor [weak self] in self?.heard(db) }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            listening = true
            CarLightsManager.shared.setMode(.phoneMusic, for: ids)
            // A voice turn or a recording ending changes the session under the engine, which stops
            // it: say so instead of a switch that looks on while nothing listens.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.listening else { return }
                    self.stopPhoneMic()
                    self.error = "The phone microphone was needed elsewhere — turn it on again."
                }
            }
        } catch {
            self.error = "Couldn't use the microphone: \(error.localizedDescription)"
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AudioSessionArbiter.shared.release(.recording)
        }
    }

    /// Stops listening and puts the lights back on their colour (the last music frame may be black).
    func stopPhoneMic() {
        guard listening else { return }
        listening = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AudioSessionArbiter.shared.release(.recording)
        CarLightsManager.shared.endPhoneMusic(for: targets)
    }

    private func heard(_ db: Double) {
        guard listening, let color = meter.next(db: db) else { return }
        CarLightsManager.shared.sendMusicColor(color, to: targets)
    }

    // MARK: Shake

    private func startShake() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.userAcceleration else { return }
            let g = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            guard g > 1.8, Date().timeIntervalSince(self.lastShake) > 0.6 else { return }
            self.lastShake = Date()
            let color = MelkColor(r: .random(in: 0...255), g: .random(in: 0...255), b: .random(in: 0...255))
            CarLightsManager.shared.apply(.color(color))
        }
    }

    private func stopShake() { motion.stopDeviceMotionUpdates() }
}

/// Magic Lantern's phone-mic rule exactly (`StreamingFragment` / `Utils`): readings are whole dB;
/// each of the first ones counts ten times until the baseline holds 200; then a reading at least
/// 5 dB over the (whole-number) average sends the NEXT colour of the rotation — the index is bumped
/// first and survives between sessions — and a quieter one sends black and joins the baseline five
/// times. The baseline is never trimmed. Only the sum and count matter for an average.
struct LoudnessRotation {
    private(set) var sum = 0
    private(set) var count = 0
    private static var index = 0

    /// The colour to send for one reading, or nil while still warming up.
    mutating func next(db: Double) -> MelkColor? {
        let reading = Int(db)
        guard count >= 200 else {
            sum += 10 * reading
            count += 10
            return nil
        }
        guard Double(reading) >= Double(sum / count + 5) else {
            sum += 5 * reading
            count += 5
            return MelkColor.black
        }
        Self.index = (Self.index + 1) % MelkColor.musicRotation.count
        return MelkColor.musicRotation[Self.index]
    }

    static func resetRotationForTests() { index = 0 }
}
