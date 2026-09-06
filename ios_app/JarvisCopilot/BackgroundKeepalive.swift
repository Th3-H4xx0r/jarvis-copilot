import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#endif

/// Keeps the process alive while backgrounded by holding an active audio session.
///
/// iOS has no background mode for "keep my socket open". The only modes that stop the
/// app from being *suspended* (as opposed to briefly woken) are `audio`, `location` and
/// VoIP, and `audio` is the cheapest and the only one with no user-visible indicator.
/// This is what keeps Spotify Connect responsive while a track is playing; here we play
/// silence. App Review rejects this pattern, which is fine for a sideloaded app.
///
/// While the keepalive runs, the bridge WebSocket and the BLE link both stay up in the
/// background, so a Jarvis invoke takes the same live path it takes in the foreground —
/// no silent-push hop, no timing race. The push path stays as the fallback for the
/// cases this cannot cover: a force-quit, or an audio interruption that never ends.
///
/// Invisible by construction: `.mixWithOthers` means we are never the primary media
/// app, and we publish nothing to `MPNowPlayingInfoCenter`, so no Now Playing card.
///
/// The session itself is NOT written here: `AVAudioSession` is process-wide and the
/// voice stack needs `.playAndRecord` from the same session, so both go through
/// `AudioSessionArbiter` (see that file for the two bugs the split ownership caused).
/// What is left here is the silent engine and the rule for when to hold a claim.
@MainActor
final class BackgroundKeepalive {
    static let shared = BackgroundKeepalive()

    private(set) var isRunning = false

    private let arbiter: AudioSessionArbiter
    private let engine: KeepaliveAudioEngine
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    /// Dependencies are optionals rather than defaulted values: a default argument
    /// cannot call a `@MainActor` initialiser or touch a `@MainActor` singleton.
    init(arbiter: AudioSessionArbiter? = nil,
         engine: KeepaliveAudioEngine? = nil,
         center: NotificationCenter = .default) {
        self.arbiter = arbiter ?? .shared
        self.engine = engine ?? SilentAudioEngine()
        self.center = center
    }

    /// The arming rule, as a pure function — `BridgeClient.syncKeepalive()` is the only
    /// caller of `sync(active:)` and passes exactly this expression.
    ///
    /// Port of `computeKeepaliveArmed` in `services/background_keepalive.dart`, minus
    /// its `background` and `voiceActive` terms:
    ///
    ///  * **background** — Flutter armed the session only once the app had backgrounded.
    ///    iOS cannot: an app that is already suspended can no longer start an audio
    ///    session, so the session has to be held from the moment bridge mode is on, or
    ///    the very first background is the one that kills the socket.
    ///  * **voiceActive** — the keepalive no longer competes for the session: while a
    ///    turn is live the arbiter keeps the union (`.playAndRecord`), which earns
    ///    background execution just as well, so there is nothing to stand down for.
    ///    (Before the arbiter this was merely *claimed*, via `.mixWithOthers` — and it
    ///    was false: `.playback` cannot record, and it won every race it entered.)
    nonisolated static func shouldRun(bridgeEnabled: Bool, isPaired: Bool) -> Bool {
        bridgeEnabled && isPaired
    }

    /// Brings the keepalive in line with whether it should be running. Idempotent, so
    /// callers can invoke it on every state change without tracking transitions.
    func sync(active: Bool) {
        if active { start() } else { stop() }
    }

    // MARK: - Lifecycle

    private func start() {
        guard !isRunning else { return }
        do {
            try arbiter.hold(.keepalive)
        } catch {
            return
        }
        guard engine.start() else {
            // Holding a session we are not playing silence into buys no background
            // time at all, so give the claim straight back.
            try? arbiter.release(.keepalive)
            return
        }
        installObservers()
        isRunning = true
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        removeObservers()
        engine.stop()
        // Only a release, never a deactivation: a voice turn may be holding the same
        // session, and pulling it out from under a live mic is the regression this
        // whole arbitration exists to prevent.
        try? arbiter.release(.keepalive)
    }

    /// Re-assert the claim and the silent engine after iOS took either away.
    ///
    /// The claim goes back through the arbiter, so if a voice turn is live this keeps
    /// the session on `.playAndRecord` instead of yanking it back to `.playback`.
    private func resume() {
        guard isRunning else { return }
        try? arbiter.hold(.keepalive, reassert: true)
        guard !engine.isRunning else { return }
        _ = engine.start()
    }

    // MARK: - Observers

    /// Phone calls, Siri and alarms interrupt the session and stop the engine. Once the
    /// interruption ends we start again, otherwise the app would quietly lose its
    /// background allowance and every invoke would fall back to push.
    ///
    /// All three are registered with `object: nil`: the session notifications only ever
    /// come from the shared instance anyway, and it lets a test drive them through its
    /// own `NotificationCenter`.
    private func installObservers() {
        removeObservers()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            Self.onMain { self?.resume() }
        })

        // Media services can be restarted underneath us (audio daemon crash); every
        // audio object is then invalid and must be rebuilt.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Self.onMain { self?.resume() }
        })

        // `AVAudioEngine` stops ITSELF whenever the session's category or route changes
        // underneath it — which now happens twice per voice turn, as the arbiter moves
        // the session to `.playAndRecord` and back. Without this the silent engine died
        // on the first turn of the launch and the background allowance went with it.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            Self.onMain { self?.resume() }
        })

        #if os(iOS)
        // Belt and braces: re-assert on return to foreground in case an interruption
        // ended without an `.ended` notification (documented as possible).
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Self.onMain { self?.resume() }
        })
        #endif
    }

    private func removeObservers() {
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    /// Observers are registered with `queue: nil` so the block runs synchronously on
    /// the POSTING thread — which is how the restart lands in the same runloop turn as
    /// the category switch that caused it. `AVAudioSession` posts from its own thread,
    /// though, so hop when we are not already on the main actor.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }
}

// MARK: - The silent engine

/// The thing that actually plays silence, behind a protocol so the keepalive's
/// lifecycle is testable without CoreAudio.
@MainActor
protocol KeepaliveAudioEngine: AnyObject {
    /// False once iOS stopped it under us (category switch, media services reset).
    var isRunning: Bool { get }
    /// Start (or restart) looping silence. False when the engine refused.
    @discardableResult
    func start() -> Bool
    func stop()
}

/// An `AVAudioPlayerNode` looping a buffer of silence. The buffer is generated in
/// memory rather than bundled, so there is no asset to add to the project.
@MainActor
final class SilentAudioEngine: KeepaliveAudioEngine {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    var isRunning: Bool { engine?.isRunning == true }

    @discardableResult
    func start() -> Bool {
        // Rebuilt from scratch every time: after a media-services reset (and after some
        // configuration changes) the old nodes are invalid and restarting them fails.
        stop()
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

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}
