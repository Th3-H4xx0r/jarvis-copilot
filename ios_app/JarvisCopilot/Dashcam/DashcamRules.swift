import Foundation

/// Which clips the phone pulls off the camera on its own. Events, parking clips and photos
/// always come; normal driving footage only by rule (4K+2.5K is 15–20 GB an hour).
/// The values live on the server (`/api/dashcam/settings`) so Jarvis can change them too.
struct DashcamRules: Equatable, Sendable {
    enum Normal: String, CaseIterable, Sendable {
        case off, front, all
        var label: String {
            switch self {
            case .off: return "Don't pull"
            case .front: return "Front camera"
            case .all: return "Front + rear"
            }
        }
    }
    enum When: String, CaseIterable, Sendable {
        case any, parked
        var label: String { self == .any ? "Any time" : "Only when parked" }
    }

    var normal: Normal = .off
    var normalWhen: When = .any
    /// Phone storage the normal footage may use. Events and photos are not counted against it.
    var phoneCapGB: Int = 20
    var keepOnPhone: Bool = false

    init() {}

    init(json: [String: Any]) {
        normal = Normal(rawValue: json["normal"] as? String ?? "") ?? .off
        normalWhen = When(rawValue: json["normal_when"] as? String ?? "") ?? .any
        if let cap = (json["phone_cap_gb"] as? NSNumber)?.intValue { phoneCapGB = min(512, max(1, cap)) }
        keepOnPhone = (json["keep_on_phone"] as? NSNumber)?.boolValue ?? false
    }

    var json: [String: Any] {
        ["normal": normal.rawValue, "normal_when": normalWhen.rawValue, "phone_cap_gb": phoneCapGB, "keep_on_phone": keepOnPhone]
    }

    var phoneCapBytes: Int64 { Int64(phoneCapGB) * 1_073_741_824 }

    /// Whether to download `file` now.
    /// - Parameters:
    ///   - parked: the phone hasn't been in a moving car for a few minutes.
    ///   - normalBytesOnPhone: normal footage already on the phone (counts toward the cap).
    func wants(_ file: DashcamFile, parked: Bool, normalBytesOnPhone: Int64) -> Bool {
        switch file.kind {
        case .event, .parking, .photo:
            return true
        case .normal:
            switch normal {
            case .off: return false
            case .front: guard file.lens == .front else { return false }
            case .all: break
            }
            if normalWhen == .parked && !parked { return false }
            return normalBytesOnPhone + file.size <= phoneCapBytes
        }
    }

    /// Download order: what matters most first, newest first within a kind.
    static func order(_ files: [DashcamFile]) -> [DashcamFile] {
        func rank(_ k: DashcamClipKind) -> Int {
            switch k { case .event: return 0; case .parking: return 1; case .photo: return 2; case .normal: return 3 }
        }
        return files.sorted { a, b in
            rank(a.kind) != rank(b.kind) ? rank(a.kind) < rank(b.kind) : a.start > b.start
        }
    }
}

/// Clips on the phone: `Documents/Dashcam/<camera>/<file name>`. Downloads land here; uploads
/// read from here; the library plays from here first.
struct DashcamStorage: Sendable {
    let root: URL

    static var standard: DashcamStorage {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return DashcamStorage(root: docs.appendingPathComponent("Dashcam", isDirectory: true))
    }

    func folder(camera: String) -> URL {
        let safe = camera.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return root.appendingPathComponent(String(safe).isEmpty ? "camera" : String(safe), isDirectory: true)
    }

    /// Kind subfolders keep a normal clip and an event clip with the same name apart.
    func localURL(camera: String, file: DashcamFile) -> URL {
        folder(camera: camera).appendingPathComponent(file.kind.rawValue, isDirectory: true)
            .appendingPathComponent(file.name)
    }

    /// A download only lands at its final path once it finished, so a file there is complete. The
    /// size check allows for Viidure listing sizes in whole KB (rounded up).
    func exists(camera: String, file: DashcamFile) -> Bool {
        guard let size = localSize(camera: camera, file: file) else { return false }
        return size > 0 && size >= file.size - 1024
    }

    func localSize(camera: String, file: DashcamFile) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: localURL(camera: camera, file: file).path)[.size] as? NSNumber)?.int64Value
    }

    /// Bytes of normal footage on the phone (what the cap measures).
    func normalBytes(camera: String) -> Int64 {
        let dir = folder(camera: camera).appendingPathComponent(DashcamClipKind.normal.rawValue, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Frees room for `needed` bytes of normal footage by deleting the oldest normal clips the
    /// server already has everywhere. Events, parking clips, photos and anything not yet
    /// uploaded are never touched. Returns the deleted file names.
    @discardableResult
    func evict(camera: String, needed: Int64, cap: Int64, uploadedNames: Set<String>) -> [String] {
        let dir = folder(camera: camera).appendingPathComponent(DashcamClipKind.normal.rawValue, isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
            .map { url -> (URL, Int64, Date) in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return (url, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.2 < $1.2 }
        var used = items.reduce(0) { $0 + $1.1 }
        var removed: [String] = []
        for (url, size, _) in items where used + needed > cap {
            guard uploadedNames.contains(url.lastPathComponent) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                used -= size
                removed.append(url.lastPathComponent)
            }
        }
        return removed
    }
}
