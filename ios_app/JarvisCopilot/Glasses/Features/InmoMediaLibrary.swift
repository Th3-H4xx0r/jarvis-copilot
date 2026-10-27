import Foundation

/// What the gallery shows. A GO3 video is three files on the glasses
/// (`INMOVID_<ms>.mp4` picture, `.opus` sound, `.gcsv` motion log) but one tile.
enum InmoGalleryKind: String, Codable { case photo, video }

/// One photo or video as the glasses list it right now.
struct InmoGalleryItem: Identifiable, Equatable {
    let key: String
    let kind: InmoGalleryKind
    let capturedAt: Date
    let parts: [InmoMediaItem]
    var id: String { key }
    /// The `.jpg` of a photo, the `.mp4` of a video.
    var picture: InmoMediaItem? {
        parts.first { ["jpg", "jpeg", "mp4"].contains(InmoMediaGrouping.ext($0.name)) }
    }
    /// A video's separate sound file.
    var sound: InmoMediaItem? { kind == .video ? parts.first { InmoMediaGrouping.ext($0.name) == "opus" } : nil }
}

/// What Jarvis remembers about an item, so saved ones stay in the gallery with the glasses off
/// and are never saved twice.
struct InmoGalleryRecord: Codable, Equatable {
    let key: String
    let kind: InmoGalleryKind
    let capturedAt: Date
    /// Remote file name → size.
    var parts: [String: Int]
    var savedAt: Date?
    var withoutSound = false
    var duration: Double?
    /// File name under `thumbs/`.
    var thumb: String?
}

/// One gallery tile: the live item, the record, or both.
struct InmoGalleryEntry: Identifiable, Equatable {
    let key: String
    let kind: InmoGalleryKind
    let capturedAt: Date
    /// Nil once the file is no longer on the glasses.
    let item: InmoGalleryItem?
    let record: InmoGalleryRecord?
    var id: String { key }
    var saved: Bool { record?.savedAt != nil }
    var size: Int { item?.parts.reduce(0) { $0 + $1.size } ?? record?.parts.values.reduce(0, +) ?? 0 }
}

enum InmoMediaGrouping {
    static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

    /// `INMOIMG_1790453383660.jpg` → the capture moment (the number is epoch milliseconds).
    static func capturedAt(_ name: String) -> Date? {
        let base = (name as NSString).deletingPathExtension
        guard let underscore = base.lastIndex(of: "_"),
              let ms = Int64(base[base.index(after: underscore)...]), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// Photos and videos for the gallery; audio recordings, sound files with no picture and anything
    /// unrecognised go to `other`.
    static func group(_ items: [InmoMediaItem]) -> (gallery: [InmoGalleryItem], other: [InmoMediaItem]) {
        var gallery: [InmoGalleryItem] = []
        var other: [InmoMediaItem] = []
        var videos: [String: [InmoMediaItem]] = [:]
        for item in items {
            let base = (item.name as NSString).deletingPathExtension
            let ext = ext(item.name)
            if base.hasPrefix("INMOIMG_"), ["jpg", "jpeg"].contains(ext), let date = capturedAt(item.name) {
                gallery.append(InmoGalleryItem(key: "\(base)-\(item.size)", kind: .photo, capturedAt: date, parts: [item]))
            } else if base.hasPrefix("INMOVID_"), ["mp4", "opus", "gcsv"].contains(ext), capturedAt(item.name) != nil {
                videos[base, default: []].append(item)
            } else {
                other.append(item)
            }
        }
        for (base, parts) in videos {
            guard let mp4 = parts.first(where: { ext($0.name) == "mp4" }), let date = capturedAt(mp4.name) else {
                other += parts; continue
            }
            gallery.append(InmoGalleryItem(key: "\(base)-\(mp4.size)", kind: .video, capturedAt: date,
                                           parts: parts.sorted { $0.name < $1.name }))
        }
        return (gallery.sorted { $0.capturedAt > $1.capturedAt }, other.sorted { $0.name < $1.name })
    }
}

/// The lasting gallery record: `library.json` plus `thumbs/` under the media folder.
final class InmoMediaLibrary {
    let directory: URL
    private(set) var records: [String: InmoGalleryRecord] = [:]
    var thumbsDirectory: URL { directory.appendingPathComponent("thumbs", isDirectory: true) }
    private var file: URL { directory.appendingPathComponent("library.json") }

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: file),
           let list = try? Self.decoder.decode([InmoGalleryRecord].self, from: data) {
            records = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        }
    }

    static var standard: InmoMediaLibrary {
        let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return InmoMediaLibrary(directory: root.appendingPathComponent("INMOMedia", isDirectory: true))
    }

    func isSaved(_ key: String) -> Bool { records[key]?.savedAt != nil }

    func record(_ record: InmoGalleryRecord) throws {
        records[record.key] = record
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let list = records.values.sorted { $0.capturedAt > $1.capturedAt }
        try Self.encoder.encode(list).write(to: file, options: .atomic)
    }

    func thumbnailURL(_ record: InmoGalleryRecord?) -> URL? {
        record?.thumb.map { thumbsDirectory.appendingPathComponent($0) }
    }

    /// Live items and remembered ones together, newest first.
    static func merge(live: [InmoGalleryItem], records: [String: InmoGalleryRecord]) -> [InmoGalleryEntry] {
        var entries = live.map { InmoGalleryEntry(key: $0.key, kind: $0.kind, capturedAt: $0.capturedAt, item: $0, record: records[$0.key]) }
        let liveKeys = Set(live.map(\.key))
        for record in records.values where !liveKeys.contains(record.key) {
            entries.append(InmoGalleryEntry(key: record.key, kind: record.kind, capturedAt: record.capturedAt, item: nil, record: record))
        }
        return entries.sorted { $0.capturedAt != $1.capturedAt ? $0.capturedAt > $1.capturedAt : $0.key < $1.key }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
