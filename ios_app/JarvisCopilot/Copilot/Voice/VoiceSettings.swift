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

    var label: String { self == .onDevice ? "On device" : "Server" }
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
    static let transcriptionKey = "jc_voice_transcription"
    /// Written by the Siri intent / Control-Center control before the app is up.
    static let pendingVoiceKey = "jc_pending_voice"

    private let store: KeyValueStore

    init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store
        _engine = store.string(Self.engineKey)
        _voice = store.string(Self.voiceKey)
        _mode = VoiceMode(rawValue: store.string(Self.modeKey) ?? "") ?? .realtime
        // Server by default: it is what every existing install already does, so
        // an update changes nothing until the user chooses otherwise.
        _transcription = VoiceTranscription(rawValue: store.string(Self.transcriptionKey) ?? "")
            ?? .server
    }

    // Backing fields so the setters can persist. `@Observable` tracks the
    // computed properties through these.
    private var _engine: String?
    private var _voice: String?
    private var _mode: VoiceMode
    private var _transcription: VoiceTranscription

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

    /// Selecting an engine drops a stale voice: voice ids are engine-specific,
    /// so keeping ElevenLabs' voice when switching to Edge would 400.
    func selectEngine(_ id: String?, voice newVoice: String? = nil) {
        if id != engine { voice = nil }
        engine = id
        if let newVoice { voice = newVoice }
    }
}
