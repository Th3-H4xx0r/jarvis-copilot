import Foundation

/// How speech becomes text.
///
/// `onDevice` — Apple's on-device engine is the ONLY transcriber: no audio is
/// sent to the server, the client's endpointer ends the turn, and the words go
/// up as text. If it heard no words, nothing is sent.
/// `server` — the audio always goes to the server, which transcribes it, and the
/// on-device engine never runs.
///
/// Per device, like the turn mode and the model.
enum VoiceTranscription: String, CaseIterable, Sendable {
    case onDevice = "on_device"
    case server

    /// `.server` is the server's voice engine — Soniox, with the server's own
    /// model as its fallback when Soniox cannot run.
    var label: String { self == .onDevice ? "On device" : "Soniox" }
}

/// Voice preferences that must survive a relaunch: which TTS engine + voice the
/// user picked and the conversation mode. Behind `KeyValueStore` so tests use
/// `MemoryKeyValueStore`.
///
/// Keys keep their `jc_` Flutter prefixes so a user upgrading from the Flutter
/// build keeps their choices.
@MainActor
@Observable
final class VoiceSettings {

    static let engineKey = "jc_voice_engine"
    static let voiceKey = "jc_voice_voice"
    static let modeKey = "jc_voice_mode"
    /// `_v2`: "server" was the default under the old key, stored or not, and the
    /// new default (on the device) has to reach those installs too.
    static let transcriptionKey = "jc_voice_transcription_v2"
    /// Which surface the Voice tab shows: the conversation orb, or Live Jarvis's
    /// ambient transcript. Persisted here beside the other per-device voice
    /// choices, per design §7.1.
    static let liveModeKey = "jc_voice_live_mode"
    /// Written by the Siri intent / Control-Center control before the app is up.
    static let pendingVoiceKey = "jc_pending_voice"

    private let store: KeyValueStore

    init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store
        _engine = store.string(Self.engineKey)
        _voice = store.string(Self.voiceKey)
        _mode = VoiceMode(rawValue: store.string(Self.modeKey) ?? "") ?? .realtime
        // On the device by default: a phone or Mac transcribes itself, and a turn
        // uses the server's engine (Soniox) only by choice, or when this device
        // cannot (`VoiceStore.ensureTranscription`).
        _transcription = VoiceTranscription(rawValue: store.string(Self.transcriptionKey) ?? "")
            ?? .onDevice
        // Regular Voice by default: an update must not move an existing install
        // onto an always-listening screen it never asked for.
        _liveMode = store.bool(Self.liveModeKey) ?? false
    }

    // Backing fields so the setters can persist. `@Observable` tracks the
    // computed properties through these.
    private var _engine: String?
    private var _voice: String?
    private var _mode: VoiceMode
    private var _transcription: VoiceTranscription
    private var _liveMode: Bool

    /// Selected TTS engine id (nil = let the server use its own default).
    var engine: String? {
        get { _engine }
        set {
            let clean = (newValue?.isEmpty ?? true) ? nil : newValue
            _engine = clean
            store.set(clean, forKey: Self.engineKey)
        }
    }

    /// Selected voice within the engine.
    var voice: String? {
        get { _voice }
        set {
            let clean = (newValue?.isEmpty ?? true) ? nil : newValue
            _voice = clean
            store.set(clean, forKey: Self.voiceKey)
        }
    }

    var mode: VoiceMode {
        get { _mode }
        set { _mode = newValue; store.set(newValue.rawValue, forKey: Self.modeKey) }
    }

    var transcription: VoiceTranscription {
        get { _transcription }
        set { _transcription = newValue; store.set(newValue.rawValue, forKey: Self.transcriptionKey) }
    }

    /// True when the Voice tab shows Live Jarvis instead of the conversation orb.
    var liveMode: Bool {
        get { _liveMode }
        set { _liveMode = newValue; store.set(newValue, forKey: Self.liveModeKey) }
    }

    /// Selecting an engine drops a stale voice: voice ids are engine-specific,
    /// so keeping ElevenLabs' voice when switching to Edge would 400.
    func selectEngine(_ id: String?, voice newVoice: String? = nil) {
        if id != engine { voice = nil }
        engine = id
        if let newVoice { voice = newVoice }
    }
}
