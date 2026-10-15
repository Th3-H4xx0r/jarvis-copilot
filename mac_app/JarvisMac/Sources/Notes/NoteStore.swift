import Foundation

/// The notes on this Mac: ~/Library/Application Support/Jarvis/Notes/<id>/note.json.
/// Only text: the call's audio is held in memory just until each stretch is
/// transcribed (NoteAudio.swift) and is never written to disk.
enum NoteStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Jarvis/Notes", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder = JSONDecoder()

    static func save(_ note: Note) {
        do {
            let dir = folder(for: note.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoder.encode(note).write(to: dir.appendingPathComponent("note.json"), options: .atomic)
        } catch {
            NSLog("Jarvis notes: could not save a note: \(error.localizedDescription)")
        }
    }

    /// Every note, newest first; one that was cut off by a quit comes back failed.
    static func loadAll() -> [Note] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [Note] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("note.json")),
                  let note = try? decoder.decode(Note.self, from: data) else { continue }
            let fixed = recovered(note)
            if fixed != note { save(fixed) }
            out.append(fixed)
        }
        return out.sorted { $0.start > $1.start }
    }

    /// Jarvis quit while recording or transcribing: the lines written live are
    /// kept (the note is ready, and says it stops early); a note with none is
    /// marked failed.
    static func recovered(_ note: Note) -> Note {
        guard note.status == .recording || note.status == .transcribing else { return note }
        var n = note
        let start = note.start
        n.end = note.end ?? note.lines.last.map { start.addingTimeInterval($0.end) } ?? start
        n.uploaded = false
        if n.lines.isEmpty {
            n.status = .failed
            n.error = String(localized: "Jarvis quit before anything was transcribed.")
        } else {
            n.status = .ready
            let built = NoteBuilder.finalize(n.lines)
            n.speakers = built.speakers
            n.lines = built.lines
            n.error = String(localized: "Jarvis quit during the call: the transcript stops there.")
        }
        return n
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }
}
