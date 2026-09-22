#if os(iOS)
import AVFoundation
#endif
import Foundation

/// Whether a wearable can act as a microphone.
///
/// The requirement was explicit: a wearable bought LATER — smart glasses were the
/// example — must appear as a capture source with no code change. So this must not
/// be a list of device names, and it must not be a list of device *kinds* either:
/// a new kind is still a new string somebody has to add.
///
/// Instead a device DECLARES a mic, the way every other device trait already
/// reaches the app: through the capability list it advertises
/// (`WearableDevice.capabilities`, which is also what `DeviceRegistry.allSkills()`
/// publishes to the server). Any device whose advertised capability names contain
/// a microphone token is offered, whatever it is called and whenever it appears.
///
/// The manual override exists because a device's firmware author chooses those
/// names, and a device that spells it something unanticipated should not need an
/// app release. It is per-device and local, like every other wearable preference.
enum LiveMicCapability {

    /// Substrings in an advertised capability name that mean "this device can hand
    /// over microphone audio". Matched as substrings, not equality, so
    /// `mic_stream_start`, `start_microphone` and `audio_in` all count.
    static let tokens = ["mic", "microphone", "audio_in", "audio_stream", "listen"]

    /// Capability names that contain a token but are NOT about capturing: a device
    /// that can mute a mic, or report one, is not a microphone we can read.
    static let exclusions = ["mute", "unmute", "volume", "level", "status", "info"]

    static func advertises(_ names: [String]) -> Bool {
        names.contains { name in
            let lower = name.lowercased()
            guard tokens.contains(where: lower.contains) else { return false }
            return !exclusions.contains(where: lower.contains)
        }
    }

    private static func overrideKey(_ deviceID: String) -> String { "jc.live.mic.\(deviceID)" }

    /// The user's explicit answer for this device, when they gave one.
    static func override(_ deviceID: String, store: KeyValueStore = UserDefaults.standard) -> Bool? {
        store.bool(overrideKey(deviceID))
    }

    static func setOverride(_ value: Bool?, for deviceID: String,
                            store: KeyValueStore = UserDefaults.standard) {
        store.set(value, forKey: overrideKey(deviceID))
    }

    /// The answer for a device: the user's override if they set one, otherwise what
    /// the device advertises.
    static func hasMic(deviceID: String, advertised: [String],
                       store: KeyValueStore = UserDefaults.standard) -> Bool {
        override(deviceID, store: store) ?? advertises(advertised)
    }
}

/// Where Live mode takes its audio from.
struct LiveCaptureSource: Identifiable, Equatable, Sendable {

    enum Kind: String, Equatable, Sendable {
        /// Whatever iOS considers the default input. Always present, never stale.
        case automatic
        /// A specific `AVAudioSession` input port — built-in, wired, AirPods.
        case route
        /// A Jarvis wearable that advertises a mic.
        case wearable
    }

    var id: String
    var kind: Kind
    /// What the picker shows, and what goes up as `source_label` on session start.
    var label: String
    /// A second line: the port type, or the wearable's model.
    var detail: String?
    var symbol: String
    /// False for a remembered-but-absent route or a disconnected wearable.
    var available: Bool = true
    /// **The honest flag.** False means selecting this source cannot currently
    /// produce audio — no wearable transport carries a mic stream into the app
    /// today (verified: the Pod streams to the SERVER, the Watch only receives
    /// clips, and the BLE protocols have no audio channel at all). The UI says so
    /// rather than showing a recording state that captures nothing.
    var canStream: Bool = true

    static let automaticID = "automatic"

    static var automatic: LiveCaptureSource {
        LiveCaptureSource(id: automaticID, kind: .automatic,
                          label: "Automatic", detail: "Whichever mic iOS picks",
                          symbol: "waveform", available: true, canStream: true)
    }
}

/// Builds the capture-source list. Split from the store so the list logic is
/// testable without a mic or a wearable.
@MainActor
enum LiveCaptureSources {

    /// Local `AVAudioSession` inputs, newest-connected first as iOS orders them.
    ///
    /// `availableInputs` is EMPTY unless the session's category permits recording,
    /// which is why the caller holds the ambient claim before asking. An empty list
    /// is reported as just `.automatic` rather than as "no microphone".
    static func routes() -> [LiveCaptureSource] {
        #if os(iOS)
        let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
        return inputs.map { port in
            LiveCaptureSource(id: "route:" + port.uid,
                              kind: .route,
                              label: port.portName,
                              detail: describe(port.portType),
                              symbol: symbol(for: port.portType),
                              available: true,
                              canStream: true)
        }
        #else
        return []
        #endif
    }

    /// Wearables that advertise a mic. Disconnected ones are still listed — so the
    /// user can see the AirPods-style entry they expect and be told it is not
    /// connected, instead of wondering why their device is missing.
    /// `hub` / `registry` are optionals rather than defaulted `.shared`: a default
    /// argument cannot touch a `@MainActor` singleton (the same limitation
    /// `AudioSessionArbiter` and `DefaultAudioSessionControlling` work around).
    static func wearables(hub: WearablesHub? = nil,
                          registry: DeviceRegistry? = nil,
                          store: KeyValueStore = UserDefaults.standard) -> [LiveCaptureSource] {
        let hub = hub ?? .shared
        let registry = registry ?? .shared
        return hub.roster().compactMap { entry in
            let advertised = registry.device(id: entry.deviceID)?.capabilities.map(\.name) ?? []
            guard LiveMicCapability.hasMic(deviceID: entry.deviceID,
                                           advertised: advertised, store: store) else { return nil }
            return LiveCaptureSource(
                id: "wearable:" + entry.deviceID,
                kind: .wearable,
                label: entry.name.isEmpty ? entry.model : entry.name,
                detail: entry.connected ? entry.model : "\(entry.model) — not connected",
                symbol: "dot.radiowaves.left.and.right",
                available: entry.connected,
                // Honest: no wearable transport carries audio into the app yet.
                canStream: false)
        }
    }

    /// The whole picker, `.automatic` first.
    static func all(hub: WearablesHub? = nil,
                    registry: DeviceRegistry? = nil,
                    store: KeyValueStore = UserDefaults.standard) -> [LiveCaptureSource] {
        [.automatic] + routes() + wearables(hub: hub, registry: registry, store: store)
    }

    /// Resolve a persisted id against what is actually here now.
    ///
    /// A source that has gone away falls back to `.automatic` rather than failing:
    /// unplugging headphones must not stop an ambient capture, it must keep
    /// recording from whatever is left and relabel itself.
    /// `canStream` is part of the guard, not just `available`: a source that cannot
    /// carry audio must never become the active microphone, or the screen would name
    /// it while the phone quietly recorded — and with no notice, because `select` was
    /// not the thing that chose it this time.
    static func resolve(id: String?, among sources: [LiveCaptureSource]) -> LiveCaptureSource {
        guard let id, !id.isEmpty,
              let match = sources.first(where: { $0.id == id }),
              match.available, match.canStream
        else { return sources.first(where: { $0.kind == .automatic }) ?? .automatic }
        return match
    }

    /// Ask iOS to use this source. Returns false when the route could not be set,
    /// which the caller reports rather than swallowing — silently recording from
    /// the wrong mic is the failure mode this whole picker exists to remove.
    @discardableResult
    static func apply(_ source: LiveCaptureSource) -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        switch source.kind {
        case .automatic:
            do { try session.setPreferredInput(nil); return true }
            catch {
                JcLog.dropped(JcLog.voice, "clear preferred input", error)
                return false
            }
        case .route:
            let uid = String(source.id.dropFirst("route:".count))
            guard let port = (session.availableInputs ?? []).first(where: { $0.uid == uid }) else {
                return false
            }
            do { try session.setPreferredInput(port); return true }
            catch {
                JcLog.dropped(JcLog.voice, "set preferred input", error)
                return false
            }
        case .wearable:
            // Nothing to apply: there is no path from a wearable's mic into this
            // process. Reported as a refusal so the caller states it plainly.
            return false
        }
        #else
        return source.kind == .automatic
        #endif
    }

    /// The label the phone should report for whatever it is ACTUALLY recording from
    /// right now, which after a route change is not necessarily what was chosen.
    static func currentRouteLabel() -> String {
        #if os(iOS)
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        guard let first = inputs.first else { return "No input" }
        return first.portName
        #else
        return "Default input"
        #endif
    }

    #if os(iOS)
    private static func describe(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInMic: return "Built-in microphone"
        case .headsetMic: return "Wired headset"
        case .bluetoothHFP: return "Bluetooth"
        case .usbAudio: return "USB"
        case .carAudio: return "Car"
        case .airPlay: return "AirPlay"
        default: return type.rawValue
        }
    }

    private static func symbol(for type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInMic: return "mic"
        case .headsetMic: return "headphones"
        // AirPods arrive as a Bluetooth hands-free port; the headphones glyph reads
        // better than a generic radio one for what is almost always AirPods.
        case .bluetoothHFP: return "headphones"
        case .usbAudio: return "cable.connector"
        case .carAudio: return "car"
        default: return "mic"
        }
    }
    #endif
}
