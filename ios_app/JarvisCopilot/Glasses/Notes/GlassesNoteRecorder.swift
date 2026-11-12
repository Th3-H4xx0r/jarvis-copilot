import Foundation
import Observation

/// Records an AI note through the GO3: the glasses' microphone is transcribed on
/// the phone by Jarvis's own speech engine, the sentence being spoken goes back to
/// the lens, glasses photos land in the note where they were taken, and Jarvis
/// (through the app's chat) writes the title and summary. Nothing reaches INMO.
///
/// Started from the phone, or from the glasses' own notes app (button/touchpad),
/// which opens lens app 5 and waits for a phone to serve it.
@MainActor
@Observable
final class GlassesNoteRecorder {
    static let shared = GlassesNoteRecorder()

    enum Phase: Equatable { case idle, starting, recording, saving }
    private(set) var phase: Phase = .idle
    private(set) var elapsed = 0
    private(set) var transcript = ""
    private(set) var photos: [GlassesNote.Photo] = []
    private(set) var noteID: String?
    /// The last problem, shown on the notes screen.
    private(set) var problem: String?

    /// The glasses' own notes app starts a Jarvis note. On by default.
    var startsFromGlasses: Bool {
        get { defaults.object(forKey: Self.fromGlassesKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.fromGlassesKey) }
    }
    static let fromGlassesKey = "glasses.notes.startFromGlasses"
    /// The official app's cap.
    static let maxSeconds = 3600

    private let defaults: UserDefaults
    private let store: GlassesNotesStore
    private let recognizer = DefaultSpeechRecognizing()
    private var observer: UUID?
    private var decoder: InmoOpusDecoder?
    private var speech: SpeechSession?
    private var lens = GlassesNoteLens()
    private var segments: [GlassesNote.Segment] = []
    private var startedAt = Date()
    private var ticker: Task<Void, Never>?
    private var sendChain: Task<Void, Never>?
    private var lastPartialSent = Date.distantPast
    private var heldPartial: String?
    // SageNote (firmware 3.0.x) session: Jarvis opens the app and drives a meeting session.
    private var sageSessionId = ""
    private var sageStarted = false
    private var sageFallback: Task<Void, Never>?
    private var sageSegmentId = 0
    private var inSageNote: Bool { !sageSessionId.isEmpty }
    private var sageSummaryTask: Task<Void, Never>?
    private var sageSummaryRevision = 0
    private var sageSummarizedChars = 0
    private var sageAudioFrames = 0
    private var sageConfigRevision = 0
    /// The glasses ended the meeting (STOP / NOTIFY_STOPPED / closed INMEET) — don't send it back.
    private var sageStoppedByGlasses = false

    init(defaults: UserDefaults = .standard, store: GlassesNotesStore = .shared) {
        self.defaults = defaults
        self.store = store
    }

    func install() {
        guard observer == nil else { return }
        observer = InmoSession.shared.addEventObserver { [weak self] in self?.receive($0) }
    }

    // MARK: Start / save

    /// `adoptingSession`: the glasses already started an INMEET meeting (e.g. a phone call) —
    /// serve that session instead of opening INMEET and starting our own.
    func start(adoptingSession glassesSession: String? = nil) async {
        guard phase == .idle else { return }
        phase = .starting
        problem = nil
        do {
            try await InmoSession.shared.ensureConnected()
            guard let session = await recognizer.startSession(sampleRate: 16000, prompt: true) else {
                throw InmoProtocolError.unavailable("On-device speech recognition isn't available. Allow Speech Recognition for Jarvis in Settings.")
            }
            decoder = try InmoOpusDecoder()
            let ms = UInt64(Date().timeIntervalSince1970 * 1000)
            noteID = String(ms)
            startedAt = Date()
            elapsed = 0; transcript = ""; photos = []; segments = []; lens = GlassesNoteLens()
            speech = session
            session.onPartial = { [weak self] text in self?.heard(text) }
            // SageNote is phone-driven: open the app, wait briefly for the glasses to start the
            // session, else fall back to sending START_MEETING ourselves (the official app's flow).
            let adopted = !(glassesSession ?? "").isEmpty
            sageSessionId = adopted ? glassesSession! : UUID().uuidString
            sageStarted = adopted; sageStoppedByGlasses = false; sageSegmentId = 0; sageAudioFrames = 0
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            if !adopted { post(GlassesSageNoteWire.open()) }
            sageConfigRevision += 1
            post(GlassesSageNoteWire.config(sessionId: sageSessionId, revision: sageConfigRevision,
                                            language: Locale.current.language.languageCode?.identifier ?? "en", nowMs: nowMs))
            InmoRuntimeDiagnostics.note(adopted ? "inmeet session adopted from glasses (session=\(sageSessionId.prefix(10)))"
                                                : "inmeet opened, waiting for glasses start (session=\(sageSessionId.prefix(8)))")
            sageFallback?.cancel()
            if !adopted { sageFallback = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !self.sageStarted, self.phase == .recording || self.phase == .starting else { return }
                self.post(GlassesSageNoteWire.startMeeting(commandId: UUID().uuidString, sessionId: self.sageSessionId,
                                                           nowMs: UInt64(Date().timeIntervalSince1970 * 1000)))
                self.sageStarted = true
                InmoRuntimeDiagnostics.note("sagenote fallback START_MEETING sent (glasses didn't self-start)")
            } }
            // Live running summary on the lens (INMO's app does this via cloud AI; Jarvis uses its own).
            sageSummaryRevision = 0; sageSummarizedChars = 0
            sageSummaryTask?.cancel()
            sageSummaryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, self.phase == .recording, self.inSageNote else { return }
                    await self.pushRunningSummary()
                }
            }
            phase = .recording
            InmoRuntimeDiagnostics.note("note started id=\(ms)")
            ticker = Task { [weak self] in
                var seconds = 0
                while !Task.isCancelled {
                    guard let self, self.phase == .recording else { return }
                    self.elapsed = seconds
                    self.post(GlassesSageNoteWire.state(sessionId: self.sageSessionId, elapsedSeconds: seconds,
                                                        nowMs: UInt64(Date().timeIntervalSince1970 * 1000)))
                    if let held = self.heldPartial { self.heldPartial = nil; self.sendLens([.init(text: held, final: false)]) }
                    if seconds >= Self.maxSeconds { await self.save(); return }
                    try? await Task.sleep(for: .seconds(1))
                    seconds = Int(Date().timeIntervalSince(self.startedAt))
                }
            }
        } catch {
            phase = .idle
            problem = error.localizedDescription
            // Tell the lens (it may have opened the notes app itself) and close it.
            if InmoSession.shared.state == .ready {
                sageFallback?.cancel(); sageFallback = nil; sageSummaryTask?.cancel(); sageSummaryTask = nil
                post(GlassesSageNoteWire.close())
            }
        }
    }

    /// Stops the note, stores it, then (in the background) asks Jarvis for the
    /// summary and pulls the full-size glasses photos over Wi-Fi.
    func save() async {
        guard phase == .recording, let id = noteID else { return }
        phase = .saving
        ticker?.cancel(); ticker = nil
        sageFallback?.cancel(); sageFallback = nil; sageSummaryTask?.cancel(); sageSummaryTask = nil
        if InmoSession.shared.state == .ready, !sageStoppedByGlasses {
            post(GlassesSageNoteWire.stopMeeting(commandId: UUID().uuidString, sessionId: sageSessionId,
                                                 nowMs: UInt64(Date().timeIntervalSince1970 * 1000)))
            post(GlassesSageNoteWire.close())
        }
        sageStarted = false; sageStoppedByGlasses = false
        var text = transcript
        if let speech {
            let final = await voiceStopWithDeadline(speech, after: 3000, clock: SystemVoiceClock())
            if !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = final }
        }
        speech = nil; decoder = nil
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        for line in lens.finish(text) { segments.append(.init(ms: ms, text: line.text)) }
        let note = GlassesNote(id: id, createdAt: startedAt, duration: Date().timeIntervalSince(startedAt),
                               title: Self.defaultTitle(startedAt), text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               segments: segments, photos: photos, summary: nil, chatSessionID: nil)
        do { try store.save(note) } catch { problem = "Couldn't save the note: \(error.localizedDescription)" }
        InmoRuntimeDiagnostics.note("note saved id=\(id) chars=\(note.text.count) photos=\(photos.count)")
        phase = .idle
        noteID = nil
        Task { await GlassesNoteFinisher.finish(noteID: id, store: store) }
    }

    /// Drops the note being recorded.
    func discard() {
        guard phase == .recording else { return }
        ticker?.cancel(); ticker = nil
        sageFallback?.cancel(); sageFallback = nil; sageSummaryTask?.cancel(); sageSummaryTask = nil
        if InmoSession.shared.state == .ready {
            post(GlassesSageNoteWire.stopMeeting(commandId: UUID().uuidString, sessionId: sageSessionId,
                                                 nowMs: UInt64(Date().timeIntervalSince1970 * 1000)))
            post(GlassesSageNoteWire.close())
        }
        sageStarted = false
        speech?.cancel(); speech = nil; decoder = nil
        if let id = noteID { store.delete(id) }
        noteID = nil
        phase = .idle
    }

    static func defaultTitle(_ date: Date) -> String {
        "Note · " + date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Glasses traffic

    private func receive(_ event: InmoEvent) {
        switch event {
        case .connectionChanged(let state):
            if phase == .recording, state == .disconnected || state == .failed {
                problem = "Glasses disconnected — the note was saved."
                Task { await save() }
            }
        case .message(let type, let fields, _):
            // SageNote(43): the glasses started the session on their side — adopt their session id,
            // acknowledge the command, and cancel our fallback START so we don't double-start.
            if type == 43 {
                if case let .command(cmd, commandId, sessionId)? = (try? GlassesSageNoteWire.parse(type: type, fields: fields)) {
                    let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
                    let ackSession = sessionId.isEmpty ? sageSessionId : sessionId
                    post(GlassesSageNoteWire.ack(commandId: commandId, cmd: cmd, sessionId: ackSession, ok: true, nowMs: nowMs))
                    InmoRuntimeDiagnostics.note("inmeet glasses cmd=\(cmd) acked session=\(ackSession.prefix(10)) phase=\(phase)")
                    if GlassesSageNoteWire.isStart(cmd) {
                        if phase == .idle {
                            // The glasses started INMEET themselves (call recording / lens button).
                            if startsFromGlasses { Task { await start(adoptingSession: ackSession) } }
                        } else {
                            sageStarted = true
                            if !sessionId.isEmpty { sageSessionId = sessionId }
                        }
                    } else if GlassesSageNoteWire.isStop(cmd), phase == .recording {
                        sageStoppedByGlasses = true
                        Task { await save() }
                    }
                }
                return
            }
            // INMEET closed on the lens (STARTING_APPLICATION switchApp 15 CLOSE): end the note.
            if let open = GlassesSageNoteWire.appState(type: type, fields: fields) {
                if !open, phase == .recording, inSageNote { sageStoppedByGlasses = true; Task { await save() } }
                return
            }
            // SageNote streams its mic/call audio as type-0 frames with audio header type 13
            // (the old note path only decodes type 3). Feed them to Jarvis's recognizer.
            if type == 0, inSageNote, phase == .recording, let decoder, let speech,
               let packets = GlassesSageNoteWire.audioPackets(fields) {
                for packet in packets { if let pcm = try? decoder.decode(packet) { speech.feed(pcm) } }
                sageAudioFrames += packets.count
                if sageAudioFrames % 50 == 0 { InmoRuntimeDiagnostics.note("sagenote audio frames=\(sageAudioFrames) session=\(sageSessionId.prefix(8))") }
                return
            }
            guard [0, 12, 15].contains(type) else { return }
            let parsed: GlassesNoteWire.Event?
            do { parsed = try GlassesNoteWire.parse(type: type, fields: fields) } catch {
                if phase == .recording { InmoRuntimeDiagnostics.note("note audio unreadable: \(error)") }
                return
            }
            guard let parsed else { return }
            switch parsed {
            case .opened, .startRequested:
                // The glasses echo our own open; only an idle phone starts a note.
                if phase == .idle, startsFromGlasses { Task { await start() } }
            case .closed, .stopRequested:
                if phase == .recording { Task { await save() } }
            case .photo(let jpeg, let name):
                guard phase == .recording, let id = noteID else { return }
                post(GlassesNoteWire.photoReceived())
                let photoName = name.isEmpty ? "\(id)_\(Int(Date().timeIntervalSince(startedAt) * 1000))" : name
                guard !photos.contains(where: { $0.id == photoName }) else { return }
                do {
                    let file = try store.writePhoto(jpeg, named: photoName, noteID: id)
                    let ms = GlassesNoteWire.photoOffsetMs(photoName) ?? Int(Date().timeIntervalSince(startedAt) * 1000)
                    photos.append(.init(id: photoName, ms: ms, file: file, fullSize: false, source: .glasses))
                } catch { problem = "Couldn't keep a glasses photo: \(error.localizedDescription)" }
            case .audio(let packets):
                guard phase == .recording, let decoder, let speech else { return }
                for packet in packets {
                    if let pcm = try? decoder.decode(packet) { speech.feed(pcm) }
                }
            }
        }
    }

    // MARK: Transcript → lens

    private func heard(_ text: String) {
        guard phase == .recording else { return }
        transcript = text
        sendLens(lens.update(text))
    }

    /// Finished sentences go at once; the growing one at most ~3×/s like the
    /// official app, the rest held for the next tick.
    private func sendLens(_ lines: [GlassesNoteLens.Line]) {
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        for line in lines {
            if line.final {
                segments.append(.init(ms: ms, text: line.text))
                heldPartial = nil
                if inSageNote { post(GlassesSageNoteWire.asr(sessionId: sageSessionId, segmentId: sageSegmentId, text: line.text, isFinal: true, nowMs: nowMs)); sageSegmentId += 1 }
                else { post(GlassesNoteWire.transcript(line.text, final: true)) }
            } else if Date().timeIntervalSince(lastPartialSent) >= 0.3 {
                lastPartialSent = Date()
                heldPartial = nil
                if inSageNote { post(GlassesSageNoteWire.asr(sessionId: sageSessionId, segmentId: sageSegmentId, text: line.text, isFinal: false, nowMs: nowMs)) }
                else { post(GlassesNoteWire.transcript(line.text, final: false)) }
            } else {
                heldPartial = line.text
            }
        }
    }

    /// Generate a running markdown summary from the transcript so far and push it to the lens
    /// (SageNote subtype-6), throttled to meaningful growth. INMO's app does this via cloud AI.
    private func pushRunningSummary() async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 120, text.count - sageSummarizedChars >= 80 else { return }
        sageSummarizedChars = text.count
        guard let markdown = await Self.runningSummaryMarkdown(text) else { return }
        guard phase == .recording, inSageNote, InmoSession.shared.state == .ready else { return }
        sageSummaryRevision += 1
        post(GlassesSageNoteWire.summary(sessionId: sageSessionId, revision: sageSummaryRevision,
                                         markdown: markdown, isFinal: false, nowMs: UInt64(Date().timeIntervalSince1970 * 1000)))
    }
    static func runningSummaryMarkdown(_ transcript: String) async -> String? {
        do {
            let chat = BoardChat()
            let session = try await chat.sessionID(for: "glassesLiveSummary", title: "Live summary")
            let turn = try await chat.run(sessionID: session, message: """
                Summarize this ongoing conversation transcript as short markdown: a one-line title (#), \
                then the key points so far as bullets, and any action items as a checklist. Keep it brief; \
                it updates live. Don't use any tools.

                Transcript so far:
                \(transcript)
                """, joinRunningTurn: true)
            let md = turn.message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            return md.isEmpty ? nil : md
        } catch { return nil }
    }
    /// Mark the current moment in the SageNote/meeting session.
    func markMoment() {
        guard inSageNote, phase == .recording, InmoSession.shared.state == .ready else { return }
        let offset = UInt64(max(0, Date().timeIntervalSince(startedAt)) * 1000)
        post(GlassesSageNoteWire.marker(sessionId: sageSessionId, markerId: UUID().uuidString,
                                        offsetMs: offset, nowMs: UInt64(Date().timeIntervalSince1970 * 1000)))
    }

    /// Sends in order: BLE writes are queued behind one another.
    private func post(_ message: Data) {
        let previous = sendChain
        sendChain = Task {
            await previous?.value
            do { try await InmoSession.shared.send(message) } catch {
                InmoRuntimeDiagnostics.note("note send failed: \(error.localizedDescription)")
            }
        }
    }
}

/// After a note is saved: Jarvis writes the title and summary (through the app's
/// own chat with the Jarvis server), then the full-size glasses photos replace the
/// Bluetooth previews.
@MainActor
enum GlassesNoteFinisher {
    static func finish(noteID: String, store: GlassesNotesStore) async {
        await summarize(noteID: noteID, store: store)
        await fetchPhotos(noteID: noteID, store: store)
    }

    static func summarize(noteID: String, store: GlassesNotesStore) async {
        guard var note = store.note(noteID), !note.text.isEmpty else { return }
        do {
            let chat = BoardChat()
            let session = try await chat.sessionID(for: "glassesNote.\(note.id)", title: note.title)
            let turn = try await chat.run(sessionID: session, message: prompt(for: note), joinRunningTurn: true)
            let (title, summary) = parse(turn.message.plainText)
            guard !summary.isEmpty else { return }
            note = store.note(noteID) ?? note
            if let title { note.title = title }
            note.summary = summary
            note.chatSessionID = session
            try store.save(note)
        } catch {
            InmoRuntimeDiagnostics.note("note summary failed: \(error.localizedDescription)")
        }
    }

    static func prompt(for note: GlassesNote) -> String {
        let minutes = Int(note.duration) / 60, seconds = Int(note.duration) % 60
        var text = """
        This is a note I just recorded on my smart glasses (\(minutes):\(String(format: "%02d", seconds)) long). \
        Reply with a short title on the first line as "Title: …", then a concise summary in markdown: \
        the key points, and any action items or reminders as a checklist. Don't use any tools.

        Transcript:
        \(note.text)
        """
        let glasses = note.photos.filter { $0.source == .glasses }
        if !glasses.isEmpty {
            let times = glasses.map { "\($0.ms / 60000):" + String(format: "%02d", ($0.ms / 1000) % 60) }
            text += "\n\nI took photos at: " + times.joined(separator: ", ")
        }
        return text
    }

    /// "Title: X" on the first line → (X, rest). Without one, the whole reply is the summary.
    static func parse(_ reply: String) -> (String?, String) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return (nil, trimmed) }
        let line = firstLine.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        guard line.lowercased().hasPrefix("title:") else { return (nil, trimmed) }
        let title = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
        let rest = trimmed.dropFirst(firstLine.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : String(title.prefix(80)), rest)
    }

    /// Asks the glasses for their unsynced files and downloads this note's photos
    /// (D:\Shorthand\<name>.jpg) over the glasses' Wi-Fi, as the official app does.
    static func fetchPhotos(noteID: String, store: GlassesNotesStore) async {
        guard let note = store.note(noteID), note.photos.contains(where: { $0.source == .glasses && !$0.fullSize }) else { return }
        let media = InmoMediaTransfer.shared
        do {
            try await media.refresh()
            for photo in note.photos where photo.source == .glasses && !photo.fullSize {
                guard let item = media.items.first(where: { $0.group == photo.id && $0.directory.lowercased().contains("shorthand") }) else { continue }
                let downloaded = try await media.download(id: item.id)
                let target = store.folder(noteID).appendingPathComponent(photo.id + ".jpg")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: downloaded, to: target)
                guard var latest = store.note(noteID), let i = latest.photos.firstIndex(where: { $0.id == photo.id }) else { continue }
                latest.photos[i].fullSize = true
                latest.photos[i].file = photo.id + ".jpg"
                try store.save(latest)
            }
        } catch {
            InmoRuntimeDiagnostics.note("note photo sync failed: \(error.localizedDescription)")
        }
    }
}
