import Foundation

/// The Live choices that belong to THIS device rather than to the account.
///
/// Design §6 draws the line: watcher toggles, the window interval, reply mode and
/// primary language are one source of truth on the server (`/api/live/config`),
/// because the web popup edits the same settings. Which microphone this phone uses,
/// and whether this phone captures at all, are meaningless anywhere else — a
/// server-stored "capture source" would be wrong the moment a second device joined.
///
/// Behind `KeyValueStore` so tests use `MemoryKeyValueStore`, like `VoiceSettings`.
@MainActor
@Observable
final class LiveSettings {

    /// Id of the chosen `LiveCaptureSource` (`automatic`, `route:<uid>`,
    /// `wearable:<deviceID>`).
    static let captureSourceKey = "jc_live_capture_source"
    /// Whether this device is allowed to be a recorder. Off makes the Live screen a
    /// viewer of whatever another device is capturing.
    static let captureHereKey = "jc_live_capture_here"
    /// The last live session this device was part of, so a relaunch can offer to
    /// resume it instead of starting a second recording of the same conversation.
    static let lastSessionKey = "jc_live_last_session"
    /// The cursor reached in that session — `after_seq` on resume.
    static let lastSeqKey = "jc_live_last_seq"
    /// How far the session's AUDIO clock had got. Resuming without it would restart
    /// timestamps at zero and collide with the rows already in the transcript.
    static let lastElapsedKey = "jc_live_last_elapsed_ms"
    /// The audio frame counter, for the same reason.
    static let lastAudioSeqKey = "jc_live_last_audio_seq"
    /// The paired chat session, so a resumed recording still knows it has one.
    static let lastChatSessionKey = "jc_live_last_chat_session"
    /// Whether THIS phone translates the lines it records (Apple, on device) or
    /// leaves them to the server. Per phone: the language packs are on it.
    static let translateOnPhoneKey = "jc_live_translate_on_phone"

    private let store: KeyValueStore

    init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store
        _captureSourceID = store.string(Self.captureSourceKey) ?? LiveCaptureSource.automaticID
        // Default ON: a user who opened Live mode on their phone meant to record
        // with it. Viewing-only is the deliberate choice, not the default.
        _captureHere = store.bool(Self.captureHereKey) ?? true
        _lastSessionID = store.string(Self.lastSessionKey) ?? ""
        _lastSeq = Int(store.string(Self.lastSeqKey) ?? "") ?? 0
        _lastElapsedMs = Int(store.string(Self.lastElapsedKey) ?? "") ?? 0
        _lastAudioSeq = Int(store.string(Self.lastAudioSeqKey) ?? "") ?? 0
        _lastChatSessionID = store.string(Self.lastChatSessionKey) ?? ""
        // Default ON: the phone is instant and private, and hands the server
        // any pair it has no pack for anyway.
        _translateOnPhone = store.bool(Self.translateOnPhoneKey) ?? true
    }

    private var _captureSourceID: String
    private var _captureHere: Bool
    private var _lastSessionID: String
    private var _lastSeq: Int
    private var _lastElapsedMs: Int
    private var _lastAudioSeq: Int
    private var _lastChatSessionID: String
    private var _translateOnPhone: Bool

    var captureSourceID: String {
        get { _captureSourceID }
        set {
            let clean = newValue.isEmpty ? LiveCaptureSource.automaticID : newValue
            _captureSourceID = clean
            store.set(clean, forKey: Self.captureSourceKey)
        }
    }

    var captureHere: Bool {
        get { _captureHere }
        set { _captureHere = newValue; store.set(newValue, forKey: Self.captureHereKey) }
    }

    var translateOnPhone: Bool {
        get { _translateOnPhone }
        set { _translateOnPhone = newValue; store.set(newValue, forKey: Self.translateOnPhoneKey) }
    }

    var lastSessionID: String {
        get { _lastSessionID }
        set { _lastSessionID = newValue; store.set(newValue, forKey: Self.lastSessionKey) }
    }

    /// Stored as a STRING: `KeyValueStore` exposes only `string` and `bool`, and
    /// widening that protocol for one integer would touch every conformer.
    var lastSeq: Int {
        get { _lastSeq }
        set { _lastSeq = newValue; store.set(String(newValue), forKey: Self.lastSeqKey) }
    }

    var lastElapsedMs: Int {
        get { _lastElapsedMs }
        set { _lastElapsedMs = newValue; store.set(String(newValue), forKey: Self.lastElapsedKey) }
    }

    var lastAudioSeq: Int {
        get { _lastAudioSeq }
        set { _lastAudioSeq = newValue; store.set(String(newValue), forKey: Self.lastAudioSeqKey) }
    }

    /// The paired chat session of the session being resumed. Without it a resumed
    /// recording loses the "this also appears in Chats" link it had a moment ago.
    var lastChatSessionID: String {
        get { _lastChatSessionID }
        set { _lastChatSessionID = newValue; store.set(newValue, forKey: Self.lastChatSessionKey) }
    }

    /// Where the session's audio clock and frame counter had reached. Recorded at
    /// utterance boundaries rather than per frame, so a relaunch mid-session costs
    /// at most one utterance of timing rather than putting the whole resumed
    /// conversation back at zero.
    func rememberAudioClock(sessionID: String, elapsedMs: Int, audioSeq: Int) {
        guard !sessionID.isEmpty, sessionID == lastSessionID else { return }
        if elapsedMs > lastElapsedMs { lastElapsedMs = elapsedMs }
        if audioSeq > lastAudioSeq { lastAudioSeq = audioSeq }
    }

    /// Remember where we got to, so a drop that outlives the process still resumes
    /// at the right cursor rather than replaying the whole conversation.
    func rememberCursor(sessionID: String, seq: Int) {
        guard !sessionID.isEmpty else { return }
        // A DIFFERENT session restarts the cursor. Carrying the old one over would
        // have a fresh conversation resume from a seq it never reached, so the
        // server would be asked to skip rows that do not exist — and the transcript
        // would open with a hole in it.
        if lastSessionID != sessionID {
            lastSessionID = sessionID
            lastSeq = seq
            // A new conversation starts its audio clock at zero too.
            lastElapsedMs = 0
            lastAudioSeq = 0
            return
        }
        // Within one session the cursor is monotonic: an out-of-order frame must not
        // rewind it and cause a replay of rows already on screen.
        if seq > lastSeq { lastSeq = seq }
    }

    func forgetCursor() {
        lastSessionID = ""
        lastSeq = 0
        lastElapsedMs = 0
        lastAudioSeq = 0
        lastChatSessionID = ""
    }
}
