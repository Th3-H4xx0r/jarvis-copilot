import AVFoundation
import Foundation
import Observation
import UIKit

/// The INMO GO3 smart glasses, as far as the phone can reach them today: an ordinary
/// Bluetooth headset (A2DP for the speakers, HFP for the four mics). The lens, the
/// touchpad, the GO key and the camera sit behind INMO's own control link, which Jarvis
/// does not drive — so there is no `WearableDevice` and no skills yet, only the audio
/// route and a card.
enum InmoGo3 {
    static let model = "INMO GO3"
    /// What the card, the page and the agent's list call them until renamed — the ring's
    /// "Smart ring". The Bluetooth name is on the page's Device section.
    static let defaultName = "Smart glasses"

    @MainActor static var name: String {
        WearableNames.shared.name(WearableKeepAlive.glasses, fallback: defaultName)
    }
}

/// One `AVAudioSession` port, reduced to what the matcher needs — so the rules are
/// testable without a headset.
struct GlassesAudioPort: Equatable {
    let name: String
    let uid: String
    let isBluetooth: Bool

    /// iOS gives A2DP and HFP separate ports ("…-tacl", "…-tsco") for one device; both
    /// start with its MAC, which is what identifies the glasses across profiles.
    var deviceKey: String {
        let prefix = String(uid.prefix(17))
        let isMAC = prefix.range(of: #"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
        return isMAC ? prefix.uppercased() : uid
    }

    /// The name the GO3 advertises is unconfirmed until one is paired, so only the word
    /// "INMO" counts ("INMO GO3", "INMO_GO3", "INMOGO3"). "GO 3" alone is a JBL speaker's
    /// real name, and "inmo" hides inside other words ("Spinmotion").
    static func looksLikeGo3(_ name: String) -> Bool {
        name.lowercased().range(of: #"(^|[^a-z0-9])inmo(go|[^a-z]|$)"#, options: .regularExpression) != nil
    }
}

/// What the route says about the glasses right now.
struct GlassesRouteState: Equatable {
    /// The glasses' port, preferring the one carrying audio.
    var glasses: GlassesAudioPort?
    /// Replies are playing through the glasses.
    var speakers = false
    /// Jarvis is listening through the glasses' mics.
    var microphone = false
    /// A Bluetooth headset that isn't recognised as the glasses — offered as
    /// "Use … as my glasses", since the GO3's advertised name is still a guess.
    var otherHeadset: GlassesAudioPort?

    var connected: Bool { glasses != nil }

    static let none = GlassesRouteState()

    /// `available` is only filled while the session can record (a voice turn), so at
    /// idle the glasses show up only while they are the output.
    static func resolve(outputs: [GlassesAudioPort], inputs: [GlassesAudioPort],
                        available: [GlassesAudioPort], rememberedKey: String?) -> GlassesRouteState {
        func isGlasses(_ port: GlassesAudioPort) -> Bool {
            guard port.isBluetooth, !port.deviceKey.isEmpty else { return false }
            // Once a pair is known, only it counts — whatever else is playing.
            if let rememberedKey { return port.deviceKey == rememberedKey }
            return GlassesAudioPort.looksLikeGo3(port.name)
        }
        let everything = outputs + inputs + available
        guard let glasses = everything.first(where: isGlasses) else {
            return GlassesRouteState(otherHeadset: everything.first { $0.isBluetooth })
        }
        return GlassesRouteState(glasses: glasses,
                                 speakers: outputs.contains(where: isGlasses),
                                 microphone: inputs.contains(where: isGlasses))
    }
}

/// Follows the phone's audio route and keeps `state` current for the card and the roster.
@Observable
@MainActor
final class GlassesAudioLink {
    static let shared = GlassesAudioLink()

    private(set) var state = GlassesRouteState.none
    /// The glasses' MAC once they have been on the route (or claimed) — mirrored here so
    /// the page updates when it changes; the value itself lives in `WearableIdentity`.
    private(set) var rememberedKey: String?
    /// What iOS reports about the glasses' audio link, for the page's Device section.
    private(set) var details = GlassesAudioDetails()

    var known: Bool { rememberedKey != nil }

    // The Get started steps, kept once done.
    /// Jarvis's speaker test played through the glasses.
    private(set) var heardSpeakers = UserDefaults.standard.bool(forKey: Keys.heard)
    /// The glasses' mics carried a voice turn.
    private(set) var usedMic = UserDefaults.standard.bool(forKey: Keys.usedMic)

    /// Start Voice the moment the glasses come onto the route (while the app is open).
    var startsVoiceOnConnect = UserDefaults.standard.bool(forKey: Keys.autoVoice) {
        didSet { UserDefaults.standard.set(startsVoiceOnConnect, forKey: Keys.autoVoice) }
    }

    private enum Keys {
        static let heard = "jc.glasses.heardSpeakers"
        static let usedMic = "jc.glasses.usedMic"
        static let autoVoice = "jc.glasses.startsVoiceOnConnect"
    }

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {}

    /// Idempotent; the hub calls it at launch (background launches too) and on every
    /// return to the foreground.
    func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        let session = AVAudioSession.sharedInstance()
        let remembered = WearableIdentity.remembered(WearableKeepAlive.glasses)
        let next = GlassesRouteState.resolve(
            outputs: session.currentRoute.outputs.map(Self.port),
            inputs: session.currentRoute.inputs.map(Self.port),
            available: (session.availableInputs ?? []).map(Self.port),
            rememberedKey: remembered)
        if let glasses = next.glasses {
            // Remembered on first sight, so the roster keeps a row when they're off. Only
            // then: once known, `resolve` matches this device alone, by its MAC.
            if remembered == nil {
                WearableIdentity.remember(glasses.deviceKey, for: WearableKeepAlive.glasses)
                JcLog.devices.notice("glasses: recognised \(glasses.name, privacy: .public)")
            }
            WearableIdentity.noteSeenNow(WearableKeepAlive.glasses)
        } else if state.connected {
            // Just left the route: that is when they were last seen, not the route change before.
            WearableIdentity.noteSeenNow(WearableKeepAlive.glasses)
        }
        if next.microphone && !usedMic {
            usedMic = true
            UserDefaults.standard.set(true, forKey: Keys.usedMic)
        }
        if next.connected && !state.connected && startsVoiceOnConnect
            && UIApplication.shared.applicationState == .active {
            NotificationCenter.default.post(name: VoiceLaunchBridge.notificationName, object: nil)
        }
        let key = WearableIdentity.remembered(WearableKeepAlive.glasses)
        if key != rememberedKey { rememberedKey = key }
        let nextDetails = Self.details(of: next.glasses, in: session)
        if nextDetails != details { details = nextDetails }
        if next != state { state = next }
    }

    /// The speaker test finished while the replies were going to the glasses.
    func noteHeardSpeakers() {
        guard !heardSpeakers else { return }
        heardSpeakers = true
        UserDefaults.standard.set(true, forKey: Keys.heard)
    }

    /// "Use … as my glasses": the headset on the route is the GO3 under another name.
    func claim(_ port: GlassesAudioPort) {
        WearableIdentity.remember(port.deviceKey, for: WearableKeepAlive.glasses)
        refresh()
    }

    /// Undo a wrong claim; the card goes back to looking for the glasses. (An INMO-named
    /// pair still on the route is simply recognised again — they are the glasses.)
    func forget() {
        WearableIdentity.forget(WearableKeepAlive.glasses)
        refresh()
    }

    private static func port(_ description: AVAudioSessionPortDescription) -> GlassesAudioPort {
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        return GlassesAudioPort(name: description.portName, uid: description.uid,
                                isBluetooth: bluetooth.contains(description.portType))
    }

    private static func details(of glasses: GlassesAudioPort?, in session: AVAudioSession) -> GlassesAudioDetails {
        guard let glasses else { return GlassesAudioDetails() }
        let route = session.currentRoute
        let theirs = (route.outputs + route.inputs + (session.availableInputs ?? []))
            .filter { port($0).deviceKey == glasses.deviceKey }
        var profiles: [String] = []
        for type in theirs.map(\.portType) {
            let name = type == .bluetoothA2DP ? "A2DP" : type == .bluetoothHFP ? "HFP" : "LE Audio"
            if !profiles.contains(name) { profiles.append(name) }
        }
        let onRoute = route.outputs.contains { port($0).deviceKey == glasses.deviceKey }
            || route.inputs.contains { port($0).deviceKey == glasses.deviceKey }
        return GlassesAudioDetails(profiles: profiles,
                                   sampleRate: onRoute ? session.sampleRate : nil,
                                   outputLatencyMs: onRoute ? Int((session.outputLatency * 1000).rounded()) : nil)
    }
}

/// The glasses' audio link as iOS describes it — only while they are on the route.
struct GlassesAudioDetails: Equatable {
    /// "A2DP" (music-quality playback), "HFP" (the mics, and calls), "LE Audio".
    var profiles: [String] = []
    /// Hz. HFP runs at 16 kHz or 8 kHz; A2DP-only playback at the phone's own rate.
    var sampleRate: Double?
    var outputLatencyMs: Int?
}
