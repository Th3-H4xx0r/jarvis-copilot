import Foundation
import UniformTypeIdentifiers

/// One folder in the vault. `id == "root"` is the vault itself.
struct VaultFolder: Identifiable, Hashable, Sendable {
    let id: String
    let parentID: String?
    let name: String
    let count: Int

    static let rootID = "root"

    init(id: String, parentID: String?, name: String, count: Int) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.count = count
    }

    init?(json o: [String: Any]) {
        guard let id = o["id"] as? String else { return nil }
        self.id = id
        parentID = o["parent_id"] as? String
        name = o["name"] as? String ?? "Folder"
        count = (o["count"] as? NSNumber)?.intValue ?? 0
    }
}

/// A link's preview, as the server fetched it when the link was saved.
struct VaultLink: Hashable, Sendable {
    let url: String
    let siteName: String
    let domain: String
    /// "video", "article" or "page".
    let kind: String
    let author: String
    let description: String
    let hasFavicon: Bool

    var isVideo: Bool { kind == "video" }

    init?(json o: [String: Any]?) {
        guard let o, let url = o["url"] as? String else { return nil }
        self.url = url
        siteName = o["site_name"] as? String ?? ""
        domain = o["domain"] as? String ?? (URL(string: url)?.host ?? "")
        kind = o["kind"] as? String ?? "page"
        author = o["author"] as? String ?? ""
        description = o["description"] as? String ?? ""
        hasFavicon = o["has_favicon"] as? Bool ?? false
    }
}

/// One thing in the vault: a note, link, photo, video, PDF or any file.
struct VaultItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case note, link, image, video, pdf, file }

    let id: String
    let parentID: String
    let kind: Kind
    let title: String
    let created: Date
    let updated: Date
    let size: Int64
    let mime: String
    let filename: String
    let hasThumb: Bool
    let thumbAspect: CGFloat?
    let duration: Double?
    let pages: Int?
    let snippet: String
    let link: VaultLink?
    /// Link items: his own note under the preview.
    let note: String
    /// Notes: the full text (only on `GET /items/<id>`).
    let body: String?
    /// Search results: where it lives ("Travel › Japan 2026").
    let path: String?
    let previewStatus: String?
    /// Notes: the title as he typed it (maybe empty); `title` may be derived from the first line.
    let rawTitle: String?

    init?(json o: [String: Any]) {
        guard let id = o["id"] as? String,
              let kind = Kind(rawValue: o["kind"] as? String ?? "") else { return nil }
        self.id = id
        self.kind = kind
        parentID = o["parent_id"] as? String ?? VaultFolder.rootID
        title = o["title"] as? String ?? ""
        created = Date(timeIntervalSince1970: (o["created"] as? NSNumber)?.doubleValue ?? 0)
        updated = Date(timeIntervalSince1970: (o["updated"] as? NSNumber)?.doubleValue ?? 0)
        size = (o["size"] as? NSNumber)?.int64Value ?? 0
        mime = o["mime"] as? String ?? ""
        filename = o["filename"] as? String ?? ""
        hasThumb = o["has_thumb"] as? Bool ?? false
        if let w = (o["thumb_w"] as? NSNumber)?.doubleValue, let h = (o["thumb_h"] as? NSNumber)?.doubleValue,
           w > 0, h > 0 {
            thumbAspect = w / h
        } else {
            thumbAspect = nil
        }
        duration = (o["duration_s"] as? NSNumber)?.doubleValue
        pages = (o["pages"] as? NSNumber)?.intValue
        snippet = o["snippet"] as? String ?? ""
        link = VaultLink(json: o["link"] as? [String: Any])
        note = o["note"] as? String ?? ""
        body = o["body"] as? String
        path = (o["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        rawTitle = o["raw_title"] as? String
        previewStatus = o["preview_status"] as? String
    }

    /// Video links get the wide card, like a search result's video.
    var isWide: Bool { kind == .link && (link?.isVideo ?? false) }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !filename.isEmpty { return filename }
        if let link { return link.domain }
        return kind == .note ? "Untitled note" : "Untitled"
    }

    /// The line under the title on a card.
    var metaLine: String {
        switch kind {
        case .link:
            guard let link else { return "Link" }
            let site = link.siteName.isEmpty ? link.domain : link.siteName
            return link.author.isEmpty ? site : "\(site) · \(link.author)"
        case .note:
            return "Note · " + VaultFormat.day(updated)
        case .pdf:
            var parts = ["PDF"]
            if let pages { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
            parts.append(VaultFormat.bytes(size))
            return parts.joined(separator: " · ")
        case .image:
            return "Photo · " + VaultFormat.bytes(size)
        case .video:
            return "Video · " + VaultFormat.bytes(size)
        case .file:
            let ext = (filename as NSString).pathExtension.uppercased()
            return [ext.isEmpty ? "File" : ext, VaultFormat.bytes(size)].joined(separator: " · ")
        }
    }

    var symbol: String {
        switch kind {
        case .note: return "note.text"
        case .link: return "link"
        case .image: return "photo"
        case .video: return "video"
        case .pdf: return "doc.richtext"
        case .file: return "doc"
        }
    }

    var fileExtension: String {
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty { return ext }
        return UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
    }
}

enum VaultFormat {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMMd" : "MMMdyyyy")
        return f.string(from: date)
    }
}

/// What a vault call can fail with that the screens treat specially.
enum VaultError: LocalizedError, Equatable {
    /// The session token is gone (expired, locked elsewhere): show the lock screen.
    case locked
    case server(String)
    /// Any other refusal, with its status so callers can tell "try again" (5xx) from "no" (4xx).
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .locked: return "The vault locked."
        case .server(let m): return m
        case .http(_, let m): return m
        }
    }

    /// Worth another try: the server or the tunnel hiccuped.
    var isTransient: Bool {
        if case .http(let status, _) = self { return status >= 500 || status == 408 || status == 429 }
        return false
    }
}
