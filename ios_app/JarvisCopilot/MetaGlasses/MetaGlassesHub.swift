import Foundation
import Photos
import UIKit

/// Which Ray-Ban Meta glasses Jarvis talks to — the real ones (Device) or the simulator (Sim) —
/// and the one `MetaGlassesDevice` registered for them. The Device | Sim toggle on the glasses page
/// sets it. Same tools, same session code either way; only the transport differs.
@MainActor
final class MetaGlassesHub: ObservableObject {
    static let shared = MetaGlassesHub()

    enum Mode: String, CaseIterable {
        case device, sim
        var label: String { self == .device ? "Device" : "Sim" }
    }

    @Published private(set) var mode: Mode
    /// The registered glasses (nil in Device mode until real glasses are paired).
    @Published private(set) var device: MetaGlassesDevice?
    let feed = MetaCommandFeed.shared
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []

    /// The simulated glasses: iPhone camera (test scenes as fallback), phone speaker, real media keys.
    private(set) lazy var simulator: SimulatedGlassesTransport = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetaGlassesSim", isDirectory: true)
        let sim = SimulatedGlassesTransport(camera: MetaSimCamera(), feed: feed, mediaDirectory: folder)
        sim.speaker = MetaPhoneSpeaker()
        sim.wakeDefaults = .standard
        sim.saveToPhotos = { item in try await Self.addToPhotos(item) }
        sim.questionCapture = MetaPhoneQuestionCapture()
        sim.assistantSession = { hold in
            if hold { try AudioSessionArbiter.shared.hold(.glassesSim) } else { try AudioSessionArbiter.shared.release(.glassesSim) }
        }
        sim.earcon = ToneEarconPlayer()
        // An incoming call: his listening chime, soft, while it rings; what you say while it rings
        // becomes words on the phone (on-device), matched to answer / decline.
        let ringChime = ToneEarconPlayer()
        ringChime.volume = 0.35
        sim.ringChime = ringChime
        sim.callTranscriber = { pcm in await MetaCallSpeech.transcribe(pcm) }
        // No mediaKeys: the sim's touchpad drives the SIMULATED music only. Real media keys run
        // through iOS Shortcuts on iOS 27 and yanked him into the Shortcuts app (2026-11-22).
        return sim
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = Mode(rawValue: defaults.string(forKey: "meta.mode") ?? "") ?? .sim
    }

    /// At launch: bring up whichever glasses the toggle points at.
    func activate() async {
        observeAppState()
        switch mode {
        case .sim: await startSim()
        case .device: break   // the real glasses register here once the hardware layer exists
        }
    }

    func setMode(_ newMode: Mode) async {
        guard newMode != mode else { return }
        await deactivate()
        mode = newMode
        defaults.set(newMode.rawValue, forKey: "meta.mode")
        feed.log(.sim, newMode == .sim ? "Switched to Sim — Jarvis talks to the simulated glasses"
                                        : "Switched to Device — the simulator is off", outcome: .info)
        await activate()
    }

    private func startSim() async {
        guard device == nil else { return }
        simulator.renewInbound()
        let glasses = MetaGlassesDevice(transport: simulator, feed: feed)
        glasses.session.onTouchBinding = { [weak self] gesture in self?.runBinding(for: gesture) }
        // The glasses' live frames feed the Mac's Jarvis Glasses camera when he's turned it on.
        glasses.session.onLiveFrame = { GlassesMacCamera.shared.liveFrame($0) }
        device = glasses
        // The same name the real glasses will register under: Jarvis can't tell them apart.
        DeviceRegistry.shared.syncMembership(of: glasses, identity: MetaGlassesDevice.identityKey,
                                             model: MetaGlassesDevice.model)
        do { try await glasses.session.start() }
        catch { feed.log(.glasses, "Couldn't start the simulated glasses", detail: error.localizedDescription, outcome: .info) }
        armKeepaliveForTheAssistant()
        // A background launch gets no didEnterBackground: start paused, catch up on foreground.
        if UIApplication.shared.applicationState == .background { simulator.pauseTicking() }
    }

    /// Add-only, like HoloDrop's saver: Jarvis never reads the library.
    static func addToPhotos(_ item: MetaStoredMedia) async throws {
        guard let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw MetaGlassesError.refused(item.kind == .video ? "a test-scene clip has no video file to save" : "the photo file is missing")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw MetaGlassesError.refused("allow Jarvis to add to Photos in Settings → Privacy → Photos")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: item.kind == .video ? .video : .photo, fileURL: url, options: nil)
        }
    }

    private func deactivate() async {
        guard let glasses = device else { return }
        await glasses.session.stop()
        DeviceRegistry.shared.remove(deviceID: glasses.deviceID)
        BridgeClient.forget(deviceID: glasses.deviceID)   // the simulator is off, not merely offline
        BridgeClient.shared.sendRegistration()
        device = nil
    }

    /// No 1 s tick while the app is in the background — the always-alive app's battery matters.
    private func observeAppState() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.simulatorIfStarted?.pauseTicking() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let sim = self?.simulatorIfStarted else { return }
                self?.armKeepaliveForTheAssistant()
                Task { await sim.resumeTicking() }
            }
        })
    }

    private var simulatorIfStarted: SimulatedGlassesTransport? { device?.transport as? SimulatedGlassesTransport }

    /// While the app is in front, put the keepalive on its recordable plan (keepaliveRecordReady is
    /// true while the sim is on): from the background iOS refuses that switch ('!pri'/'!int'), and
    /// the ring's assistant needs it already in place. Re-claiming the keepalive re-applies its plan.
    private func armKeepaliveForTheAssistant() {
        guard UIApplication.shared.applicationState != .background,
              AudioSessionArbiter.shared.holds(.keepalive) else { return }
        try? AudioSessionArbiter.shared.hold(.keepalive)
    }

    // MARK: Touch bindings (a Jarvis action on top of the glasses' own default)

    func binding(for gesture: MetaTouchGesture) -> RingAction {
        guard let data = defaults.data(forKey: "meta.touch.\(gesture.rawValue)"),
              let action = try? JSONDecoder().decode(RingAction.self, from: data) else { return .none }
        return action
    }

    func setBinding(_ action: RingAction, for gesture: MetaTouchGesture) {
        if let data = try? JSONEncoder().encode(action) { defaults.set(data, forKey: "meta.touch.\(gesture.rawValue)") }
        objectWillChange.send()
    }

    private func runBinding(for gesture: MetaTouchGesture) {
        let action = binding(for: gesture)
        guard action.isSet else { return }
        Task {
            let line = await RingActionRunner.run(action)
            feed.log(.touch, "\(MetaTouchBinding.label(gesture)) → \(action.summary)", detail: line)
        }
    }
}
