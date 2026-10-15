import AppKit
import AVFoundation
import Observation
import Speech
import UniformTypeIdentifiers

/// The note-taker: records a call — your microphone and what the Mac plays (the
/// other side, through a Core Audio process tap) — and writes a live transcript
/// on this Mac, "You" for the microphone and "Them" for the Mac's sound. When you
/// stop, the transcript is finished (your microphone's echo of the other side
/// removed), saved here and uploaded to the server (`/api/agent-notes`), where a
/// Jarvis model writes the title, summary, key points and to-dos; the phone sees
/// the note there. Audio is never written to disk: each stretch is held in memory
/// only until it is transcribed. No bot joins the call — tell the other people
/// it is recorded.
/// After coucou's NoteTaker (github.com/Louis-CFM/coucou, MIT).
@MainActor
@Observable
final class NoteTaker {
    static let shared = NoteTaker()

    /// Newest first.
    private(set) var notes: [Note] = []
    private(set) var recordingID: UUID?
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    /// The Mac's sound is being recorded too (false: microphone only).
    private(set) var systemAudio = false
    private(set) var starting = false
    var startError: String?
    /// Notes being uploaded or waiting for their summary.
    private(set) var syncing: Set<UUID> = []

    var isRecording: Bool { recordingID != nil }
    var recording: Note? { recordingID.flatMap(note) }

    @ObservationIgnored private var mic: MicCapture?
    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var micChannel: ChannelBuffer?
    @ObservationIgnored private var systemChannel: ChannelBuffer?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var lastApp: String?
    @ObservationIgnored private var loaded = false

    private init() {}

    // MARK: launch

    func load() {
        guard !loaded else { return }
        loaded = true
        notes = NoteStore.loadAll()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            let name = app.localizedName
            MainActor.assumeIsolated { NoteTaker.shared.lastApp = name }
        }
        // Notes written while the server was away go up once jc-client is there.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            self.sync()
        }
    }

    /// Jarvis is quitting: the call stops and what was transcribed is kept.
    func shutdown() {
        guard let id = recordingID, var note = note(id) else { return }
        liveTask?.cancel()
        mic?.stop()
        tap?.stop()
        note.end = Date()
        note.status = .ready
        let built = NoteBuilder.finalize(note.lines)
        note.speakers = built.speakers
        note.lines = built.lines
        note.error = note.lines.isEmpty ? nil : String(localized: "Jarvis quit during the call: the transcript stops there.")
        replace(note)
        recordingID = nil
    }

    // MARK: recording

    func toggle() {
        if isRecording { stop() } else { Task { await self.start() } }
    }

    func start() async {
        guard recordingID == nil, !starting else { return }
        starting = true
        defer { starting = false }
        startError = nil
        if let failure = await SpeechPermissions.ensure() {
            startError = failure.message
            return
        }
        guard let recognizer = ClassicDictation.recognizer() else {
            startError = String(localized: "On-device speech recognition isn't installed for your language. Turn on Dictation in System Settings → Keyboard.")
            return
        }
        let now = Date()
        var note = Note(title: String(localized: "Call \(now.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"),
                        start: now)
        let front = NSWorkspace.shared.frontmostApplication
        note.app = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastApp : front?.localizedName

        let micChannel = ChannelBuffer()
        let mic = MicCapture()
        guard mic.start(sink: { micChannel.append($0) }) else {
            startError = String(localized: "The microphone didn't start.")
            return
        }
        let systemChannel = ChannelBuffer()
        let tap = SystemAudioTap()
        do {
            try tap.start(sink: { systemChannel.append($0) })
            self.tap = tap
            self.systemChannel = systemChannel
            systemAudio = true
        } catch {
            // Without the Mac's sound the call is noted from the microphone alone.
            NSLog("Jarvis notes: system audio unavailable: \(error.localizedDescription)")
            self.tap = nil
            self.systemChannel = nil
            systemAudio = false
        }
        self.mic = mic
        self.micChannel = micChannel
        note.speakers = [NoteSpeaker(id: NoteBuilder.meID, name: NoteBuilder.meName, isMe: true)]
            + (systemAudio ? [NoteSpeaker(id: NoteBuilder.themID, name: NoteBuilder.themName)] : [])
        notes.insert(note, at: 0)
        NoteStore.save(note)
        recordingID = note.id
        NotificationCenter.default.post(name: .jarvisNoteRecordingChanged, object: true)
        Sounds.play(.started)
        startLiveLoop(note.id, recognizer: recognizer)
    }

    func stop() {
        guard let id = recordingID, var note = note(id) else { return }
        let live = liveTask
        live?.cancel()
        mic?.stop()
        tap?.stop()
        let micChannel = self.micChannel, systemChannel = self.systemChannel
        let recognizer = ClassicDictation.recognizer()
        mic = nil
        tap = nil
        self.micChannel = nil
        self.systemChannel = nil
        micLevel = 0
        systemLevel = 0
        note.end = Date()
        note.status = .transcribing
        replace(note)
        recordingID = nil
        NotificationCenter.default.post(name: .jarvisNoteRecordingChanged, object: false)
        Sounds.play(.finished)
        Task { @MainActor in
            await live?.value
            // The last words of each side, then the finished transcript.
            for (channel, speaker) in [(micChannel, NoteBuilder.meID), (systemChannel, NoteBuilder.themID)] {
                if let channel, let recognizer {
                    await self.transcribeChunk(of: channel, as: speaker, into: id, force: true, with: recognizer)
                }
            }
            guard var current = self.note(id) else { return }
            let built = NoteBuilder.finalize(current.lines)
            current.speakers = built.speakers
            current.lines = built.lines
            current.status = current.lines.isEmpty ? .failed : .ready
            current.error = current.lines.isEmpty ? String(localized: "Nothing was heard during the call.") : nil
            current.uploaded = false
            self.replace(current)
            await self.upload(id)
        }
    }

    /// Every second while recording: the levels, and the stretches that end on a
    /// pause go to the recognizer for the live transcript.
    private func startLiveLoop(_ id: UUID, recognizer: SFSpeechRecognizer) {
        liveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.recordingID == id else { return }
                self.micLevel = self.micChannel?.level ?? 0
                self.systemLevel = self.systemChannel?.level ?? 0
                for (channel, speaker) in [(self.micChannel, NoteBuilder.meID), (self.systemChannel, NoteBuilder.themID)] {
                    if let channel {
                        await self.transcribeChunk(of: channel, as: speaker, into: id, force: false, with: recognizer)
                    }
                }
            }
        }
    }

    private func transcribeChunk(of channel: ChannelBuffer, as speaker: String, into id: UUID, force: Bool,
                                 with recognizer: SFSpeechRecognizer) async {
        guard let chunk = channel.takeChunk(force: force) else { return }
        let words = await ChunkTranscriber.transcribe(chunk.samples, with: recognizer)
        guard !words.isEmpty, var note = note(id) else { return }
        for line in NoteBuilder.lines(speaker: speaker, words: NoteBuilder.offset(words, by: chunk.start)) {
            NoteBuilder.insert(line, into: &note.lines)
        }
        replace(note)
    }

    // MARK: server

    /// Uploads every finished note the server doesn't have yet.
    func sync() {
        for note in notes where note.status == .ready && !note.uploaded {
            Task { await self.upload(note.id) }
        }
    }

    func upload(_ id: UUID) async {
        guard Prefs.notesUpload, let origin = AppModel.shared.apiOrigin,
              let note = note(id), note.status == .ready, !syncing.contains(id) else { return }
        syncing.insert(id)
        defer { syncing.remove(id) }
        var body = note.serverJSON
        body["summarize"] = Prefs.notesSummarize && (note.summary ?? "").isEmpty
        guard let reply = await Self.call("POST", origin, "/api/agent-notes", body: body) as? [String: Any],
              let server = reply["note"] as? [String: Any], var current = self.note(id) else { return }
        current.absorb(server: server)
        current.uploaded = true
        replace(current)
        if current.summaryStatus == .pending { await waitForSummary(id, origin: origin) }
    }

    /// The summary is written on the server in the background: check every few
    /// seconds for up to three minutes.
    private func waitForSummary(_ id: UUID, origin: String) async {
        for _ in 0..<45 {
            try? await Task.sleep(for: .seconds(4))
            guard let json = await Self.call("GET", origin, "/api/agent-notes/\(id.uuidString)") as? [String: Any],
                  var current = note(id) else { continue }
            current.absorb(server: json)
            replace(current)
            if current.summaryStatus != .pending { return }
        }
    }

    func summarizeAgain(_ id: UUID) {
        guard let origin = AppModel.shared.apiOrigin else { return }
        Task { @MainActor in
            if !(self.note(id)?.uploaded ?? false) { await self.upload(id) }
            guard let reply = await Self.call("POST", origin, "/api/agent-notes/\(id.uuidString)/summarize", body: [:])
                    as? [String: Any], let server = reply["note"] as? [String: Any], var current = self.note(id) else { return }
            current.absorb(server: server)
            self.replace(current)
            self.syncing.insert(id)
            await self.waitForSummary(id, origin: origin)
            self.syncing.remove(id)
        }
    }

    nonisolated static func call(_ method: String, _ origin: String, _ path: String,
                                 body: [String: Any]? = nil) async -> Any? {
        guard let url = URL(string: origin + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: result.0)
    }

    // MARK: editing

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    func rename(_ id: UUID, title: String) {
        guard var note = note(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != note.title else { return }
        note.title = t
        note.titleEdited = true
        changed(note)
    }

    func toggleTodo(_ id: UUID, todo: UUID) {
        guard var note = note(id), let i = note.todos.firstIndex(where: { $0.id == todo }) else { return }
        note.todos[i].done.toggle()
        changed(note)
    }

    func delete(_ id: UUID) {
        guard recordingID != id else { return }
        notes.removeAll { $0.id == id }
        NoteStore.delete(id)
        if let origin = AppModel.shared.apiOrigin {
            Task { _ = await Self.call("DELETE", origin, "/api/agent-notes/\(id.uuidString)") }
        }
    }

    func markdown(_ note: Note) -> String { NoteBuilder.markdown(note) }

    func copyMarkdown(_ note: Note) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(note), forType: .string)
    }

    func export(_ note: Note) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(note).write(to: url, atomically: true, encoding: .utf8)
    }

    /// A local edit: saved, then sent up (the server keeps its summary).
    private func changed(_ note: Note) {
        var n = note
        n.uploaded = false
        replace(n)
        Task { await self.upload(n.id) }
    }

    private func replace(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note } else { notes.insert(note, at: 0) }
        NoteStore.save(note)
    }
}
