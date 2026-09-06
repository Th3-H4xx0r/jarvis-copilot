import Foundation

/// Voice preferences that must survive a relaunch: which TTS engine + voice the
/// user picked, the conversation mode, and the wake-word opt-in. Behind
/// `KeyValueStore` so tests use `MemoryKeyValueStore`.
///
/// Keys keep their `jc_` Flutter prefixes so a user upgrading from the Flutter
/// build keeps their choices.
@MainActor
@Observable
final class VoiceSettings {

    static let engineKey = "jc_voice_engine"
    static let voiceKey = "jc_voice_voice"
    static let modeKey = "jc_voice_mode"
    static let wakeWordKey = "jc_voice_wake_word"
    /// Written by the Siri intent / Control-Center control before the app is up.
    static let pendingVoiceKey = "jc_pending_voice"

    private let store: KeyValueStore

    init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store
        _engine = store.string(Self.engineKey)
        _voice = store.string(Self.voiceKey)
        _mode = VoiceMode(rawValue: store.string(Self.modeKey) ?? "") ?? .realtime
        _wakeWordEnabled = store.bool(Self.wakeWordKey) ?? false
    }

    // Backing fields so the setters can persist. `@Observable` tracks the
    // computed properties through these.
    private var _engine: String?
    private var _voice: String?
    private var _mode: VoiceMode
    private var _wakeWordEnabled: Bool

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

    /// The "Hey Jarvis" foreground listener. Off by default: it's battery-heavy
    /// and iOS can't run a custom wake word in the background anyway.
    var wakeWordEnabled: Bool {
        get { _wakeWordEnabled }
        set { _wakeWordEnabled = newValue; store.set(newValue, forKey: Self.wakeWordKey) }
    }

    /// Selecting an engine drops a stale voice: voice ids are engine-specific,
    /// so keeping ElevenLabs' voice when switching to Edge would 400.
    func selectEngine(_ id: String?, voice newVoice: String? = nil) {
        if id != engine { voice = nil }
        engine = id
        if let newVoice { voice = newVoice }
    }
}
