import Foundation

/// Glasses features that live on their own screens — AI Notes, live translation, live
/// captions, Talk and "Use Jarvis for Glasses AI" — as tools. Each does what the
/// screen's own control does.
@MainActor
protocol GlassesScreenControls: AnyObject {
    /// `start`, `stop` (saves) or `summarise` (the newest note).
    func note(_ action: String) async throws -> [String: Any]
    func translate(on: Bool, from: String?, to: String?) async throws -> [String: Any]
    func captions(on: Bool) -> [String: Any]
    func talk() async throws -> [String: Any]
    func jarvisAI(on: Bool) async -> [String: Any]
    /// What one of these is doing now, as its screen shows it (a note recording, translation
    /// running, captions or Glasses AI on); nil mid-change or for anything else.
    func state(_ skill: String) -> CommandLiveState?
}

extension GlassesScreenControls {
    func state(_ skill: String) -> CommandLiveState? { nil }
}

/// The real screens' stores.
@MainActor
final class LiveGlassesScreenControls: GlassesScreenControls {
    private let recorder: @MainActor () -> GlassesNoteRecorder
    private let notes: @MainActor () -> GlassesNotesStore
    private let translator: @MainActor () -> GlassesTranslator
    private let captionsBridge: @MainActor () -> LiveLensBridge
    private let ai: @MainActor () -> InmoAIChannel

    init(recorder: @escaping @MainActor () -> GlassesNoteRecorder = { .shared },
         notes: @escaping @MainActor () -> GlassesNotesStore = { .shared },
         translator: @escaping @MainActor () -> GlassesTranslator = { .shared },
         captions: @escaping @MainActor () -> LiveLensBridge = { .shared },
         ai: @escaping @MainActor () -> InmoAIChannel = { .shared }) {
        self.recorder = recorder
        self.notes = notes
        self.translator = translator
        self.captionsBridge = captions
        self.ai = ai
    }

    /// AI Notes: "Start a note", the recording screen's Save, and a note's "Summarise with Jarvis".
    func note(_ action: String) async throws -> [String: Any] {
        let recorder = recorder()
        switch action {
        case "start":
            if recorder.phase == .recording { return ["state": "recording", "note_id": recorder.noteID as Any? ?? NSNull()] }
            guard recorder.phase == .idle else { throw InmoProtocolError.unavailable("A note is still \(recorder.phase == .saving ? "saving" : "starting"); try again in a moment") }
            await recorder.start()
            guard recorder.phase == .recording else { throw InmoProtocolError.unavailable(recorder.problem ?? "The note didn't start") }
            return ["state": "recording", "note_id": recorder.noteID as Any? ?? NSNull()]
        case "stop":
            guard recorder.phase == .recording, let id = recorder.noteID else { throw InmoProtocolError.unavailable("No note is recording") }
            await recorder.save()
            guard let saved = notes().note(id) else { throw InmoProtocolError.unavailable(recorder.problem ?? "Couldn't save the note") }
            return ["state": "saved", "note_id": id, "title": saved.title, "words": saved.text.split(separator: " ").count,
                    "summary": "Jarvis is writing the title and summary"]
        default:
            let store = notes()
            guard let newest = store.notes.first else { throw InmoProtocolError.unavailable("There are no AI notes yet") }
            if let summary = newest.summary { return ["state": "summarised", "note_id": newest.id, "title": newest.title, "summary": summary] }
            guard !newest.text.isEmpty else { throw InmoProtocolError.unavailable("The newest note has no words to summarise") }
            await GlassesNoteFinisher.summarize(noteID: newest.id, store: store)
            guard let done = store.note(newest.id), let summary = done.summary else { throw InmoProtocolError.unavailable("Jarvis couldn't summarise the note") }
            return ["state": "summarised", "note_id": done.id, "title": done.title, "summary": summary]
        }
    }

    /// Translate: the language pickers, "Start live translation" and Stop. New languages
    /// while it runs restart it on the new pair.
    func translate(on: Bool, from: String?, to: String?) async throws -> [String: Any] {
        let translator = translator()
        guard on else {
            let wasRunning = translator.phase == .running
            await translator.stop()
            return ["state": "stopped", "was_running": wasRunning]
        }
        let source = from ?? translator.source, target = to ?? translator.target
        guard source != target else { throw DeviceError.badArgument("from and to must be different languages") }
        let changed = source != translator.source || target != translator.target
        if translator.phase == .running, !changed { return running(translator) }
        if translator.phase == .running { await translator.stop() }
        guard translator.phase == .idle else { throw InmoProtocolError.unavailable("Translation is still starting or stopping; try again in a moment") }
        translator.setLanguages(source: source, target: target)
        await translator.start()
        guard translator.phase == .running else { throw InmoProtocolError.unavailable(translator.problem ?? "Translation didn't start") }
        return running(translator)
    }

    private func running(_ translator: GlassesTranslator) -> [String: Any] {
        ["state": "running", "from": translator.source, "to": translator.target, "engine": translator.engineInUse.rawValue]
    }

    /// Live captions: "Show on glasses".
    func captions(on: Bool) -> [String: Any] {
        let bridge = captionsBridge()
        bridge.enabled = on
        return ["on": bridge.enabled, "status": LiveCaptionsSettingsView.describe(bridge.status)]
    }

    /// The glasses page's "Talk to Jarvis" (it also turns on Jarvis for Glasses AI).
    func talk() async throws -> [String: Any] {
        let channel = ai()
        await channel.startFromPhone()
        guard channel.hasOpenChat else { throw InmoProtocolError.unavailable(channel.status) }
        return ["state": "listening", "status": channel.status]
    }

    /// "Use Jarvis for Glasses AI".
    func jarvisAI(on: Bool) async -> [String: Any] {
        let channel = ai()
        await channel.setEnabled(on)
        return ["on": channel.enabled, "status": channel.status]
    }

    func state(_ skill: String) -> CommandLiveState? {
        switch skill {
        case "glasses_notes":
            switch recorder().phase {
            case .recording: return CommandLiveState(on: true)
            case .idle: return CommandLiveState(on: false)
            case .starting, .saving: return nil
            }
        case "glasses_translate":
            switch translator().phase {
            case .running: return CommandLiveState(on: true)
            case .idle: return CommandLiveState(on: false)
            case .starting, .stopping: return nil
            }
        case "glasses_captions": return CommandLiveState(on: captionsBridge().enabled)
        case "glasses_jarvis_ai": return CommandLiveState(on: ai().enabled)
        default: return nil
        }
    }
}
