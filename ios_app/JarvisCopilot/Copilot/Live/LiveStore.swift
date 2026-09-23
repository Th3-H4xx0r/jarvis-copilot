import Foundation

/// One row in the Live transcript: an utterance, or a watcher's note. They share
/// the `seq` space, which is what lets them interleave in the order they happened
/// instead of the insights piling up at the bottom.
enum LiveRow: Identifiable, Equatable, Sendable {
    case segment(LiveSegment)
    case insight(LiveInsight)

    var seq: Int {
        switch self {
        case .segment(let s): return s.seq
        case .insight(let i): return i.seq
        }
    }

    var id: String {
        switch self {
        case .segment(let s): return "s\(s.seq)"
        // The insight's LOCAL id, not its `seq`: one monitor window's notes all
        // carry the same `seq`, so `seq` is not unique and SwiftUI would render
        // one row for the lot.
        case .insight(let i): return "i\(i.localID)"
        }
    }

    /// Orders rows that claim the same `seq`. 0 for an utterance, so a note
    /// about it always follows it; the insight's local id otherwise, which is
    /// the order the watcher produced them in.
    var tiebreak: Int {
        switch self {
        case .segment: return 0
        case .insight(let i): return i.localID
        }
    }
}

/// Why capture stopped in a way the user must see. Design §8: running out of spool
/// or disk stops capture with a LOUD state rather than silently losing hours, so
/// this is deliberately not just another line in the status pill.
struct LiveHalt: Equatable, Sendable {
    var title: String
    var detail: String
}

/// Live Jarvis on this device: the socket, the ambient microphone, the transcript,
/// and the resilience rules of design §8.
@MainActor
@Observable
final class LiveStore {

    static let shared = LiveStore(translationSessions: LiveStore.systemTranslationSessions(),
                                  voiceprints: { LiveVoiceprintEmbedder() },
                                  onDevice: { await LiveModels.shared.transcriber() })

    /// Translation sessions that need no view, where this OS has them. Only the
    /// app's own store gets Apple's: a test store would otherwise reach into the
    /// real framework the moment a foreign row arrived.
    static func systemTranslationSessions() -> DirectTranslationSessions? {
        #if canImport(Translation)
        if #available(iOS 26.0, *) { return InstalledTranslationSessions() }
        #endif
        return nil
    }

    /// The rate the ambient mic produces and the rate declared in `hello`.
    static let micRate = 16000

    /// Reconnect backoff. A real iPhone drops a long-lived stream about once a
    /// minute (§8), so the first retry is fast — a slow first retry would spend
    /// most of a conversation disconnected.
    static let reconnectDelaysMs = [400, 1200, 3000, 6000, 10000]

    /// How long an utterance's on-device transcription may take before we give up
    /// on it and send the audio-only path instead. A wedged analyzer must not stall
    /// the next utterance.
    static let transcriptionDeadlineMs = 4000

    /// How long the recogniser's words must stay unchanged before the line is
    /// over and gets committed.
    ///
    /// This, not the level gate, is what ends a line now. Measured on real
    /// sessions: the room's noise sat above the gate, the gate never closed, and
    /// every row waited for the 15 s cap — a median of 11.5 s between the last
    /// word and the row. Apple's transcriber stops producing words when the
    /// words stop, whatever the room is doing, and it publishes them in steps of
    /// about 940 ms, so anything much under this would end a line between two
    /// of its own words. Replayed against the same recordings: 0.5–2.1 s.
    static let wordsSettledMs = 1200

    /// Audio kept before speech opens, so an utterance's first consonant is not
    /// clipped off the recording. ~400 ms.
    static let preRollFrames = 5

    /// Cap on speech held while the transcription session opens — about 3 s at the
    /// ambient tap size. A session that never arrives must not grow this without
    /// limit for the length of a monologue.
    static let maxPendingSpeechFrames = 40

    /// Warn at this spool fill before the hard stop, so a failing uplink is visible
    /// while there is still time to do something about it.
    static let spoolWarnFill = 0.6

    /// How often the mic watchdog checks that audio is still arriving. The tap's own
    /// `isRunning` goes false after 3 s of no buffers, so this is just often enough
    /// to notice without polling hard.
    static let micWatchdogMs = 2000

    /// Frames uploaded per drain turn. A 30 MB backlog recovered in one go would
    /// base64 and write the lot on the main actor, freezing the UI exactly while the
    /// feature is supposed to be recovering.
    static let drainBatch = 256

    /// How many frames may sit unconfirmed before the oldest are assumed delivered.
    /// A window, not a log: at ~50 frames a second this is a couple of seconds of
    /// audio, which is the scale of a socket death going unnoticed.
    static let inFlightWindow = 150

    // MARK: - Observable state

    /// The rows and the relabelling rules — see `LiveTranscript`, which is where the
    /// retroactive-merge behaviour lives.
    private(set) var transcript = LiveTranscript()

    var segments: [LiveSegment] { transcript.segments }
    var insights: [LiveInsight] { transcript.insights }
    /// Transcript and insights in one timeline.
    var rows: [LiveRow] { transcript.rows }

    private(set) var capturing = false
    private(set) var connected = false
    /// True while a call or Siri holds the mic. Capture auto-resumes (§8).
    private(set) var interrupted = false
    /// The codec this device declares in `hello` AND the encoding its audio frames
    /// are actually in — one value, read by both, because the failure mode worth
    /// designing against is the two disagreeing. `"opus-packets"` normally,
    /// `"pcm16"` when this OS's CoreAudio will not encode Opus.
    private(set) var audioCodec = "pcm16"
    /// The rate that goes with `audioCodec`: 48000 for Opus (the rate a decoder
    /// needs), the microphone's rate for PCM16.
    private(set) var audioRate = LiveStore.micRate
    /// Why the recording is uncompressed, when it is. Shown rather than silently
    /// costing the user ten times the disk.
    private(set) var codecNotice = ""
    private(set) var lane = LiveLane.server
    private(set) var liveSessionID = ""
    private(set) var chatSessionID = ""
    /// Why on-device transcription is not running, when it is not. Shown in the
    /// status line — §8 requires the fallback to the server lane be STATED.
    private(set) var sttNotice = ""
    private(set) var storageBytes = 0
    /// A capacity or backpressure warning the SERVER sent. Separate from
    /// `spoolWarning` so the two writers cannot erase one another — draining the
    /// local backlog used to clear a server warning that had nothing to do with it.
    private(set) var serverWarning = ""
    /// Our own backlog warning: the uplink is failing and this device is holding
    /// conversation it has not managed to send.
    private(set) var spoolWarning = ""
    /// True while the speech model is being fetched. Without it the screen reads
    /// "Not recording" through a download the user just asked for.
    private(set) var preparing = false
    private(set) var prepareProgress = 0.0
    /// The server says it is not receiving audio from us. Believing our own
    /// `capturing` flag over this is how a recording screen sits over a mic the
    /// server considers silent.
    private(set) var serverPaused = false
    private(set) var error = ""
    /// Set when capture has stopped in a way that must not be missed.
    private(set) var halt: LiveHalt?
    /// Level meter, 0...1.
    private(set) var level = 0.0
    /// When capture began, or nil. One clock, read by the screen, the tab-bar
    /// indicator and the Live Activity — a second `Date` kept in a view's
    /// `@State` (which is where this used to live) drifts from this one the
    /// moment capture restarts without the view being rebuilt.
    private(set) var captureStartedAt: Date?
    /// The utterance being spoken RIGHT NOW, straight from this phone's own
    /// recogniser — before any server round trip.
    ///
    /// Not part of `transcript`: it is a guess that is about to be replaced, so
    /// it must not reach the resume cursor, the rollover budget, fact-check,
    /// naming or translation. Cleared the instant its committed row lands.
    private(set) var partialText = ""
    /// Where the in-progress utterance began on the session clock, for its
    /// timestamp.
    private(set) var partialStartMs = 0
    /// The words of the utterance that just ENDED, on screen until its committed
    /// row lands.
    ///
    /// A slot of its own because lines now end back to back: the next line's
    /// words are already arriving in `partialText` while this one is on its way to
    /// the server, and the echo of this one must take away only these words —
    /// clearing `partialText` on it would blank the sentence being spoken.
    private(set) var committingText = ""
    private(set) var committingStartMs = 0
    /// The end-of-session wrap-up, once the artifacts watcher has produced one.
    var wrapUp: LiveWrapUp? { transcript.wrapUp }
    private(set) var config = LiveConfig()
    private(set) var speakers: [LiveSpeaker] = []
    private(set) var storage = LiveStorage()
    /// The capture sources offered right now, and the one in use.
    private(set) var sources: [LiveCaptureSource] = [.automatic]
    private(set) var activeSource = LiveCaptureSource.automatic
    /// Unsent frames waiting on the socket. Surfaced so the status line can show a
    /// backlog instead of pretending everything is fine.
    private(set) var spooledFrames = 0
    private(set) var spoolFill = 0.0

    let settings: LiveSettings

    // MARK: - Collaborators

    private let api: LiveAPI
    private let input: AudioInput
    private let session: AmbientAudioSession
    private let recognizer: SpeechRecognizing
    private let connector: VoiceSocketConnecting
    private let clock: VoiceClock
    private let spool: LiveSpool
    private let preferences: KeyValueStore

    /// The recording indicator outside this screen: the tab-bar dot and the
    /// Live Activity. A computed property rather than an injected collaborator
    /// because it is a process-wide fact about the phone, not a dependency of
    /// this store — and because it must be reachable from `stop()` even on the
    /// paths where nothing else was ever set up.
    private var beacon: LiveCaptureBeacon { .shared }

    /// A `var`, and replaced for every new session: `AmbientSegmenter.reset()`
    /// deliberately never rewinds its audio clock (so an utterance boundary cannot
    /// collide with the previous one), which means a SECOND recording in the same
    /// launch would otherwise start stamped at the first one's total duration.
    private var segmenter = AmbientSegmenter()
    /// PCM16 → Opus for the uplink. Nil when this OS refused the format, which is
    /// the ONLY state in which `audioCodec` may say `pcm16` — see `prepareEncoder`.
    /// On-device translation, so a foreign line gets its meaning in the same
    /// breath instead of after a round trip (see `LiveTranslator`). The server
    /// still does this for anything the phone cannot — a language Apple has no
    /// pack for, or a recording running while the screen is closed.
    let translator = LiveTranslator()

    private var encoder: AmbientOpusEncoder?
    private var socket: VoiceSocket?
    private var speech: SpeechSession?
    /// Where on the session's audio clock `speech` was handed its first sample.
    ///
    /// The recogniser reports its result ranges relative to its own first buffer,
    /// so without this anchor those ranges cannot be turned back into the
    /// timestamps a `seg` frame carries.
    private var speechAnchorMs = 0
    /// Whether on-device transcription is actually running. A `Bool` and not a test
    /// against `sttNotice`: deriving control flow from a user-facing string means any
    /// future notice silently switches the transcriber off.
    private var sttEnabled = false
    private var audioSeq = 0
    private var reconnectAttempt = 0
    private var reconnectTimer: VoiceTimerToken?
    private var micWatchdog: VoiceTimerToken?
    /// A synchronous latch for `start()`, which has three awaits before `capturing`
    /// becomes true. Without it a double-tap runs two starts, and the loser's
    /// teardown stops the winner's microphone.
    private var starting = false
    /// The rate the input was started at, so a watchdog restart asks for the same.
    private var captureRate = LiveStore.micRate
    /// Frames handed to the socket but not known to have arrived.
    ///
    /// `URLSessionWebSocketTask.send` reports failure asynchronously, so a dead TCP
    /// connection can swallow everything written in the seconds before `onClose`
    /// fires. These go back into the spool when the socket closes, which is the only
    /// way that window is not silent loss.
    private var inFlight: [LiveOutbound] = []
    /// One voices refresh at a time — a merge storm would otherwise fire one GET per
    /// `speaker` frame.
    private var loadingSpeakers = false
    private var preRoll: [Data] = []
    /// Speech heard before the transcription session finished opening.
    ///
    /// `startSession` is async, so the first frames of an utterance — which carry
    /// its first word — arrive while `speech` is still nil. Dropping them is how the
    /// opening word of every row goes missing. They are held here and fed in order
    /// the moment the session exists.
    private var pendingSpeechFrames: [Data] = []
    /// Bumped by every stop; a start or a reconnect that finishes to find it
    /// changed has been superseded.
    private var generation = 0
    /// When the mic was taken, by the WALL clock. The audio clock cannot measure a
    /// gap it heard nothing during, and this is the one thing in the capture path a
    /// wall clock is the right tool for.
    private var interruptedAt: Date?
    /// The session id this device ASKED to continue in its last `hello`.
    /// Compared against the id `ready` comes back with: the server decides when
    /// a conversation has grown past its budget and rolls it over, and this is
    /// how the client finds out (see `apply(_ ready:)`).
    private var resumeRequestedID = ""
    /// Drops an in-progress utterance that never produced a committed row — a
    /// recogniser that gave text and then died would otherwise leave that text
    /// on screen for the rest of the session.
    private var partialExpiry: VoiceTimerToken?
    /// The recogniser's last words for the open utterance, and when on the audio
    /// clock they last changed and first appeared. `wordsAreOver()` reads these.
    private var lastWords = ""
    /// Makes the voiceprint embedder, once, off the main actor — it loads a
    /// 13 MB model. Nil when this build does not make voiceprints (tests).
    private var voiceprintLoader: (@Sendable () -> VoiceprintEmbedding?)?
    private var voiceprints: VoiceprintEmbedding?
    private var voiceprintsTried = false
    /// The open utterance's samples, exactly as the recogniser was fed them, so
    /// its voiceprint and its second hearing are cut from the same audio its word
    /// range refers to. Rolling: in a noisy room the window can be open on room
    /// tone long before anyone speaks, so the OLDEST audio goes, never the words.
    private var utterancePCM = Data()
    /// How much audio has rolled off the front of `utterancePCM`.
    private var utteranceDroppedMs = 0
    /// Loads the downloaded on-device models (Parakeet, SenseVoice), and what
    /// it made. Nil when this build does not run them (tests).
    private var onDeviceLoader: (@MainActor () async -> OnDeviceTranscribing?)?
    private var onDevice: OnDeviceTranscribing?
    private var onDeviceLoading = false
    private var wordsChangedAtMs: Int?
    private var firstWordsAtMs: Int?

    /// How long an in-progress utterance may sit on screen after its audio
    /// ended without its committed row arriving. Long enough to cover the
    /// transcription deadline plus a round trip, short enough that a guess is
    /// never mistaken for the record.
    static let partialGraceMs = 6000

    init(api: LiveAPI = LiveAPI(),
         input: AudioInput? = nil,
         session: AmbientAudioSession? = nil,
         recognizer: SpeechRecognizing? = nil,
         connector: VoiceSocketConnecting? = nil,
         clock: VoiceClock? = nil,
         spool: LiveSpool? = nil,
         settings: LiveSettings? = nil,
         preferences: KeyValueStore = UserDefaults.standard,
         translationSessions: DirectTranslationSessions? = nil,
         voiceprints: (@Sendable () -> VoiceprintEmbedding?)? = nil,
         onDevice: (@MainActor () async -> OnDeviceTranscribing?)? = nil) {
        self.api = api
        self.input = input ?? AmbientAudioInput()
        self.session = session ?? AmbientAudioSession()
        self.recognizer = recognizer ?? DefaultSpeechRecognizing()
        self.connector = connector ?? URLSessionVoiceSocketConnector()
        self.clock = clock ?? SystemVoiceClock()
        self.spool = spool ?? LiveSpool()
        self.settings = settings ?? LiveSettings()
        self.preferences = preferences
        translator.direct = translationSessions
        voiceprintLoader = voiceprints
        onDeviceLoader = onDevice
        wire()
    }

    private func wire() {
        input.onFrame = { [weak self] pcm in self?.handle(frame: pcm) }
        (input as? AmbientAudioInput)?.onRouteChange = { [weak self] in self?.routeChanged() }
        session.onInterruption = { [weak self] event in self?.handle(interruption: event) }
        spooledFrames = spool.count
        spoolFill = spool.fill
        adoptTranslator()
    }

    // MARK: - Device identity

    /// The server-issued device id when this phone has one, else a stable local id.
    ///
    /// A fresh UUID per launch would look like a new device to the server on every
    /// start, so `hello` would never match a resume and every relaunch would open a
    /// second recording of the same conversation.
    private var deviceID: String {
        if let id = preferences.string(PushHandler.deviceIDKey), !id.isEmpty { return id }
        let key = "jc.live.local_device_id"
        if let id = preferences.string(key), !id.isEmpty { return id }
        let minted = "ios-" + String(UUID().uuidString.prefix(8)).lowercased()
        preferences.set(minted, forKey: key)
        return minted
    }

    // MARK: - Lifecycle

    /// Load what the screen needs without touching the microphone. Safe to call on
    /// every appearance.
    func load() async {
        refreshSources()
        async let cfg: Void = loadConfig()
        async let spk: Void = loadSpeakers()
        async let stg: Void = loadStorage()
        _ = await (cfg, spk, stg)
    }

    func loadConfig() async {
        do { config = try await api.config(); clearTransientError() }
        catch { report("load Live settings", error) }
    }

    func loadSpeakers() async {
        // Coalesced: a merge storm used to spawn one GET per `speaker` frame, each
        // able to overwrite the error slot.
        guard !loadingSpeakers else { return }
        loadingSpeakers = true
        defer { loadingSpeakers = false }
        do { speakers = try await api.speakers(); clearTransientError() }
        catch { report("load voices", error) }
    }

    func loadStorage() async {
        do {
            storage = try await api.storage()
            // The panel's total is the authority; a `state` frame's number is a
            // live estimate between panel loads.
            storageBytes = storage.totalBytes
            clearTransientError()
            pushBeacon()
        } catch { report("load storage", error) }
    }

    /// Dismiss the current message. The toast is tappable, because an error with no
    /// way out sits over the transcript for the rest of the session.
    func dismissError() { error = "" }

    /// A successful load withdraws a previous load's complaint. Only transient
    /// failures are cleared this way — a halt has its own banner and its own dismiss,
    /// so it cannot be wiped by an unrelated request succeeding.
    private func clearTransientError() {
        guard halt == nil else { return }
        error = ""
    }

    func save(_ updated: LiveConfig) async {
        let previous = config
        config = updated
        do { try await api.saveConfig(updated) }
        catch {
            // Put the UI back on what the server still believes, so a toggle that
            // failed does not read as applied.
            config = previous
            report("save Live settings", error)
        }
    }

    /// Recompute the capture-source list. Called on appear, on a route change, and
    /// after the ambient claim is raised (which is when `availableInputs` is
    /// populated at all).
    func refreshSources() {
        sources = LiveCaptureSources.all()
        activeSource = LiveCaptureSources.resolve(id: settings.captureSourceID, among: sources)
    }

    /// Choose a capture source. Returns a message when the choice cannot actually
    /// take effect — never silently accepted.
    @discardableResult
    func select(source: LiveCaptureSource) -> String? {
        // The preference is written only AFTER both guards pass. Persisting first
        // meant a source that cannot stream could survive a relaunch as the stored
        // choice and be resolved back as the active microphone — with no notice,
        // because `select` was never called that time round.
        guard source.canStream else {
            // The phone keeps recording rather than going silent: a chosen source
            // that cannot work must not take capture down with it.
            _ = LiveCaptureSources.apply(.automatic)
            activeSource = .automatic
            settings.captureSourceID = LiveCaptureSource.automaticID
            return "\(source.label) can't stream audio to Jarvis yet — no wearable carries a "
                 + "microphone into this app. Recording stays on the phone."
        }
        guard LiveCaptureSources.apply(source) else {
            return "iOS refused to switch the microphone to \(source.label)."
        }
        settings.captureSourceID = source.id
        activeSource = source
        if capturing { sendSourceLabel() }
        return nil
    }

    func start() async {
        // `starting` is a SYNCHRONOUS latch. `capturing` is not true until three
        // awaits later, so `guard !capturing` alone let a double-tap run two starts
        // concurrently — and the loser's teardown stopped the winner's microphone.
        guard !capturing, !starting, halt == nil else { return }
        guard settings.captureHere else {
            error = "This device is set not to capture. Turn on \"Record on this phone\" in Live settings."
            return
        }
        starting = true
        defer { starting = false }

        generation += 1
        let epoch = generation
        error = ""

        guard await input.requestPermission() else {
            error = "Microphone access is off — turn it on in Settings."
            return
        }
        guard epoch == generation else { return }

        // The claim first: `availableInputs` is empty until the category permits
        // recording, so the source list and the preferred input can only be set
        // after this.
        do { try session.hold() } catch {
            report("claim audio for Live", error)
            return
        }
        refreshSources()
        if activeSource.canStream { _ = LiveCaptureSources.apply(activeSource) }

        await prepareTranscription()
        // Before `hello`, which declares whether this phone makes voiceprints.
        await loadVoiceprints()
        // NOT awaited: the first load compiles a 470 MB model for this phone and
        // takes seconds, and the microphone must not wait on it. Lines committed
        // before it is ready keep Apple's words.
        refreshOnDevice()
        // Every early return from here on releases the claim: leaving it held keeps
        // the system recording indicator lit over a screen saying "Not recording".
        guard epoch == generation else { try? session.release(); return }

        captureRate = Self.micRate
        // BEFORE the microphone: the first frame must already know what it is being
        // encoded as, and `hello` — sent a few lines later — has to declare the same
        // thing. Building the encoder after either would send audio under a codec
        // decided afterwards.
        prepareEncoder()
        do {
            try await input.start(sampleRate: Self.micRate)
        } catch {
            report("start the ambient microphone", error)
            try? session.release()
            return
        }
        guard epoch == generation else {
            await input.stop()
            try? session.release()
            return
        }
        capturing = true
        captureStartedAt = Date()
        // The indicator and the Live Activity come up with the microphone, not
        // after the socket: the phone is already listening to the room, and the
        // one thing that must never lag is the notice that says so.
        beacon.began(at: captureStartedAt ?? Date(), kept: storageText, detail: activityDetail)
        // Load the translation models for the languages this recording expects
        // now, while the room is quiet, rather than on the first foreign line.
        if config.translate {
            translator.target = config.primaryLanguage
            translator.warmUp(sources: sttLocales.map(\.identifier))
        }
        await openOrResumeSession(epoch: epoch)
        guard epoch == generation else { return }
        armMicWatchdog(epoch: epoch)
        await openSocket(epoch: epoch)
    }

    /// Claim a live session over REST before the socket opens.
    ///
    /// This is where `source_label` belongs: the contract puts it on
    /// `/api/live/session/start`, and the transcript needs to say which microphone
    /// a conversation was heard through. A session this device is already mid-way
    /// through is resumed instead, so a reconnect does not open a second recording
    /// of the same conversation.
    ///
    /// A failure here is NOT fatal: the socket's `hello` can create the session
    /// server-side, so a start endpoint that is missing or unreachable costs the
    /// source label, not the recording.
    private func openOrResumeSession(epoch: Int) async {
        if !settings.lastSessionID.isEmpty {
            liveSessionID = settings.lastSessionID
            chatSessionID = settings.lastChatSessionID
            // Continue the session's clocks. A fresh `AmbientSegmenter` starts at
            // zero, so without this a session resumed after a relaunch would emit
            // timestamps that collide with its own earlier rows and the transcript
            // would interleave the two halves of the conversation.
            segmenter.skip(ms: settings.lastElapsedMs)
            audioSeq = settings.lastAudioSeq
            spool.adopt(sessionID: liveSessionID)
            refreshSpoolCounters()
            return
        }
        // A NEW conversation: everything session-scoped restarts. The segmenter is
        // replaced rather than reset because its audio clock deliberately never
        // rewinds, so a second recording in one launch would otherwise be stamped
        // from the first one's total duration and its rows would overwrite the
        // first's by `seq`.
        segmenter = AmbientSegmenter()
        audioSeq = 0
        transcript.removeAll()
        do {
            let ids = try await api.startSession(deviceID: deviceID,
                                                 sourceLabel: sourceLabel,
                                                 title: Self.sessionTitle())
            guard epoch == generation else { return }
            if !ids.liveSessionID.isEmpty {
                liveSessionID = ids.liveSessionID
                chatSessionID = ids.chatSessionID
                settings.rememberCursor(sessionID: ids.liveSessionID, seq: 0)
                settings.lastChatSessionID = ids.chatSessionID
                // Bound the spool to the session as soon as the id exists, not one
                // round trip later when `ready` lands: an unbound spool that is
                // adopted late used to have everything captured in the meantime
                // discarded.
                spool.adopt(sessionID: ids.liveSessionID)
                refreshSpoolCounters()
            }
        } catch {
            JcLog.dropped(JcLog.voice, "start a live session over REST", error)
        }
    }

    /// The server generates the real title from the conversation; this is only what
    /// the Chats list shows until it does.
    private static func sessionTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return "Live — " + formatter.string(from: Date())
    }

    /// Stop capturing.
    ///
    /// **Unsent conversation is never discarded here.** The spool and the resume
    /// cursor are only cleared when the spool is already empty, i.e. when everything
    /// captured has actually gone up. A stop with a backlog — the user tapping Stop
    /// while the status line says "Reconnecting — 5.2 MB buffered", a halt, a switch
    /// back to Voice mode, or a Siri request arriving mid-recording — keeps both, so
    /// the next start resumes the same session and drains it.
    ///
    /// This is what makes `haltCapture`'s "Nothing already captured has been
    /// deleted" true rather than a comforting lie; it used to call `spool.reset()`
    /// two lines after promising exactly that.
    func stop() async {
        generation += 1
        let epoch = generation
        reconnectTimer?.cancel()
        reconnectTimer = nil
        micWatchdog?.cancel()
        micWatchdog = nil
        capturing = false
        interrupted = false
        level = 0
        captureStartedAt = nil
        // FIRST, and unconditionally. Everything below this line can throw, be
        // superseded by a new `start()`, or return early; an indicator or a
        // Live Activity still claiming to record after the microphone stopped
        // is the worst outcome this feature has, so it is retired before
        // anything that could fail.
        beacon.ended()
        clearPartial()
        spokenReply?.stop()

        // A part-spoken utterance still counts — dropping it would lose the last
        // thing anybody said before the user tapped stop.
        //
        // AWAITED, unlike the interruption path's fire-and-forget version: the
        // teardown below closes the socket, so a transcription still in flight would
        // resolve with nowhere to send its text and the final utterance would vanish.
        await flushFinalUtterance()
        // Each await is an opportunity for a new `start()` to have begun; the rest of
        // this teardown would then dismantle THAT recording's mic, claim and cursor.
        guard epoch == generation else { return }
        preRoll.removeAll()
        pendingSpeechFrames.removeAll()
        // Released only after `flushFinalUtterance` has had its tail: a converter
        // dropped with audio inside it is that audio lost. The next `start` builds a
        // fresh one, which is also what re-answers "will this OS encode Opus".
        encoder = nil

        await input.stop()
        guard epoch == generation else { return }
        try? session.release()

        let id = liveSessionID
        closeSocket()
        connected = false
        guard !id.isEmpty else {
            refreshSpoolCounters()
            return
        }
        do { try await api.endSession(liveSessionID: id) }
        catch { report("end the Live session", error) }
        guard epoch == generation else { return }
        // The CURSOR SURVIVES A STOP. Tapping Stop and Record again is one
        // conversation with a pause in it, not two, so the next `start()` asks
        // to continue this same session — which is also what makes a burst of
        // short recordings add up into one summarisable window instead of a
        // pile of one-minute chats. Whether it may continue is the server's
        // decision: it rolls the session over once the transcript reaches its
        // share of the model's context, and says which session it bound in
        // `ready` (see `apply(_ ready:)`). There is deliberately no size or
        // time rule on this side — one decision-maker only.
        if spool.isEmpty {
            spool.reset()
        } else {
            spoolWarning = "\(LiveFormat.bytes(spool.byteCount)) of this conversation hasn't "
                         + "reached Jarvis yet. It is kept on the phone and will upload when you "
                         + "record again."
        }
        refreshSpoolCounters()
    }

    /// Clear a hard stop so the user can try again — after freeing space, or
    /// getting back on a network.
    func clearHalt() {
        halt = nil
        error = ""
    }

    /// Throw away the backlog, explicitly. The only path that deletes unsent
    /// conversation, and it exists so the user can choose it rather than have it
    /// happen to them.
    func discardBacklog() {
        spool.reset()
        settings.forgetCursor()
        spoolWarning = ""
        refreshSpoolCounters()
    }

    // MARK: - Mic watchdog

    /// Notice when the microphone stops delivering audio.
    ///
    /// `AmbientAudioInput.isRunning` goes false after three seconds without a buffer,
    /// which is the only reliable signal that a route change, a media-services reset
    /// or a failed engine restart has killed capture. Nothing was reading it, so an
    /// AirPods disconnect could leave the screen reading "Recording" over a dead mic
    /// indefinitely — the exact outcome §8 forbids.
    ///
    /// One restart attempt, then a loud halt. Retrying forever would be the silent
    /// failure again, just slower.
    private func armMicWatchdog(epoch: Int) {
        micWatchdog?.cancel()
        micWatchdog = clock.schedule(after: Self.micWatchdogMs) { [weak self] in
            guard let self else { return }
            self.micWatchdog = nil
            guard epoch == self.generation, self.capturing else { return }
            // A paused capture is SUPPOSED to be delivering nothing.
            guard !self.interrupted else {
                self.armMicWatchdog(epoch: epoch)
                return
            }
            guard !self.input.isRunning else {
                self.armMicWatchdog(epoch: epoch)
                return
            }
            Task { [weak self] in await self?.recoverMic(epoch: epoch) }
        }
    }

    private func recoverMic(epoch: Int) async {
        guard epoch == generation, capturing, !interrupted else { return }
        JcLog.voice.notice("live: the microphone stopped delivering; rebuilding")
        level = 0
        do {
            try session.reassert()
            await input.stop()
            try await input.start(sampleRate: captureRate)
            guard epoch == generation else { return }
            armMicWatchdog(epoch: epoch)
        } catch {
            // Visible, not a log line: capture has stopped and the user must know.
            halt = LiveHalt(
                title: "Recording stopped",
                detail: "The microphone stopped delivering audio and could not be restarted. "
                      + "Nothing already captured has been deleted.")
            await stop()
        }
    }

    // MARK: - Transcription readiness

    /// Decide the lane this device can honestly claim.
    ///
    /// §8: if the SpeechAnalyzer model is not downloaded we declare `stt: "none"`
    /// and SAY SO, rather than claiming the edge lane and then never sending a
    /// `seg` — which the server would read as a silent room.
    private func prepareTranscription() async {
        // `prepare` may DOWNLOAD the language model, which can take a while. Without
        // saying so the user presses Record and the screen reads "Not recording" for
        // the length of a download they were never told about.
        preparing = true
        prepareProgress = 0
        // Every language the user said might be spoken needs its model installed,
        // not just the device's own — a locale with no model on the phone is a
        // recogniser that silently never produces a word.
        let readiness = await recognizer.prepare(locales: sttLocales) { [weak self] fraction in
            self?.prepareProgress = fraction
        }
        preparing = false
        switch readiness {
        case .ready:
            sttNotice = ""
            sttEnabled = true
        default:
            sttNotice = readiness.message.isEmpty
                ? "Transcribing on the server."
                : readiness.message + " Transcribing on the server instead."
            sttEnabled = false
        }
    }

    private var declaredSTT: String { sttEnabled ? "on_device" : "none" }

    // MARK: - Socket

    private func openSocket(epoch: Int) async {
        guard epoch == generation else { return }
        do {
            let url = try api.socketURL()
            let s = try await connector.connect(url: url, headers: api.headers)
            guard epoch == generation else { s.close(); return }
            s.onFrame = { [weak self] frame in
                guard let self else { return }
                switch frame {
                case .text(let text): self.receive(text: text)
                // The server has no reason to send us binary, but a frame we did
                // not expect must not look like a dead socket.
                case .binary(let data):
                    JcLog.voice.notice("live: ignored \(data.count, privacy: .public)B binary frame")
                }
            }
            s.onClose = { [weak self] error in self?.socketClosed(error) }
            socket = s
            connected = true
            reconnectAttempt = 0
            sendHello()
        } catch {
            connected = false
            report("connect to Live Jarvis", error)
            scheduleReconnect()
        }
    }

    private func sendHello() {
        // `audioCodec`/`audioRate`, never a literal: this frame is the server's only
        // instruction for how to store what follows it, so it must be read from the
        // same two properties `sendAudio` encodes with.
        let caps = LiveCaps(stt: declaredSTT,
                            embed: voiceprints == nil ? "none" : "on_device",
                            embedModel: voiceprints == nil ? "" : LiveVoiceprint.modelID,
                            codec: audioCodec, rate: audioRate)
        // Resume only when this device has a cursor in a session that is still the
        // one it is recording — otherwise the server would be asked to continue a
        // conversation that ended.
        var resume: LiveResume?
        let remembered = liveSessionID.isEmpty ? settings.lastSessionID : liveSessionID
        if !remembered.isEmpty {
            resume = LiveResume(liveSessionID: remembered, afterSeq: settings.lastSeq)
        }
        // Remembered so `ready` can be compared against it. The client ALWAYS
        // asks to continue the last session — it has no way to know the budget
        // — and the server answers with the id it actually bound.
        resumeRequestedID = remembered
        send(.hello(deviceID: deviceID, caps: caps, resume: resume))
    }

    private func closeSocket() {
        let s = socket
        socket = nil
        s?.onFrame = nil
        s?.onClose = nil
        s?.close()
    }

    private func socketClosed(_ error: Error?) {
        socket = nil
        connected = false
        // Everything written but not confirmed goes BACK into the spool.
        //
        // `URLSessionWebSocketTask.send` reports a failure through its completion
        // handler, not through `receive()`, so a dead TCP connection can take seconds
        // to surface as `onClose` — and every frame written in that window had simply
        // vanished, while the status line read "Recording" throughout. There is no ack
        // in the protocol and `after_seq` is a DOWNLOAD cursor (it replays server rows
        // to us; it cannot make the server re-request audio it never got), so re-queuing
        // locally is the only thing that closes this hole. Re-sent frames are
        // idempotent for the server to drop by (session, seq).
        requeueInFlight()
        guard capturing else { return }
        // Not reported as an error: §8 calls this the normal path. Capture keeps
        // running into the spool and the status line shows the backlog.
        JcLog.voice.notice("live socket closed; spooling")
        scheduleReconnect()
    }

    private func requeueInFlight() {
        let pending = inFlight
        inFlight.removeAll()
        guard !pending.isEmpty else { return }
        do {
            try spool.prepend(pending)
            refreshSpoolCounters()
            JcLog.voice.notice("live: re-queued \(pending.count, privacy: .public) unconfirmed frames")
        } catch let failure as LiveSpoolError {
            haltCapture(failure)
        } catch {
            haltCapture(.unwritable(error.localizedDescription))
        }
    }

    private func scheduleReconnect() {
        guard capturing, halt == nil, reconnectTimer == nil else { return }
        let delay = Self.reconnectDelaysMs[min(reconnectAttempt, Self.reconnectDelaysMs.count - 1)]
        reconnectAttempt += 1
        let epoch = generation
        reconnectTimer = clock.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.reconnectTimer = nil
            guard epoch == self.generation, self.capturing else { return }
            Task { await self.openSocket(epoch: epoch) }
        }
    }

    // MARK: - Sending

    private func send(_ message: LiveClientMessage) {
        enqueue(.text(message.encoded()))
    }

    private func sendSourceLabel() {
        send(.source(label: sourceLabel))
    }

    /// One path for everything outbound: straight down the socket when there is
    /// one, into the spool when there is not. A caller never has to know.
    private func enqueue(_ frame: LiveOutbound) {
        if let socket, connected {
            // Anything already spooled goes FIRST — sending the newest frame ahead
            // of a backlog would put the transcript out of order.
            if !spool.isEmpty { drainSpool(into: socket) }
            if spool.isEmpty {
                write(frame, to: socket)
                return
            }
        }
        do {
            try spool.append(frame)
            refreshSpoolCounters()
            if spool.fill >= Self.spoolWarnFill, spoolWarning.isEmpty {
                spoolWarning = "Jarvis is unreachable — \(LiveFormat.bytes(spool.byteCount)) "
                             + "of this conversation is waiting on the phone."
            }
        } catch let failure as LiveSpoolError {
            haltCapture(failure)
        } catch {
            haltCapture(.unwritable(error.localizedDescription))
        }
    }

    /// Write a frame and remember it until the socket has outlived it. See
    /// `socketClosed` for why "written" is not "delivered".
    private func write(_ frame: LiveOutbound, to socket: VoiceSocket) {
        switch frame {
        case .text(let text): socket.send(text: text)
        case .binary(let data): socket.send(data: data)
        }
        inFlight.append(frame)
        // A window, not a log: past this the oldest frames are taken as delivered,
        // which bounds the memory an otherwise-healthy socket costs.
        if inFlight.count > Self.inFlightWindow {
            inFlight.removeFirst(inFlight.count - Self.inFlightWindow)
        }
    }

    /// Upload the backlog, in bounded batches.
    ///
    /// Bounded because this runs from the audio callback: recovering a 30 MB spool in
    /// one pass would base64 and write the whole thing on the main actor, freezing the
    /// UI precisely while the feature is supposed to be recovering. Whatever is left
    /// goes on the next frame, and frames captured meanwhile queue behind it, so order
    /// is preserved either way.
    ///
    /// Drained frames enter `inFlight` rather than being considered delivered — see
    /// `socketClosed`.
    private func drainSpool(into socket: VoiceSocket) {
        let sent = spool.drain(limit: Self.drainBatch) { frame in
            self.write(frame, to: socket)
            return true
        }
        if sent > 0 {
            JcLog.voice.notice("live: drained \(sent, privacy: .public) spooled frames")
            refreshSpoolCounters()
            // Only OUR backlog warning clears here. The server's capacity warning is
            // the server's to withdraw; clearing it from the spool path used to erase
            // a message that had nothing to do with the spool.
            if spool.isEmpty { spoolWarning = "" }
        }
    }

    private func refreshSpoolCounters() {
        spooledFrames = spool.count
        spoolFill = spool.fill
    }

    /// The loud stop of §8. Capture ends, the reason stays on screen, and nothing
    /// is quietly discarded.
    private func haltCapture(_ failure: LiveSpoolError) {
        guard halt == nil else { return }
        JcLog.voice.error("live capture halted: \(failure.errorDescription ?? "", privacy: .public)")
        halt = LiveHalt(title: "Recording stopped",
                        detail: (failure.errorDescription ?? "Live Jarvis ran out of room.")
                              + " Nothing already captured has been deleted.")
        Task { await stop() }
    }

    // MARK: - Audio

    private func handle(frame pcm: Data) {
        guard capturing, !interrupted else { return }
        let dtMs = Endpointer.frameMsForPcm16(byteLength: pcm.count, sampleRate: Self.micRate)
        let amp = voicePeakAmplitude(pcm)
        level = min(amp * 24, 1)

        // While a recogniser is listening, IT chunks the utterance (see
        // `wordsAreOver`); the level gate's cap would only cut room noise at an
        // arbitrary instant. With no session the cap stays, because it is also
        // how a session that never opened reaches `finishUtterance` and hands
        // transcription back to the server.
        let event = segmenter.update(amp, dtMs, capArmed: !(sttEnabled && speech != nil))
        switch event {
        case .started:
            openSpeechSession()
            // The frames just before the gate opened carry the utterance's first
            // sound; they go up now, in order, ahead of this one — and they are
            // also the transcriber's first audio, which is why they are queued for
            // it rather than only uploaded.
            //
            // Each keeps its OWN timestamp, backdated by its distance from now. The
            // whole purpose of the frame header is to preserve timing (§2.2), and
            // stamping 400 ms of audio with one instant would have the server place
            // the opening of every utterance late.
            let preRollMs = preRoll.count * max(dtMs, 1)
            // Where on the session's audio clock the FIRST sample handed to the
            // recogniser sits. The recogniser's own result ranges are relative to
            // that sample, so this is what turns them back into session time.
            speechAnchorMs = max(segmenter.elapsedMs - dtMs - preRollMs, 0)
            for (index, buffered) in preRoll.enumerated() {
                let backdated = segmenter.elapsedMs - preRollMs + index * max(dtMs, 1)
                sendAudio(buffered, tsMs: max(backdated, 0))
            }
            pendingSpeechFrames = preRoll
            // The recogniser's first sample is the pre-roll's, so the voiceprint
            // buffer starts there too.
            utterancePCM = Data()
            utteranceDroppedMs = 0
            for frame in preRoll { keepForLater(frame) }
            preRoll.removeAll()
        case .ended(let startMs, let endMs):
            sendAudio(pcm)
            closeUtterance(startMs: startMs, endMs: endMs)
            return
        case .none:
            break
        }

        if segmenter.speaking {
            if let speech {
                speech.feed(pcm)
            } else if pendingSpeechFrames.count < Self.maxPendingSpeechFrames {
                // The session is still opening; hold this so its first word is not
                // lost to the gap.
                pendingSpeechFrames.append(pcm)
            }
            keepForLater(pcm)
            sendAudio(pcm)
            if wordsAreOver(), case .ended(let startMs, let endMs)? = segmenter.endUtterance() {
                closeUtterance(startMs: startMs, endMs: endMs)
            }
        } else {
            // Silence is NOT uploaded, and still isn't now that the audio is Opus.
            // Compression brought the archive to the design's ~11 MB an hour of
            // SPEECH; uploading the silence too would put the continuous ambient
            // recording back at roughly that rate all day, for hours of a quiet
            // room. So the gate stays: every millisecond of speech goes up, plus the
            // pre-roll, and only true silence is dropped. The server therefore has
            // the audio for every transcript row but not a continuous recording — a
            // real difference from the design, noted here so it is not mistaken for
            // a bug.
            preRoll.append(pcm)
            if preRoll.count > Self.preRollFrames { preRoll.removeFirst() }
        }
    }

    /// Build the Opus encoder for this capture, or state why there isn't one.
    ///
    /// Design §11's archive rate assumed 24 kbps Opus: ~11 MB an hour against
    /// PCM16's ~115, which over a feature the user has chosen to keep INDEFINITELY
    /// is 31 GB a year against 300. CoreAudio encoding Opus was proved on this
    /// device before any of this was wired (`AmbientOpusEncoderTests`), but "proved
    /// on one phone" is not "true on every OS this app runs on", so a refusal here
    /// is a first-class outcome: PCM16 stays, and it is DECLARED as PCM16.
    private func prepareEncoder() {
        if let made = AmbientOpusEncoder.make(sourceRate: Double(captureRate)) {
            encoder = made
            audioCodec = AmbientOpusEncoder.wireCodec
            audioRate = AmbientOpusEncoder.wireRate
            codecNotice = ""
            JcLog.voice.notice("live: ambient audio as \(made.codecLabel, privacy: .public)")
        } else {
            encoder = nil
            audioCodec = "pcm16"
            audioRate = captureRate
            codecNotice = "This phone won't encode Opus, so Live recordings are "
                        + "uncompressed and take about ten times the space."
            JcLog.voice.error("""
                live: no Opus encoder (\(AmbientOpusEncoder.lastError, privacy: .public)); \
                sending PCM16 and saying so
                """)
        }
        // Anything still queued in the OTHER encoding cannot go up a socket that
        // declares this one. The spool sets it aside rather than mislabelling it.
        spool.adopt(codec: audioCodec)
        refreshSpoolCounters()
    }

    /// Encode a captured chunk and put it on the wire.
    ///
    /// `tsMs` overrides the audio clock for the pre-roll, whose frames are older
    /// than now and whose stamps are what keep the opening of an utterance in the
    /// right place.
    private func sendAudio(_ pcm: Data, tsMs: Int? = nil) {
        let stamp = max(tsMs ?? segmenter.elapsedMs, 0)
        guard let encoder else {
            emitAudio(pcm, tsMs: stamp)
            return
        }
        guard let packets = encoder.encodePackets(pcm) else {
            // The encoder failed after having worked. Sending these samples now
            // would put PCM in a chunk the server has labelled Opus, so the label
            // is changed FIRST and the bytes follow it.
            fallBackToPCM(because: AmbientOpusEncoder.lastError)
            emitAudio(pcm, tsMs: stamp)
            return
        }
        emit(packets: packets, from: stamp)
    }

    /// One frame per packet.
    ///
    /// The server writes its own 4-byte big-endian length in front of every payload
    /// it is handed, so a frame carrying several packets would be stored as one
    /// mis-sized packet and the file's `opus-packets-len32@48000` framing would be a
    /// lie. Each packet is 20 ms of audio, so the stamps step by that rather than
    /// every packet in a chunk claiming the same instant.
    private func emit(packets: [Data], from tsMs: Int) {
        for (index, packet) in packets.enumerated() {
            emitAudio(packet, tsMs: tsMs + index * AmbientOpusEncoder.packetMs)
        }
    }

    private func emitAudio(_ payload: Data, tsMs: Int) {
        guard !payload.isEmpty else { return }
        audioSeq += 1
        enqueue(.binary(LiveAudioFrame.encode(seq: audioSeq, tsMs: tsMs, payload: payload)))
    }

    /// Give up the packet the encoder is holding.
    ///
    /// The encoder is packet-aligned, so at any moment up to 20 ms of real audio is
    /// inside it — and at an utterance boundary that is the end of the last word.
    /// Flushing also stops one utterance's tail being spliced onto the front of the
    /// next one, which is what happens when the silence between them is dropped.
    private func flushEncoderTail(tsMs: Int? = nil) {
        guard let encoder else { return }
        emit(packets: encoder.flushPackets(), from: max(tsMs ?? segmenter.elapsedMs, 0))
    }

    /// Stop claiming Opus, mid-capture, because the encoder stopped working.
    ///
    /// Modelled on `fallBackToServerTranscription`: the danger is not the
    /// degradation, it is degrading while still declaring the old capability. A
    /// re-`hello` is how this protocol re-declares caps, and the server keys its
    /// audio writer by codec — so it opens a new chunk for the new encoding instead
    /// of appending samples to an Opus file.
    private func fallBackToPCM(because reason: String) {
        guard encoder != nil else { return }
        encoder = nil
        audioCodec = "pcm16"
        audioRate = captureRate
        codecNotice = "Opus encoding stopped working, so the rest of this recording "
                    + "is uncompressed."
        JcLog.voice.error("live: opus encoder failed (\(reason, privacy: .public)); PCM16 from here")
        spool.adopt(codec: audioCodec)
        refreshSpoolCounters()
        sendHello()
    }

    /// The language Apple's recogniser listens in: the conversation's primary
    /// one, or the device's when that is unknown (an empty list).
    ///
    /// There used to be a user-picked list of up to three, each its own
    /// recogniser over the same audio — three times the battery, and still only
    /// the languages someone predicted. The downloaded models (`LiveModels`)
    /// re-hear every line instead, in 25 European languages plus Chinese,
    /// Japanese and Korean, without anyone choosing.
    var sttLocales: [Locale] {
        let primary = config.primaryLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary.isEmpty ? [] : [Locale(identifier: primary)]
    }

    /// Open a transcription session for the utterance that just began.
    private func openSpeechSession() {
        guard declaredSTT == "on_device", speech == nil else { return }
        let epoch = generation
        let locales = sttLocales
        Task { [weak self] in
            guard let self else { return }
            // `prompt: false` — a user who never opted into on-device speech is not
            // shown a permission sheet by an ambient recorder.
            let made = await self.recognizer.startSession(sampleRate: Self.micRate,
                                                          prompt: false, locales: locales)
            guard epoch == self.generation, self.capturing else { made?.cancel(); return }
            guard let made else {
                // The recognizer refused. On the EDGE lane that is not benign: the
                // server is not transcribing, so a silent nil here means the utterance
                // never reaches the transcript at all. Hand the lane back instead.
                self.fallBackToServerTranscription(
                    because: "On-device transcription stopped working.")
                return
            }
            // A session that finished arriving after the utterance ended is useless.
            guard self.segmenter.speaking, self.speech == nil else { made.cancel(); return }
            self.speech = made
            self.forgetWords()
            // The words as they are said. Apple's transcriber emits volatile
            // results for the stretch it is still hearing and re-states them as
            // they firm up, so this is the live text with no server round trip
            // in it — the same source the regular voice screen displays from.
            self.partialStartMs = max(self.segmenter.startMs, 0)
            made.onPartial = { [weak self, weak made] text in
                guard let self, let made, self.speech === made else { return }
                self.noteWords(text)
                self.showPartial(text)
            }
            // Everything said while it was opening, in order.
            for frame in self.pendingSpeechFrames { made.feed(frame) }
            self.pendingSpeechFrames.removeAll()
        }
    }

    // MARK: - The utterance in progress

    /// Put the recogniser's current guess on screen.
    private func showPartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard capturing, !interrupted else { return }
        guard !trimmed.isEmpty else { return }
        partialText = trimmed
        // Still being spoken, so the grace window has not started. Re-armed
        // when the utterance ends.
        partialExpiry?.cancel()
        partialExpiry = nil
    }

    /// Take every provisional row off screen — the words being spoken and the
    /// words waiting on their row. For the paths that end capture outright.
    private func clearPartial() {
        partialText = ""
        partialStartMs = 0
        clearCommitting()
    }

    /// Take away only the words that were waiting on a committed row.
    private func clearCommitting() {
        partialExpiry?.cancel()
        partialExpiry = nil
        committingText = ""
        committingStartMs = 0
    }

    /// The utterance's audio has ended and its committed row is on its way.
    /// Its words move to their own slot so the next line can start filling
    /// `partialText` at once, and stay visible across the transcription deadline
    /// and the round trip — but not forever: a recogniser that produced text and
    /// then failed, or an utterance the server discards, must not leave a guess
    /// on screen wearing the transcript's clothes.
    /// Returns whether there were words to hand off.
    @discardableResult
    private func handOffPartial() -> Bool {
        guard !partialText.isEmpty else { return false }
        committingText = partialText
        committingStartMs = partialStartMs
        partialText = ""
        partialStartMs = 0
        partialExpiry?.cancel()
        partialExpiry = clock.schedule(after: Self.partialGraceMs) { [weak self] in
            guard let self else { return }
            self.partialExpiry = nil
            self.committingText = ""
            self.committingStartMs = 0
        }
        return true
    }

    // MARK: - When a line is over

    /// Record the recogniser's latest words for the open utterance.
    private func noteWords(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words != lastWords else { return }
        lastWords = words
        wordsChangedAtMs = segmenter.elapsedMs
        if firstWordsAtMs == nil { firstWordsAtMs = segmenter.elapsedMs }
    }

    private func forgetWords() {
        lastWords = ""
        wordsChangedAtMs = nil
        firstWordsAtMs = nil
    }

    /// Whether the open utterance is over by the recogniser's account: its
    /// words have not changed for `wordsSettledMs`, or they have run for the
    /// whole chunking cap. Measured from the first WORD, not from when the level
    /// gate opened — in a loud room the gate can have been open on noise for a
    /// long time before anyone spoke.
    private func wordsAreOver() -> Bool {
        guard sttEnabled, speech != nil,
              let changed = wordsChangedAtMs, let first = firstWordsAtMs
        else { return false }
        let now = segmenter.elapsedMs
        return now - changed >= Self.wordsSettledMs
            || now - first >= AmbientSegmenter.maxUtteranceMs
    }

    // MARK: - Voiceprints

    /// Twenty seconds of 16 kHz mono int16 — the most the server embeds, and
    /// more than a line can hold once the words have run for the cap.
    static let maxHeardBytes = LiveStore.micRate * 2 * LiveVoiceprint.maxSpeechMs / 1000

    /// Keep a frame of the open utterance for its voiceprint and second hearing,
    /// dropping the oldest few seconds at once when it is full.
    private func keepForLater(_ pcm: Data) {
        guard voiceprints != nil || onDeviceLoader != nil else { return }
        utterancePCM.append(pcm)
        guard utterancePCM.count > Self.maxHeardBytes else { return }
        let bytesPerMs = Self.micRate * 2 / 1000
        let drop = (utterancePCM.count - Self.maxHeardBytes + 5000 * bytesPerMs) / 2 * 2
        // A fresh buffer, not `removeFirst`: a trimmed `Data` keeps its old
        // indices, and every slice below counts from zero.
        utterancePCM = utterancePCM.subdata(in: drop..<utterancePCM.count)
        utteranceDroppedMs += drop / bytesPerMs
    }

    /// Ask again for the on-device transcriber, in the background. The loader
    /// answers at once when nothing changed, and nil when the user chose the
    /// server — so this is also how picking Server stops the phone re-hearing.
    private func refreshOnDevice() {
        guard let loader = onDeviceLoader, !onDeviceLoading else { return }
        onDeviceLoading = true
        Task { [weak self] in
            let made = await loader()
            self?.onDevice = made
            self?.onDeviceLoading = false
        }
    }

    /// Padding either side of the recogniser's word range for the second
    /// hearing — the recogniser's range can shave an onset a model needs.
    static let secondHearingPadMs = 500

    /// The words a committed line carries, and their language.
    private func bestLine(apple: String, appleLang: String, heard: Data, heardStartMs: Int,
                          bounds: (start: Int, end: Int)) async -> (text: String, lang: String) {
        // For the NEXT line: a download that just finished, or a different
        // choice in Settings, takes effect without stopping the recording.
        refreshOnDevice()
        guard let onDevice, !heard.isEmpty else { return (apple, appleLang) }
        let bytesPerMs = Self.micRate * 2 / 1000
        let from = min(max(0, (bounds.start - Self.secondHearingPadMs - heardStartMs) * bytesPerMs),
                       heard.count)
        let to = min(max(from, (bounds.end + Self.secondHearingPadMs - heardStartMs) * bytesPerMs),
                     heard.count)
        guard to > from else { return (apple, appleLang) }
        let clip = heard.subdata(in: from..<to)
        let second = await onDevice.transcribe(pcm16: clip)
        return Self.chooseLine(apple: apple, appleLang: appleLang, heard: second)
    }

    /// Apple's words, unless the phone's own second hearing is sure the line was
    /// in ANOTHER language. Apple's recogniser takes one locale, so a line in
    /// another language comes out as phonetic English ("Hola, Como Stas") — and
    /// labelled English, so it is never translated. Same language: Apple's words
    /// stay, being the ones the user just watched appear.
    static func chooseLine(apple: String, appleLang: String,
                           heard: OnDeviceHeard?) -> (text: String, lang: String) {
        guard let heard, !heard.text.isEmpty, heard.confidence >= 0.9, !heard.language.isEmpty,
              LiveTranslator.primarySubtag(heard.language) != LiveTranslator.primarySubtag(appleLang)
        else { return (apple, appleLang) }
        return (heard.text, heard.language)
    }

    /// Load the embedder once. A failure leaves `voiceprints` nil, and the
    /// server identifies from the audio exactly as before.
    private func loadVoiceprints() async {
        guard !voiceprintsTried, let loader = voiceprintLoader else { return }
        voiceprintsTried = true
        voiceprints = await Task.detached(priority: .utility) { loader() }.value
        if voiceprints == nil { JcLog.voice.notice("live: voiceprint model unavailable; the server identifies") }
    }

    /// The voiceprint of `startMs...endMs` — the same word-bounded range the
    /// server would read back — cut from the samples the recogniser heard.
    /// Nil when there is no embedder or too little speech to carry a voice.
    private func voiceprint(of pcm: Data, anchorMs: Int, startMs: Int, endMs: Int) async -> [Float]? {
        guard let embedder = voiceprints, !pcm.isEmpty else { return nil }
        let bytesPerMs = Self.micRate * 2 / 1000
        let from = min(max(0, (startMs - anchorMs) * bytesPerMs), pcm.count)
        let to = min(max(from, (endMs - anchorMs) * bytesPerMs), pcm.count)
        guard to - from >= LiveVoiceprint.minSpeechMs * bytesPerMs else { return nil }
        let slice = pcm.subdata(in: from..<to)
        return await Task.detached(priority: .userInitiated) { embedder.embed(pcm16: slice) }.value
    }

    /// An utterance boundary, however it was reached: the level gate's silence
    /// or cap, or the recogniser's words settling.
    private func closeUtterance(startMs: Int, endMs: Int) {
        // The last 20 ms of the last word is inside the encoder; the utterance
        // is over, so nothing more is coming to push it out.
        flushEncoderTail()
        finishUtterance(startMs: startMs, endMs: endMs)
        // An utterance boundary is the cheap place to record the clocks: once
        // per utterance rather than once per 20 ms frame.
        settings.rememberAudioClock(sessionID: liveSessionID,
                                    elapsedMs: segmenter.elapsedMs,
                                    audioSeq: audioSeq)
    }

    /// Give the transcription job back to the server, and say so.
    ///
    /// The dangerous state is claiming the edge lane while producing no `seg` frames:
    /// the server is not transcribing either, so the conversation reads as a silent
    /// room. Re-declaring `stt: "none"` over the live socket makes the server take
    /// over from the audio it is already receiving.
    private func fallBackToServerTranscription(because reason: String) {
        guard sttEnabled else { return }
        sttEnabled = false
        sttNotice = reason + " Jarvis is transcribing on the server instead."
        JcLog.voice.notice("live: handing transcription back to the server")
        speech?.cancel()
        speech = nil
        pendingSpeechFrames.removeAll()
        utterancePCM = Data()
        // The recogniser this text came from is gone, so nothing will ever
        // commit it. Dropped at once rather than left to age out.
        clearPartial()
        // Re-introduce ourselves with the reduced capability; the lane rule is the
        // server's to apply and it can only apply it to what we declare.
        sendHello()
    }

    /// An utterance ended: detach its transcription session, await the final text
    /// under a deadline, and send the `seg`.
    ///
    /// The session is detached SYNCHRONOUSLY and replaced by nil so the next
    /// utterance can open its own immediately — awaiting the finalize inline would
    /// drop the opening of whatever is said next.
    /// Narrow an amplitude-gate window down to the stretch the recogniser
    /// actually found words in.
    ///
    /// `startMs`/`endMs` are what the gate held open; `observedMs` is the
    /// recogniser's own range, in ms from the first sample it was fed, and
    /// `anchorMs` is where that sample sits on the session's audio clock.
    ///
    /// Every failure mode falls back to the gate's own window. A wrong span is
    /// worse than a loose one, because the server slices the identification audio
    /// out of exactly these numbers — so a range that is missing, degenerate, or
    /// lands outside the window (which would mean the analyzer's clock is not
    /// ours) is discarded rather than trusted.
    static func narrowedBounds(startMs: Int, endMs: Int, anchorMs: Int,
                               observedMs: ClosedRange<Int>?) -> (start: Int, end: Int) {
        guard endMs > startMs, let observed = observedMs else { return (startMs, endMs) }
        // A little air either side: the recogniser's range covers the words, and
        // the breath before the first one belongs to the speaker too.
        let low = anchorMs + observed.lowerBound - Self.boundsPadMs
        let high = anchorMs + observed.upperBound + Self.boundsPadMs
        let clampedLow = max(low, startMs)
        let clampedHigh = min(high, endMs)
        guard clampedHigh > clampedLow else { return (startMs, endMs) }
        return (clampedLow, clampedHigh)
    }

    /// Padding either side of the recogniser's word range, in ms.
    static let boundsPadMs = 150

    private func finishUtterance(startMs: Int, endMs: Int) {
        let finished = speech
        let anchorMs = speechAnchorMs
        let heard = utterancePCM
        let heardStartMs = anchorMs + utteranceDroppedMs
        utterancePCM = Data()
        utteranceDroppedMs = 0
        speech = nil
        forgetWords()
        // The audio has ended; the row is in flight. The words stay put until
        // it lands (`upsert`) or the grace window closes.
        let handedOff = handOffPartial() ? committingText : nil
        // Anything still queued belonged to the utterance that just ended; it must
        // not be fed to the NEXT one's session.
        pendingSpeechFrames.removeAll()
        // The two reasons for having no session are NOT the same, and conflating them
        // is how an utterance disappears. On the server lane there is nothing to do —
        // the audio has gone up and the server transcribes it. On the edge lane a
        // missing session means nobody is transcribing this utterance, so the lane has
        // to be handed back.
        guard sttEnabled else { return }
        guard let finished else {
            fallBackToServerTranscription(because: "On-device transcription didn't start in time.")
            return
        }
        let epoch = generation
        let language = config.primaryLanguage
        Task { [weak self] in
            guard let self else { return }
            let text = await self.transcribe(finished, deadlineMs: Self.transcriptionDeadlineMs)
            guard epoch == self.generation else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing heard: a VAD opening on a door slam is normal and must not
            // become an empty transcript row — nor leave its guess on screen for
            // a row that is not coming. Only if those words are still the ones
            // waiting: a later line may have taken the slot since.
            guard !trimmed.isEmpty else {
                if let handedOff, self.committingText == handedOff { self.clearCommitting() }
                return
            }
            // Read AFTER the await: it is the FINAL results that carry the range
            // and the winning language, and those only exist once `stop()` has
            // finalized.
            let bounds = Self.narrowedBounds(startMs: startMs, endMs: endMs, anchorMs: anchorMs,
                                             observedMs: finished.transcribedRangeMs)
            let voice = await self.voiceprint(of: heard, anchorMs: heardStartMs,
                                              startMs: bounds.start, endMs: bounds.end)
            let line = await self.bestLine(apple: trimmed,
                                           appleLang: finished.resolvedLanguage ?? language,
                                           heard: heard, heardStartMs: heardStartMs, bounds: bounds)
            guard epoch == self.generation else { return }
            self.send(.segment(startMs: bounds.start, endMs: bounds.end, text: line.text,
                               // The locale that actually produced this text, not
                               // the one we hoped for. The server's auto-translate
                               // keys on this field, so labelling Spanish `en`
                               // guarantees it is never translated.
                               lang: line.lang,
                               // "me" is provisional and local: this device's owner
                               // is the likeliest speaker into their own phone, and
                               // the server's identification is the authority that
                               // overrides it (design §5.2).
                               localLabel: "me",
                               voiceprint: voice,
                               translatesHere: self.translatesHere))
        }
    }

    /// The last utterance of a session, sent before anything is torn down.
    ///
    /// Separate from `finishUtterance` because it must complete INLINE: that one
    /// detaches a Task so the next utterance can start immediately, which is right
    /// mid-conversation and wrong at the end, where the socket is about to close.
    private func flushFinalUtterance() async {
        let finished = speech
        let anchorMs = speechAnchorMs
        let heard = utterancePCM
        let heardStartMs = anchorMs + utteranceDroppedMs
        utterancePCM = Data()
        utteranceDroppedMs = 0
        speech = nil
        pendingSpeechFrames.removeAll()
        // Before the guards, and before `stop` closes the socket: the encoder's
        // held packet is real audio whether or not this utterance produced any text.
        flushEncoderTail()
        guard let event = segmenter.flush(), case .ended(let startMs, let endMs) = event else {
            finished?.cancel()
            return
        }
        guard sttEnabled, let finished else {
            finished?.cancel()
            return
        }
        let text = await transcribe(finished, deadlineMs: Self.transcriptionDeadlineMs)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bounds = Self.narrowedBounds(startMs: startMs, endMs: endMs, anchorMs: anchorMs,
                                         observedMs: finished.transcribedRangeMs)
        let voice = await voiceprint(of: heard, anchorMs: heardStartMs,
                                     startMs: bounds.start, endMs: bounds.end)
        let line = await bestLine(apple: trimmed,
                                  appleLang: finished.resolvedLanguage ?? config.primaryLanguage,
                                  heard: heard, heardStartMs: heardStartMs, bounds: bounds)
        send(.segment(startMs: bounds.start, endMs: bounds.end, text: line.text,
                      lang: line.lang,
                      localLabel: "me", voiceprint: voice, translatesHere: translatesHere))
    }

    /// `stop()` bounded by a deadline: a wedged analyzer must not hold an utterance
    /// forever. Returns whatever it had committed by then.
    ///
    /// A watchdog rather than a task group: `SpeechSession` is `@MainActor` and not
    /// `Sendable`, so handing it to a group's `@Sendable` closures would be sending
    /// a non-Sendable value across isolation. Everything here stays on the main
    /// actor, and the `await` on `stop()` is what lets the watchdog run.
    private func transcribe(_ session: SpeechSession, deadlineMs: Int) async -> String {
        let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(deadlineMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            // Cancelling makes the analyzer finish now and hand back whatever it
            // had already committed, instead of holding the utterance open.
            session.cancel()
        }
        let text = await session.stop()
        watchdog.cancel()
        return text
    }

    // MARK: - Interruption and routes

    private func handle(interruption event: AudioInterruption) {
        switch event {
        case .began:
            guard capturing, !interrupted else { return }
            interrupted = true
            interruptedAt = clock.now
            // End whatever was being said; the rest of it is lost to the call.
            // The encoder's tail goes now, while the audio clock still points at the
            // moment the call arrived — `resumeAfterInterruption` winds it forward by
            // the length of the call, and a packet flushed after that would be
            // stamped minutes away from the sound in it.
            flushEncoderTail()
            if let ended = segmenter.flush(), case .ended(let startMs, let endMs) = ended {
                finishUtterance(startMs: startMs, endMs: endMs)
            }
            speech?.cancel()
            speech = nil
            level = 0
            // Audio captured just before the call is not the opening of whatever is
            // said after it. Left queued, those frames would be uploaded stamped with
            // post-interruption timestamps, twenty minutes away from the sound in them.
            preRoll.removeAll()
            pendingSpeechFrames.removeAll()
            // `finishUtterance` above may have left words in flight; the
            // recogniser they came from has just been cancelled, so they are
            // the last thing that should stay on screen behind a "Paused".
            clearPartial()
            // Amber, frozen clock, and the word "Paused" on the island and the
            // tab: the phone is no longer hearing the room and must not keep
            // claiming it is.
            pushBeacon()
            JcLog.voice.notice("live capture paused by an audio interruption")
        case .ended:
            guard interrupted else { return }
            Task { [weak self] in await self?.resumeAfterInterruption() }
        }
    }

    private func resumeAfterInterruption() async {
        guard capturing, halt == nil else { return }
        let epoch = generation
        do {
            // Re-assert: iOS deactivated us under the belief we were still active.
            try session.reassert()
            if !input.isRunning { try await input.start(sampleRate: captureRate) }
            guard epoch == generation else { return }
            // The clock is wound forward only once the mic is actually back. Doing it
            // before the restart meant a FAILED restart still advanced the clock, so a
            // later successful resume double-counted the gap.
            if let began = interruptedAt {
                // Without this the timestamps after an interruption claim the
                // conversation carried straight on, so a transcript with a
                // twenty-minute call in the middle of it reads as continuous and
                // every later row is wrong by the length of the call.
                segmenter.skip(ms: Int(clock.now.timeIntervalSince(began) * 1000))
                interruptedAt = nil
            }
            // Only now does audio count again — `handle(frame:)` drops frames while
            // `interrupted`, which is what keeps them out of the skipped window.
            interrupted = false
            refreshSources()
            armMicWatchdog(epoch: epoch)
            pushBeacon()
            JcLog.voice.notice("live capture resumed after the interruption")
        } catch {
            report("resume Live recording", error)
            // Still paused, and visibly so, rather than a screen that says Recording
            // over a mic we failed to get back.
            armMicWatchdog(epoch: epoch)
        }
    }

    private func routeChanged() {
        refreshSources()
        guard capturing else { return }
        // The label, not the choice: after unplugging headphones iOS has already
        // moved us, and the transcript should say where the audio is coming from
        // now rather than what was picked earlier.
        sendSourceLabel()
    }

    /// What goes up as `source_label`, and what the status line shows.
    var sourceLabel: String {
        let route = LiveCaptureSources.currentRouteLabel()
        return activeSource.kind == .automatic ? route : "\(activeSource.label) (\(route))"
    }

    // MARK: - Receiving

    /// The socket's text entry point. Internal rather than private so a test can
    /// drive the client from the server side without a real socket — this IS the
    /// boundary, so there is nothing to hide behind it.
    func receive(text: String) {
        guard let frame = LiveServerFrame.decode(text: text) else {
            JcLog.voice.notice("live: undecodable text frame \(text.utf8.count, privacy: .public)B")
            return
        }
        apply(frame)
    }

    /// One decoded frame, from the socket or from a replay.
    ///
    /// Split out so a note restored by `backfill` takes the SAME path a live one
    /// takes — the alternative is a second, quietly diverging copy of every
    /// placement rule (the wrap-up at the end, an anchored verdict under its
    /// line) for the restore case.
    private func apply(_ frame: LiveServerFrame) {
        switch frame {
        case .ready(let ready):
            apply(ready)
        case .segment(let segment):
            upsert(segment)
            translateOnDevice(segment)
        case .speaker(let event):
            apply(event)
        case .insight(let insight):
            upsert(insight)
        case .factCheck(let result):
            // The answer is here, so the loading card's deadline is moot.
            cancelFactCheckDeadline()
            // A verdict the server anchored to one row sits under that row; one
            // about a whole window lands at the end of the transcript. Either
            // way a failed pass renders as a failure, never as a completed check.
            transcript.apply(result)
        case .wrapUp(let wrap):
            // Rendered at the end of the transcript AS WELL AS going into the
            // paired chat (the server does that; §4). The screen that produced
            // the conversation used to be the one place its conclusion never
            // appeared.
            transcript.apply(wrap)
        case .speak(let text):
            speakReply(text)
        case .state(let state):
            apply(state)
        case .error(let message):
            error = message
        case .unknown(let kind):
            // Kept, not dropped: a server that started sending a new frame type
            // should be visible in the log, not indistinguishable from silence.
            JcLog.voice.notice("live: unknown frame \(kind, privacy: .public)")
        }
    }

    private func apply(_ ready: LiveReady) {
        // A `ready` with no session id would blank `liveSessionID`, which silently
        // disables backfill, fact-check, translate and endSession (each guards on it)
        // — and `spool.adopt("")` returns early, so the spool would keep the PREVIOUS
        // session's frames and drain them into this stream, filing a conversation
        // under the wrong transcript.
        guard !ready.liveSessionID.isEmpty else {
            report("read the Live session id", APIError.badResponse("ready carried no session id"))
            return
        }
        // THE SERVER'S ID WINS. We asked to continue `resumeRequestedID`; a
        // different id coming back means the server declined — either because
        // that conversation has grown past its share of the model's context and
        // was rolled over, or because this server no longer has it at all. Both
        // mean the rows on screen belong to a conversation that is over, and
        // carrying them (or our cursor, or the audio clock) into a new session
        // would interleave two conversations under one transcript.
        let rolledOver = !resumeRequestedID.isEmpty && resumeRequestedID != ready.liveSessionID
        if rolledOver {
            JcLog.voice.notice("live: server started a new session; clearing the previous transcript")
            transcript.removeAll()
            clearPartial()
            // The audio clock restarts with the session. `AmbientSegmenter`
            // deliberately never rewinds, so it is REPLACED — the same reason
            // `openOrResumeSession` replaces it for a new conversation.
            segmenter = AmbientSegmenter()
            audioSeq = 0
            settings.forgetCursor()
        }
        let resumed = !rolledOver && !liveSessionID.isEmpty && liveSessionID == ready.liveSessionID
        resumeRequestedID = ready.liveSessionID
        liveSessionID = ready.liveSessionID
        if !ready.chatSessionID.isEmpty {
            chatSessionID = ready.chatSessionID
            settings.lastChatSessionID = ready.chatSessionID
        }
        lane = ready.lane
        // If the server would not grant the edge lane, say so rather than leaving
        // the status line claiming on-device transcription.
        if ready.lane == .server, sttEnabled {
            sttEnabled = false
            sttNotice = "Jarvis is transcribing on the server for this session."
        }
        spool.adopt(sessionID: ready.liveSessionID)
        refreshSpoolCounters()
        settings.rememberCursor(sessionID: ready.liveSessionID, seq: ready.seq)
        if let socket, connected { drainSpool(into: socket) }
        sendSourceLabel()
        // Backfill anything said while we were away. A reconnect mid-conversation
        // is the normal path, so the transcript must close its own gaps.
        let cursor = transcript.cursor
        if !resumed || ready.seq > cursor {
            Task { [weak self] in await self?.backfill(afterSeq: cursor) }
        }
    }

    private func backfill(afterSeq: Int) async {
        guard !liveSessionID.isEmpty else { return }
        do {
            let page = try await api.transcript(liveSessionID: liveSessionID, afterSeq: afterSeq)
            for row in page.segments { upsert(row) }
            // After the rows, so a note that belongs under a line finds it.
            for note in page.notes { apply(note) }
        } catch { report("load the transcript", error) }
    }

    private func upsert(_ segment: LiveSegment) {
        // The committed row REPLACES the words that were waiting on it, in the
        // same render: the guess and the record must never both be on screen.
        // Only those words — `partialText` is the NEXT line, still being spoken,
        // and blanking it here is what an echo landing mid-sentence used to do.
        clearCommitting()
        transcript.upsert(segment)
        settings.rememberCursor(sessionID: liveSessionID, seq: segment.seq)
    }

    private func upsert(_ insight: LiveInsight) {
        transcript.upsert(insight)
        settings.rememberCursor(sessionID: liveSessionID, seq: insight.seq)
    }

    private func apply(_ event: LiveSpeakerEvent) {
        transcript.apply(event)
        // The voices list carries names and counts that a merge or rename changes.
        Task { [weak self] in await self?.loadSpeakers() }
    }

    private func apply(_ state: LiveStateFrame) {
        if let bytes = state.storageBytes { storageBytes = bytes }
        // Present-and-empty means "withdraw the warning"; absent means "unchanged".
        // Collapsing the two left an amber banner up for the rest of a session after
        // the server had cleared it.
        if let warning = state.warning { serverWarning = warning }
        // The server believing us paused while we believe we are recording is the
        // cheapest cross-check available on "is the audio actually arriving", so it
        // reaches the status line rather than only the log.
        if let paused = state.paused { serverPaused = paused }
        if let recording = state.recording, recording { serverPaused = false }
        // The figure and the qualifier the island shows both come from here.
        pushBeacon()
    }

    /// Design §6: replies honour the spoken-vs-text setting. Spoken output uses the
    /// PHONE's own synthesizer, not `/api/voice/synthesize` — an ambient insight is
    /// a short aside and a round trip for TTS audio would arrive after the moment
    /// it was about.
    private func speakReply(_ text: String) {
        guard config.spokenReplies, !text.isEmpty else { return }
        // ONE synthesizer, reused. `speak`'s "interrupt whatever is still being said"
        // contract is per instance, so a fresh one per insight meant two of them
        // talking over each other — and the previous one was kept alive by its own
        // detached Task, so nothing ever released it.
        let synthesizer = spokenReply ?? DefaultVoiceSynthesizing()
        spokenReply = synthesizer
        Task { _ = await synthesizer.speak(text, rate: DefaultVoiceSynthesizing.defaultRate) }
    }

    /// Held so the synthesizer is not deallocated mid-sentence, and so `stop()` can
    /// silence it — an insight must not keep talking after recording ends.
    private var spokenReply: VoiceSynthesizing?

    // MARK: - Per-segment actions

    /// A fact-check of the recent conversation is in flight.
    ///
    /// The request is a full agent turn with web tools, so this can be true for
    /// several seconds — which is exactly why the control has to show a real
    /// spinner rather than a change of shade.
    /// DERIVED from the card, not a flag of its own.
    ///
    /// It used to be set around the `await` on the POST — but the server accepts
    /// the job and returns at once (the agent turn runs off-thread), so the
    /// button's spinner stopped after a fraction of a second while the actual
    /// work had barely started. One source of truth means the button and the
    /// card say the same thing for the same length of time.
    var checkingConversation: Bool { transcript.factCheck?.pending == true }

    /// The latest verdict, or the reason there isn't one.
    var factCheck: LiveFactCheckResult? { transcript.factCheck }

    /// Ask Jarvis to check what has just been said.
    ///
    /// **Nothing checks anything on its own.** This is the only path in the
    /// client that calls `/api/live/factcheck`, and it runs only from the
    /// Fact-check button. The server's `run_fact_check` likewise has exactly one
    /// caller, that endpoint. (The one watcher that IS automatic is translate.)
    ///
    /// The verdict does not come back on this response — it arrives later as an
    /// `insight` over the socket, because the work is a whole agent turn and
    /// running it inside the HTTP handler used to get 504'd by the edge. So this
    /// finishing only means "the server accepted the job".
    func factCheckConversation() async {
        guard !liveSessionID.isEmpty else {
            transcript.apply(LiveFactCheckResult(
                text: "There's no conversation to check yet.", failed: true))
            return
        }
        guard !checkingConversation else { return }
        // The card appears NOW, in its loading state, at the place the verdict
        // will land — and becomes the verdict in place rather than a placeholder
        // vanishing and a different card arriving. Until this, the only feedback
        // during a multi-second agent turn was a spinner on a small tile at the
        // bottom of the screen. It is also what keeps the BUTTON busy, so the
        // two cannot disagree.
        transcript.apply(LiveFactCheckResult(pending: true))
        do {
            try await api.factCheckConversation(liveSessionID: liveSessionID)
            // Accepted, not answered: the verdict arrives later as an `insight`.
            // Arm a deadline so a verdict that never comes stops the card
            // spinning forever and says so instead.
            armFactCheckDeadline()
        } catch {
            // A refusal must NOT read as a completed check. The server's own
            // words go to the log; the screen gets a sentence.
            JcLog.dropped(JcLog.voice, "fact-check the conversation", error)
            cancelFactCheckDeadline()
            transcript.apply(LiveFactCheckResult(
                text: Self.factCheckFailureText(error), failed: true))
        }
    }

    /// How long a verdict has to arrive over the socket before the loading card
    /// gives up.
    ///
    /// Sits just above the SERVER's own deadline (`fact_check_timeout_seconds`,
    /// 15s), so the server stops the work and this only ever catches a verdict
    /// lost in transit — a socket that dropped between the request and the
    /// answer. Two minutes was the old value and it was a lie: the user was
    /// watching a spinner long after anything was still happening.
    static let factCheckDeadlineMs = 20_000

    private var factCheckDeadline: VoiceTimerToken?

    private func armFactCheckDeadline() {
        cancelFactCheckDeadline()
        factCheckDeadline = clock.schedule(after: Self.factCheckDeadlineMs) { [weak self] in
            guard let self else { return }
            self.factCheckDeadline = nil
            // Only the card we put up. A verdict that landed in the meantime is
            // the answer and must not be overwritten by a timeout.
            guard self.transcript.factCheck?.pending == true else { return }
            // Ask before declaring failure. The verdict is STORED the moment
            // it is produced, and the frame carrying it can be lost — a socket
            // that dropped between the request and the answer is the ordinary
            // case here, and it is exactly why the same verdict turns up in
            // the paired chat while this screen shows nothing.
            Task { [weak self] in await self?.reconcileFactCheck() }
        }
    }

    /// Look for a verdict that was produced but never reached this device.
    ///
    /// Only on the timeout path: a refetch on every check would be a round trip
    /// nobody needs when the frame arrives normally, which it usually does.
    private func reconcileFactCheck() async {
        guard !liveSessionID.isEmpty else {
            failPendingFactCheck()
            return
        }
        do {
            let page = try await api.transcript(liveSessionID: liveSessionID,
                                                afterSeq: 0)
            for note in page.notes { apply(note) }
        } catch {
            JcLog.dropped(JcLog.voice, "look for the verdict", error)
        }
        // Still nothing, so it really did not happen.
        failPendingFactCheck()
    }

    private func failPendingFactCheck() {
        guard transcript.factCheck?.pending == true else { return }
        transcript.apply(LiveFactCheckResult(
            text: "Jarvis didn't send a verdict back. Nothing has been verified.",
            failed: true))
    }

    private func cancelFactCheckDeadline() {
        factCheckDeadline?.cancel()
        factCheckDeadline = nil
    }

    /// A sentence for a check that never started. The only case worth naming
    /// separately is the watcher being switched off, because that one the user
    /// can actually fix.
    private static func factCheckFailureText(_ error: Error) -> String {
        if case APIError.http(let status, _) = error, status == 400 || status == 404 {
            return "This Jarvis server can't check a whole conversation yet — "
                 + "it still expects a single line. Nothing has been verified."
        }
        return LiveFailureText.humanSentence
    }

    // MARK: - Browsing past conversations

    /// Past conversations, newest first, for the session picker.
    private(set) var sessions: [LiveSessionSummary] = []
    /// The session being READ rather than recorded. Empty when this screen is
    /// showing the live conversation.
    private(set) var viewingSessionID = ""
    private(set) var loadingSessions = false

    /// True while looking at a conversation that is over. Recording is hidden
    /// rather than disabled-looking, because appending to a finished session is
    /// not something the user should be invited to try and then refused.
    var readOnly: Bool { !viewingSessionID.isEmpty }

    func loadSessions() async {
        guard !loadingSessions else { return }
        loadingSessions = true
        defer { loadingSessions = false }
        do { sessions = try await api.sessions(); clearTransientError() }
        catch { report("load your Live conversations", error) }
    }

    /// Open a past conversation, read-only.
    ///
    /// Refused while recording rather than silently stopping the microphone:
    /// browsing is not a reason to end a recording the user started.
    func view(session: LiveSessionSummary) async {
        guard !capturing else {
            error = "Stop recording first — then you can look back at another conversation."
            return
        }
        guard session.id != viewingSessionID else { return }
        viewingSessionID = session.id
        transcript.removeAll()
        clearPartial()
        do {
            let page = try await api.transcript(liveSessionID: session.id, afterSeq: 0)
            guard viewingSessionID == session.id else { return }
            for row in page.segments { transcript.upsert(row) }
            // Looking back at a finished conversation shows what was said about
            // it too — the verdicts and the wrap-up, not just the utterances.
            for note in page.notes { apply(note) }
            clearTransientError()
        } catch {
            report("load that conversation", error)
        }
    }

    /// Back to the live conversation: drop the read-only view so Record returns.
    func stopViewing() {
        guard readOnly else { return }
        viewingSessionID = ""
        transcript.removeAll()
        clearPartial()
    }

    /// Deliberately begin a NEW conversation instead of continuing the last one.
    /// The rollover point is the server's to decide, but starting fresh on
    /// purpose is the user's.
    func startFreshSession() {
        viewingSessionID = ""
        transcript.removeAll()
        clearPartial()
        settings.forgetCursor()
        resumeRequestedID = ""
        liveSessionID = ""
        chatSessionID = ""
    }

    /// This phone translates the lines it sends, rather than the server. Said
    /// on every line (`translate: "device"`) instead of once in `hello`, so
    /// changing it in Settings holds from the next line, not the next connection.
    var translatesHere: Bool { config.translate && settings.translateOnPhone }

    /// Hand a foreign utterance to the phone's own translator.
    ///
    /// Only what is already known to need it: a line the transcript labels as
    /// another language, with no translation yet. The server has the same rule,
    /// so the two cannot disagree about what counts as foreign — and whichever
    /// answers first wins, because both write the same field.
    private func translateOnDevice(_ segment: LiveSegment) {
        guard translatesHere, !readOnly else { return }
        // The row as held, not the frame: a row re-sent after identification or
        // the language rescue carries no translation even when the line already
        // has one, and reading the frame translated it a second time.
        let held = transcript.segment(seq: segment.seq) ?? segment
        guard (held.translation ?? "").isEmpty else { return }
        guard !held.lang.isEmpty else { return }
        translator.target = config.primaryLanguage
        translator.request(seq: held.seq, text: held.text, source: held.lang)
    }

    /// Wire the translator's answers into the transcript. Called once, at init.
    private func adoptTranslator() {
        translator.onTranslated = { [weak self] seq, text in
            guard let self else { return }
            // On screen immediately — this is the whole point of doing it here.
            self.transcript.setTranslation(seq: seq, text: text)
            // Then to the server, so it survives the app closing and reaches
            // every other device looking at this conversation.
            Task { [weak self] in await self?.storeTranslation(seq: seq, text: text) }
        }
        translator.onSkipped = { [weak self] seq, why in
            guard let self else { return }
            switch why {
            case .alreadyInTarget:
                // Nothing to do, and nobody else should be asked. Passing this
                // to the server is what produced an English line with an
                // identical English "translation" under it.
                break
            case .cannot:
                // This phone has no pack for that pair. The server has more
                // languages and does not need the screen to be open.
                guard let row = self.transcript.segment(seq: seq) else { return }
                Task { [weak self] in await self?.translate(row) }
            }
        }
    }

    private func storeTranslation(seq: Int, text: String) async {
        guard !liveSessionID.isEmpty else { return }
        do { try await api.saveTranslation(liveSessionID: liveSessionID, seq: seq,
                                           translation: text) }
        catch {
            // The words are already on screen; failing to persist them is worth
            // a log and nothing louder.
            JcLog.dropped(JcLog.voice, "store that translation", error)
        }
    }

    func translate(_ segment: LiveSegment, to target: String? = nil) async {
        guard !liveSessionID.isEmpty else { return }
        let language = target ?? config.primaryLanguage
        do { try await api.translate(liveSessionID: liveSessionID, seq: segment.seq, target: language) }
        catch { report("translate that", error) }
    }

    /// Give the voice in this row a name. The rename lands locally at once so the
    /// chip changes under the user's finger, and the server's `speaker` frame
    /// confirms it for every other device.
    func nameVoice(of segment: LiveSegment, as name: String) async {
        guard let id = segment.speakerID, !id.isEmpty else {
            error = "Jarvis hasn't worked out whose voice that is yet."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply(LiveSpeakerEvent(op: .rename, speakerID: id, name: trimmed))
        do { try await api.rename(speakerID: id, name: trimmed) }
        catch { report("rename that voice", error) }
    }

    func rename(speaker: LiveSpeaker, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await api.rename(speakerID: speaker.id, name: trimmed)
            apply(LiveSpeakerEvent(op: .rename, speakerID: speaker.id, name: trimmed))
        } catch { report("rename that voice", error) }
    }

    /// Which of two voices should survive a merge, when the user has not said.
    ///
    /// A NAME is the strongest signal there is — somebody typed it, and throwing
    /// it away to keep an anonymous "Speaker 4" would undo work the user did by
    /// hand. After that, the voice with more history wins: fewer rows have to be
    /// rewritten, and the bigger voiceprint is the better one to keep matching
    /// against. The user can still flip it; this only decides what is offered.
    static func survivorOfMerge(_ a: LiveSpeaker, _ b: LiveSpeaker) -> LiveSpeaker {
        let aNamed = !a.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let bNamed = !b.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if aNamed != bNamed { return aNamed ? a : b }
        if a.segmentCount != b.segmentCount { return a.segmentCount > b.segmentCount ? a : b }
        return a
    }

    /// Fold `other` into `survivor`: the user says they are the same person.
    ///
    /// The relabel lands locally the moment the server accepts it, so the
    /// transcript on screen changes under the user's finger rather than waiting
    /// for a reload — `LiveTranscript.apply` rewrites every row already showing
    /// the folded id. The server's own `speaker` frame then confirms it for every
    /// other device.
    func merge(_ other: LiveSpeaker, into survivor: LiveSpeaker) async {
        guard !other.id.isEmpty, !survivor.id.isEmpty, other.id != survivor.id else { return }
        // The survivor's own name wins; the folded voice's name is inherited only
        // when the survivor has none, which is the same rule the server applies.
        let survivorName = survivor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let otherName = other.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = survivorName.isEmpty ? (otherName.isEmpty ? nil : otherName) : survivorName
        do {
            try await api.merge(fromID: other.id, intoID: survivor.id)
            apply(LiveSpeakerEvent(op: .merge, speakerID: survivor.id,
                                   name: name, mergedFrom: [other.id]))
        } catch { report("merge those voices", error) }
    }

    func delete(kind: LiveDeleteKind, id: String) async {
        do {
            let outcome = try await api.delete(kind: kind, id: id)
            await loadStorage()
            await loadSpeakers()
            // Said AFTER the reloads, because each of them clears the transient
            // error on success — a message set before them would be wiped by
            // the very refresh the delete triggered.
            //
            // Through `error` on purpose: this IS the case where the delete did
            // not do everything it said, and there is no quieter place on this
            // screen the user would actually read.
            if let shortfall = outcome.shortfall {
                error = "Deleted, but \(shortfall)."
            }
            if kind == .session, id == liveSessionID {
                transcript.removeAll()
                // Asking to resume a session the user just deleted would have
                // the server mint a new one and the client reset anyway — but
                // via a round trip and a log line about a session it cannot
                // find. Forget it here instead.
                settings.forgetCursor()
                resumeRequestedID = ""
            }
        } catch { report("delete that", error) }
    }

    // MARK: - Status

    /// The status line of design §7.1: recording state and stored audio.
    ///
    /// Ordered so the least reassuring true thing wins. Every branch below exists
    /// because it is a state in which the honest answer is NOT "Recording".
    var statusText: String {
        if let halt { return halt.title }
        if preparing {
            let percent = Int(prepareProgress * 100)
            return percent > 0 ? "Getting the speech model ready… \(percent)%"
                               : "Getting the speech model ready…"
        }
        if interrupted { return "Paused — audio in use" }
        guard capturing else {
            if !settings.captureHere { return "Viewing only" }
            return spooledFrames > 0
                ? "Not recording — \(LiveFormat.bytes(spool.byteCount)) still to upload"
                : "Not recording"
        }
        if !connected {
            return spooledFrames > 0
                ? "Reconnecting — \(LiveFormat.bytes(spool.byteCount)) buffered"
                : "Reconnecting"
        }
        // The server says it is not getting audio from us. It knows something we
        // cannot see from here, so it outranks our own belief.
        if serverPaused { return "Recording — but Jarvis isn't receiving audio" }
        // The buffer is in memory only, so a crash would take it. Better said than
        // implied by a class that claims to be crash-proof.
        if !spool.isDurable { return "Recording — buffer not saved to disk" }
        return lane == .edge ? "Recording on device" : "Recording"
    }

    var storageText: String {
        storageBytes > 0 ? "\(LiveFormat.bytes(storageBytes)) stored" : "No audio stored yet"
    }

    /// Seconds since capture began, by the wall clock, or nil when nothing is
    /// being captured. The same figure the screen's clock and the Live
    /// Activity's both read, so the two can never disagree.
    var elapsedSeconds: TimeInterval? {
        guard let captureStartedAt, capturing else { return nil }
        return max(0, Date().timeIntervalSince(captureStartedAt))
    }

    /// The qualifier `statusText` attached to the state, if any — the one thing
    /// the island has to say beyond "recording" and the figure.
    ///
    /// Derived from `statusText` rather than rebuilt: every branch of that
    /// property exists because it is a state where the honest answer is not
    /// "Recording", and a second derivation here would quietly miss the ones it
    /// forgot about.
    private var activityDetail: String {
        LiveRecorderStatus.split(statusText).detail ?? ""
    }

    /// Hand the indicator and the Live Activity the current truth. Cheap: the
    /// beacon drops anything already on screen and rate-limits the rest, so
    /// this can be called from any state change without thinking about budget.
    private func pushBeacon() {
        guard capturing else { return }
        beacon.update(interrupted: interrupted,
                      elapsed: elapsedSeconds ?? 0,
                      kept: storageText,
                      detail: activityDetail)
    }

    /// The warning worth showing, if any: ours about the backlog, or the server's.
    var warningText: String {
        !spoolWarning.isEmpty ? spoolWarning : serverWarning
    }

    private func report(_ what: StaticString, _ failure: Error) {
        guard !wasCancelled(failure) else { return }
        error = "Couldn't \(String(describing: what)): " + apiErrorLine(failure)
        JcLog.dropped(JcLog.voice, what, failure)
    }
}
