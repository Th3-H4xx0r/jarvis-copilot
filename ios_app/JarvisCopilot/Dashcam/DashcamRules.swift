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
        case any, parked, charging
        var label: String {
            switch self {
            case .any: return "Any time"
            case .parked: return "Parked only"
            case .charging: return "Charging only"
            }
        }
        /// Whether this rule lets the work go now.
        func allows(parked: Bool, charging: Bool) -> Bool {
            switch self {
            case .any: return true
            case .parked: return parked
            case .charging: return charging
            }
        }
    }
    /// What may go to the cloud over mobile data (LTE — also the way out while on the camera's Wi‑Fi).
    enum UploadData: String, CaseIterable, Sendable {
        case all, events, never
        /// A word or two: the setting's value shows on one line (the long one wrapped into the row below).
        var label: String {
            switch self {
            case .all: return "Everything"
            case .events: return "Events only"
            case .never: return "Nothing"
            }
        }
        /// What the value means, for the card's footer.
        var detail: String {
            switch self {
            case .all: return "Everything uploads over mobile data too."
            case .events: return "Events upload over mobile data at once; the rest waits for Wi‑Fi or the charger."
            case .never: return "Nothing uploads over mobile data: Wi‑Fi only."
            }
        }
    }

    var normal: Normal = .off
    var normalWhen: When = .any
    /// Phone storage normal footage may use, together with the MP4 copies made for Drive and the player.
    /// Events and photos are not counted against it (they always come).
    var phoneCapGB: Int = 20
    var keepOnPhone: Bool = false
    /// Cloud uploads: on/off, what may use mobile data, and whether to wait until parked.
    var upload: Bool = true
    var uploadData: UploadData = .all
    var uploadWhen: When = .any

    init() {}

    init(json: [String: Any]) {
        normal = Normal(rawValue: json["normal"] as? String ?? "") ?? .off
        normalWhen = When(rawValue: json["normal_when"] as? String ?? "") ?? .any
        if let cap = (json["phone_cap_gb"] as? NSNumber)?.intValue { phoneCapGB = min(512, max(1, cap)) }
        keepOnPhone = (json["keep_on_phone"] as? NSNumber)?.boolValue ?? false
        upload = (json["upload"] as? NSNumber)?.boolValue ?? true
        uploadData = UploadData(rawValue: json["upload_data"] as? String ?? "") ?? .all
        uploadWhen = When(rawValue: json["upload_when"] as? String ?? "") ?? .any
    }

    /// Whether a clip of `kind` may go up now. `charging`: the phone is on power, so the radio's cost
    /// isn't his battery — normal footage held off mobile data goes then too (an evening's drive was
    /// 11 GB over LTE, most of a day's charge).
    func mayUpload(_ kind: DashcamClipKind, metered: Bool, parked: Bool, charging: Bool = false) -> Bool {
        guard upload, uploadWhen.allows(parked: parked, charging: charging) else { return false }
        guard metered else { return true }
        switch uploadData {
        case .all: return true
        case .events: return kind != .normal || charging
        case .never: return false
        }
    }

    var json: [String: Any] {
        ["normal": normal.rawValue, "normal_when": normalWhen.rawValue, "phone_cap_gb": phoneCapGB, "keep_on_phone": keepOnPhone,
         "upload": upload, "upload_data": uploadData.rawValue, "upload_when": uploadWhen.rawValue]
    }

    var phoneCapBytes: Int64 { Int64(phoneCapGB) * 1_073_741_824 }

    /// Whether to download `file` now.
    /// - Parameters:
    ///   - parked: the phone hasn't been in a moving car for a few minutes.
    ///   - charging: the phone is on power (charging or full).
    ///   - normalBytesOnPhone: normal footage already on the phone (counts toward the cap).
    func wants(_ file: DashcamFile, parked: Bool, charging: Bool = false, normalBytesOnPhone: Int64) -> Bool {
        switch file.kind {
        case .event, .parking, .photo:
            return true
        case .normal:
            switch normal {
            case .off: return false
            case .front: guard file.lens == .front else { return false }
            case .all: break
            }
            if !normalWhen.allows(parked: parked, charging: charging) { return false }
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

    /// Kind and lens subfolders keep same-named clips apart (a front and a rear clip often share
    /// a file name; so can a normal clip and its locked event copy).
    /// The camera folder goes in too: event and emr folders share a kind and can share names.
    func localURL(camera: String, file: DashcamFile) -> URL {
        let url = path(camera: camera, file: file, lens: file.lens)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        // Builds before the A4 fix filed its rear clips (video_back/*_b.ts) under front/: keep finding them there.
        if file.lens == .rear {
            let legacy = path(camera: camera, file: file, lens: .front)
            if fm.fileExists(atPath: legacy.path) { return legacy }
        }
        // A locked clip brought back from the cloud is the MP4 copy the cloud keeps, beside where the camera's
        // file would be (`restoredURL`).
        let restored = Self.mp4(url)
        if restored != url, fm.fileExists(atPath: restored.path) { return restored }
        return url
    }

    /// Where a locked clip brought back from the cloud lands: the camera's own path when it came back in the
    /// camera's format, else the same name in `.mp4` (the cloud keeps MP4 copies of `.ts` clips) — which
    /// `localURL` finds when the camera's file isn't there.
    func restoredURL(camera: String, file: DashcamFile, ext: String) -> URL {
        let url = path(camera: camera, file: file, lens: file.lens)
        guard ext.lowercased() != url.pathExtension.lowercased() else { return url }
        return url.deletingPathExtension().appendingPathExtension(ext.lowercased())
    }

    /// Where the camera's own file goes (a download's destination), whatever else is there.
    func cameraURL(camera: String, file: DashcamFile) -> URL { path(camera: camera, file: file, lens: file.lens) }

    /// The camera's original came down: a copy brought back from the cloud beside it goes, so there is one copy.
    func dropRestoredCopy(camera: String, file: DashcamFile) {
        let original = cameraURL(camera: camera, file: file)
        let restored = Self.mp4(original)
        guard restored != original, FileManager.default.fileExists(atPath: original.path) else { return }
        try? FileManager.default.removeItem(at: restored)
    }

    /// What a downloaded file is, from its first bytes: "ts" (the 0x47 sync byte at 0 and 188), "mp4" (`ftyp` at 4)
    /// or "jpg"; nil when it's none of those.
    static func sniffedExtension(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 189)) ?? Data())
        if head.count >= 189, head[0] == 0x47, head[188] == 0x47 { return "ts" }
        if head.count >= 8, head[4...7].elementsEqual(Array("ftyp".utf8)) { return "mp4" }
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "jpg" }
        return nil
    }

    private static func mp4(_ url: URL) -> URL {
        url.pathExtension.lowercased() == "ts" ? url.deletingPathExtension().appendingPathExtension("mp4") : url
    }

    /// A phone copy's place under its camera folder ("normal/front/loop/x.ts"): what the phone-space count
    /// leaves out for locked clips, the same whatever container path the app has this install.
    static func key(_ url: URL) -> String { url.pathComponents.suffix(4).joined(separator: "/") }

    private func path(camera: String, file: DashcamFile, lens: DashcamLens) -> URL {
        let parent = file.path.split(separator: "/").dropLast().last.map(String.init) ?? "card"
        let safeParent = String(parent.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return folder(camera: camera).appendingPathComponent(file.kind.rawValue, isDirectory: true)
            .appendingPathComponent(lens.rawValue, isDirectory: true)
            .appendingPathComponent(safeParent.isEmpty ? "card" : safeParent, isDirectory: true)
            .appendingPathComponent(file.name)
    }

    /// Every file under the normal-footage folder (all lenses), with size and age.
    private func normalFiles(camera: String) -> [(url: URL, size: Int64, date: Date)] {
        let dir = folder(camera: camera).appendingPathComponent(DashcamClipKind.normal.rawValue, isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
        var out: [(URL, Int64, Date)] = []
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            out.append((url, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// A download only lands at its final path once it finished, so a file there is complete. The
    /// size check allows for Viidure listing sizes in whole KB (rounded up). A restored MP4 copy is smaller
    /// than the camera's file but just as complete (it too lands whole).
    func exists(camera: String, file: DashcamFile) -> Bool {
        let url = localURL(camera: camera, file: file)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { return false }
        if url.lastPathComponent != file.name { return size > 0 }
        return size > 0 && size >= file.size - 1024
    }

    func localSize(camera: String, file: DashcamFile) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: localURL(camera: camera, file: file).path)[.size] as? NSNumber)?.int64Value
    }

    /// Bytes of normal footage on the phone (what the cap measures). `excluding`: locked clips' copies
    /// (`key`), which stay on the phone for good and so never count against the cap.
    func normalBytes(camera: String, excluding: Set<String> = []) -> Int64 {
        normalFiles(camera: camera).reduce(0) { excluding.contains(Self.key($1.url)) ? $0 : $0 + $1.size }
    }

    /// Frees room for `needed` bytes of normal footage by deleting the oldest normal clips the
    /// server already has everywhere. Events, parking clips, photos, locked clips (`key`) and anything not
    /// yet uploaded are never touched. Returns the deleted file names.
    @discardableResult
    func evict(camera: String, needed: Int64, cap: Int64, uploadedNames: Set<String>, locked: Set<String> = []) -> [String] {
        let items = normalFiles(camera: camera).filter { !locked.contains(Self.key($0.url)) }.sorted { $0.date < $1.date }
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
