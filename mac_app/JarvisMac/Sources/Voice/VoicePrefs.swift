import Foundation

/// The voice features' settings: "Hey Jarvis", Flow dictation and the note-taker.
/// Everything that listens is off until you turn it on.
extension Prefs {
    private static var store: UserDefaults { .standard }

    /// "Hey Jarvis" opens the voice panel (off by default).
    static var wakeWord: Bool {
        get { store.bool(forKey: "voice.wakeWord") }
        set { store.set(newValue, forKey: "voice.wakeWord") }
    }

    /// Flow dictation: hold the key to dictate anywhere (off by default).
    static var flowEnabled: Bool {
        get { store.bool(forKey: "flow.enabled") }
        set { store.set(newValue, forKey: "flow.enabled") }
    }

    static var flowKey: FlowKey {
        get { FlowKey.stored(store.string(forKey: "flow.key")) }
        set { store.set(newValue.rawValue, forKey: "flow.key") }
    }

    static var flowEngine: FlowEngine {
        get { FlowEngine(rawValue: store.string(forKey: "flow.engine") ?? "") ?? .automatic }
        set { store.set(newValue.rawValue, forKey: "flow.engine") }
    }

    /// Clean the words with a Jarvis model before pasting (off by default: the
    /// words then go to the server).
    static var flowCleanup: Bool {
        get { store.bool(forKey: "flow.cleanup") }
        set { store.set(newValue, forKey: "flow.cleanup") }
    }

    /// The style of the apps that have none of their own.
    static var flowDefaultStyle: FlowStyle {
        get { FlowStyle(rawValue: store.string(forKey: "flow.defaultStyle") ?? "") ?? .natural }
        set { store.set(newValue.rawValue, forKey: "flow.defaultStyle") }
    }

    /// Days the history is kept: 0 = not kept, -1 = forever.
    static var flowKeepDays: Int {
        get { store.object(forKey: "flow.keepDays") as? Int ?? FlowHistory.defaultKeepDays }
        set { store.set(newValue, forKey: "flow.keepDays") }
    }

    /// Upload finished call notes to the server so the phone sees them.
    static var notesUpload: Bool {
        get { store.object(forKey: "notes.upload") as? Bool ?? true }
        set { store.set(newValue, forKey: "notes.upload") }
    }

    /// Have a Jarvis model write the summary, key points and to-dos.
    static var notesSummarize: Bool {
        get { store.object(forKey: "notes.summarize") as? Bool ?? true }
        set { store.set(newValue, forKey: "notes.summarize") }
    }
}
