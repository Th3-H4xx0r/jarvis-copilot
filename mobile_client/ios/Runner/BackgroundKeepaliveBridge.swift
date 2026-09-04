import Foundation
import AVFoundation
import UIKit

/// Keeps the process alive while backgrounded by holding an active audio
/// session, so the device-bridge WebSocket (ws_bridge.dart) survives
/// backgrounding instead of falling back to the slow/unreliable silent-push
/// path (Workstream H — user-reported bug 2026-09-04: phone shows online but
/// a live invoke, e.g. "what's my battery?", times out because the WS died
/// the moment iOS suspended the app).
///
/// Ported closely from JarvisWearables/JarvisWearables/BackgroundKeepalive.swift
/// (see that file's comments for the full rationale). iOS has no background
/// mode for "keep my socket open"; `audio` is the cheapest of the modes that
/// stop outright suspension, and the only one with no user-visible indicator
/// when played silent + `.mixWithOthers`. This is the same trick that keeps
/// Spotify Connect responsive while a track plays. App Review rejects this
/// pattern for App-Store apps; fine here since JarvisCopilot is sideloaded.
///
/// Arm/disarm decisions themselves live in Dart (pure, unit-tested —
/// `lib/services/background_keepalive.dart`); this class is a dumb executor
/// driven by the `jarviscopilot/keepalive` MethodChannel's `setActive` calls,
/// plus one native-only fallback: a brief unconditional arm on a
/// background-launch-by-push, before Dart has had a chance to run its own
/// decision and correct it.
@MainActor
final class BackgroundKeepalive {
    static let shared = BackgroundKeepalive()

    private(set) var isRunning = false

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Brings the keepalive in line with whether it should be running. Idempotent, so
    /// callers can invoke it on every state change without tracking transitions.
    func sync(active: Bool) {
        if active { start() } else { stop() }
    }

    private func start() {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.playback` is what earns background execution. `.mixWithOthers` keeps
            // us from ducking or pausing whatever the user is actually listening to,
            // and from taking over the lock-screen media controls.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }

        guard startEngine() else { return }
        installObservers()
        isRunning = true
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        removeObservers()
        tearDownEngine()
        // `.notifyOthersOnDeactivation` is deliberately omitted: we never interrupted
        // anyone, so there is nothing for other apps to resume.
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// A player node looping a buffer of silence. Generated in memory rather than
    /// bundled, so there is no asset to add to the project.
    private func startEngine() -> Bool {
        tearDownEngine()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        // One second of zeros; `AVAudioPCMBuffer` is zero-initialised.
        let frames = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return false
        }
        buffer.frameLength = frames

        do {
            try engine.start()
        } catch {
            return false
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()

        self.engine = engine
        self.player = player
        return true
    }

    private func tearDownEngine() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    /// Phone calls, Siri and alarms interrupt the session and stop the engine. Once the
    /// interruption ends we start again, otherwise the app would quietly lose its
    /// background allowance and every invoke would fall back to push.
    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let self, self.isRunning,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            Task { @MainActor in self.resume() }
        })

        // Media services can be restarted underneath us (audio daemon crash); every
        // audio object is then invalid and must be rebuilt.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        })

        // Belt and braces: re-assert on return to foreground in case an interruption
        // ended without an `.ended` notification (documented as possible).
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, self.engine?.isRunning != true else { return }
                self.resume()
            }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func resume() {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        _ = startEngine()
    }
}

/// Flutter-facing bridge: registers `jarviscopilot/keepalive` and forwards
/// `setActive` calls to [BackgroundKeepalive]. Kept separate from
/// `BackgroundKeepalive` itself (which has no Flutter dependency) so the
/// keepalive logic stays testable/portable, mirroring the JarvisWearables
/// split.
enum BackgroundKeepaliveBridge {
    static func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "jarviscopilot/keepalive",
            binaryMessenger: messenger
        )
        // FlutterMethodChannel invokes handlers on the main thread; the
        // engine that calls in is `nonisolated` to the compiler, so we hop
        // through `MainActor.assumeIsolated` rather than an `await` (which
        // would race Dart's expectation of a synchronous-looking reply).
        channel.setMethodCallHandler { call, result in
            MainActor.assumeIsolated {
                switch call.method {
                case "setActive":
                    let args = call.arguments as? [String: Any]
                    let active = (args?["active"] as? Bool) ?? false
                    BackgroundKeepalive.shared.sync(active: active)
                    result(true)
                case "isRunning":
                    result(BackgroundKeepalive.shared.isRunning)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
        }
    }

    /// Called from `didFinishLaunchingWithOptions` when iOS launched us in
    /// the background for a remote (silent) push — the same wake that
    /// carries a Jarvis invoke. Arms the keepalive immediately, natively,
    /// before Dart has spun up and made its own (better-informed) decision;
    /// Dart's `BackgroundKeepalive.syncFromAppState()` runs moments later on
    /// launch and will disarm it again if the user has the setting off or
    /// isn't paired. Cheap and self-correcting either way.
    @MainActor
    static func armForBackgroundPushLaunch() {
        BackgroundKeepalive.shared.sync(active: true)
    }
}
