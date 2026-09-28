import Foundation
import Observation

/// One AI note recorded through the glasses.
struct GlassesNote: Codable, Identifiable, Equatable {
    /// The note's start, epoch ms — the same id the glasses put in photo names.
    var id: String
    var createdAt: Date
    var duration: TimeInterval
    var title: String
    /// The whole transcript, as the recognizer finally resolved it.
    var text: String
    /// Finished sentences with when they were said, for placing photos among them.
    var segments: [Segment]
    var photos: [Photo]
    /// Jarvis's summary (markdown), once it has been made.
    var summary: String?
    /// The Jarvis chat the summary came from, so the note can be followed up there.
    var chatSessionID: String?

    struct Segment: Codable, Equatable {
        var ms: Int
        var text: String
        /// Live translation records: what `text` was translated to.
        var translation: String? = nil
    }
    struct Photo: Codable, Equatable, Identifiable {
        /// "<note start ms>_<ms into the note>" for glasses photos.
        var id: String
        var ms: Int
        /// File name inside the note's folder.
        var file: String
        /// False while it is still the small Bluetooth preview.
        var fullSize: Bool
        var source: Source
    }
    enum Source: String, Codable { case glasses, phone }

    /// Transcript sentences and photos in the order they happened.
    enum Item: Identifiable {
        case text(GlassesNote.Segment), photo(GlassesNote.Photo)
        var id: String {
            switch self { case .text(let s): return "t\(s.ms)-\(s.text.hashValue)"; case .photo(let p): return "p" + p.id }
        }
    }
    var timeline: [Item] {
        let texts = segments.map { (ms: $0.ms, order: 0, item: Item.text($0)) }
        let pictures = photos.map { (ms: $0.ms, order: 1, item: Item.photo($0)) }
        return (texts + pictures).sorted { ($0.ms, $0.order) < ($1.ms, $1.order) }.map(\.item)
    }
}

/// Notes on this phone: one folder per note under Application Support/GlassesNotes,
/// holding note.json and the photos.
@MainActor
@Observable
final class GlassesNotesStore {
    static let shared = GlassesNotesStore()
    private(set) var notes: [GlassesNote] = []
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("GlassesNotes", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("GlassesNotes", isDirectory: true)
        load()
    }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func url(of photo: GlassesNote.Photo, in note: GlassesNote) -> URL { folder(note.id).appendingPathComponent(photo.file) }
    func note(_ id: String) -> GlassesNote? { notes.first { $0.id == id } }

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        notes = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("note.json")) else { return nil }
            return try? decoder.decode(GlassesNote.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ note: GlassesNote) throws {
        try FileManager.default.createDirectory(at: folder(note.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(note).write(to: folder(note.id).appendingPathComponent("note.json"), options: .atomic)
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note } else { notes.insert(note, at: 0) }
        notes.sort { $0.createdAt > $1.createdAt }
    }

    /// Writes a photo's bytes into the note's folder and returns the file name.
    func writePhoto(_ data: Data, named name: String, noteID: String) throws -> String {
        try FileManager.default.createDirectory(at: folder(noteID), withIntermediateDirectories: true)
        let file = name + ".jpg"
        try data.write(to: folder(noteID).appendingPathComponent(file), options: .atomic)
        return file
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
        notes.removeAll { $0.id == id }
    }
}
