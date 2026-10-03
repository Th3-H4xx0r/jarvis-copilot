import AVFoundation
import Foundation

// MARK: - Server models (`/api/dashcam`, spec §"Phone ↔ server")

/// Decoding is lenient on purpose: a field the server adds later, or a number sent as a string,
/// must not hide a whole clip from the library.
private func str(_ v: Any?) -> String? {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
private func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}
private func bool(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? (v as? String == "true") }

struct DashcamDestinationState: Equatable, Sendable {
    var state: String          // pending | uploading | done | failed
    var error: String?
    var remotePath: String?
    /// Set on copies the phone uploaded to Drive itself: the Drive file, streamable directly.
    var fileID: String?
    /// The 720p streaming copy, when the phone made one.
    var previewFileID: String?

    init(json: [String: Any]) {
        state = str(json["state"]) ?? "pending"
        error = str(json["error"])
        remotePath = str(json["remote_path"])
        fileID = str(json["file_id"])
        previewFileID = str(json["preview_file_id"])
    }
    init(state: String, error: String? = nil) { self.state = state; self.error = error }
}

struct DashcamServerClip: Identifiable, Equatable, Sendable {
    let id: String
    var cameraID: String
    var path: String
    var name: String
    var kind: DashcamClipKind
    var lens: DashcamLens
    var start: Date
    var durationS: Double
    var size: Int64
    var onCamera: Bool
    var sizeStable: Bool
    var hasGPS: Bool
    var hasThumb: Bool
    var phoneState: String
    var phoneError: String?
    var uploadState: String
    /// Bytes of the phone → server upload the server holds so far.
    var uploadBytes: Int64 = 0
    var destinations: [String: DashcamDestinationState]
    var driveID: String?
    /// The server's own verdict (every enabled destination has it); preferred over recomputing.
    var serverUploaded: Bool?

    init?(json: [String: Any]) {
        guard let id = str(json["id"]), let path = str(json["path"]) else { return nil }
        self.id = id
        cameraID = str(json["camera_id"]) ?? ""
        self.path = path
        name = str(json["name"]) ?? (path.split(separator: "/").last.map(String.init) ?? path)
        kind = DashcamClipKind(rawValue: str(json["kind"]) ?? "") ?? .normal
        lens = DashcamLens(rawValue: str(json["lens"]) ?? "") ?? .front
        start = str(json["start"]).flatMap(Date.dashcamISO) ?? Date(timeIntervalSince1970: 0)
        durationS = num(json["duration_s"]) ?? num(json["duration"]) ?? 0
        size = Int64(num(json["size"]) ?? 0)
        onCamera = json["on_camera"].map(bool) ?? true
        sizeStable = bool(json["size_stable"])
        hasGPS = bool(json["has_gps"])
        hasThumb = bool(json["has_thumb"])
        let phone = json["phone"] as? [String: Any] ?? [:]
        phoneState = str(phone["state"]) ?? "none"
        phoneError = str(phone["error"])
        let upload = json["upload"] as? [String: Any] ?? [:]
        uploadState = str(upload["state"]) ?? "none"
        uploadBytes = Int64(num(upload["bytes"]) ?? 0)
        var dests: [String: DashcamDestinationState] = [:]
        for (k, v) in json["destinations"] as? [String: Any] ?? [:] {
            if let d = v as? [String: Any] { dests[k] = DashcamDestinationState(json: d) }
        }
        destinations = dests
        driveID = str(json["drive_id"])
        serverUploaded = json["uploaded"].map(bool)
    }

    var end: Date { start.addingTimeInterval(durationS) }

    /// A Drive copy the phone uploaded itself, to stream straight from Google (destination id, file id).
    var driveFile: (destinationID: String, fileID: String, previewID: String?)? {
        destinations.first { $0.value.state == "done" && $0.value.fileID != nil }
            .map { ($0.key, $0.value.fileID!, $0.value.previewFileID) }
    }

    /// Every destination the clip was sent to has it.
    var uploaded: Bool { serverUploaded ?? (!destinations.isEmpty && destinations.values.allSatisfy { $0.state == "done" }) }
    var failed: Bool { destinations.values.contains { $0.state == "failed" } || phoneState == "failed" }
    var uploading: Bool {
        !uploaded && (uploadState == "staging" || uploadState == "staged"
                      || destinations.values.contains { $0.state == "uploading" || $0.state == "pending" })
    }
}

struct DashcamDrive: Identifiable, Equatable, Sendable {
    let id: String
    var start: Date
    var end: Date
    var distanceM: Double
    var durationS: Double
    var movingS: Double
    var avgMps: Double
    var maxMps: Double
    var bounds: [Double]
    var clipIDs: [String]

    init?(json: [String: Any]) {
        guard let id = str(json["id"]) else { return nil }
        self.id = id
        start = str(json["start"]).flatMap(Date.dashcamISO) ?? Date(timeIntervalSince1970: 0)
        end = str(json["end"]).flatMap(Date.dashcamISO) ?? start
        distanceM = num(json["distance_m"]) ?? 0
        durationS = num(json["duration_s"]) ?? end.timeIntervalSince(start)
        movingS = num(json["moving_s"]) ?? durationS
        avgMps = num(json["avg_mps"]) ?? 0
        maxMps = num(json["max_mps"]) ?? 0
        bounds = (json["bounds"] as? [Any])?.compactMap(num) ?? []
        clipIDs = (json["clip_ids"] as? [Any])?.compactMap(str) ?? []
    }
}

struct DashcamDriveDetail: Sendable {
    var drive: DashcamDrive
    /// `[lat, lon, speed m/s, t]`, thinned for the map; `t` (Unix seconds) maps a point to its clip.
    var polyline: [(lat: Double, lon: Double, speed: Double?, t: Double?)]
    var clips: [DashcamServerClip]
}

struct DashcamDestination: Identifiable, Equatable, Sendable {
    let id: String
    var type: String
    var name: String
    var path: String
    var enabled: Bool
    var kinds: [String]
    var status: String?
    var error: String?

    init?(json: [String: Any]) {
        guard let id = str(json["id"]) else { return nil }
        self.id = id
        type = str(json["type"]) ?? "?"
        name = str(json["name"]) ?? type
        path = str(json["path"]) ?? ""
        enabled = json["enabled"].map(bool) ?? true
        kinds = (json["kinds"] as? [Any])?.compactMap(str) ?? DashcamClipKind.allCases.map(\.rawValue)
        status = str(json["status"])
        error = str(json["error"])
    }
}

struct DashcamServerState: Sendable {
    var rules: DashcamRules
    var destinations: [DashcamDestination]
    var counts: [String: Int]
    var stagingBytes: Int64
    var stagingCap: Int64
}

struct DashcamUploadTicket: Equatable, Sendable {
    let uploadID: String
    let chunkSize: Int
    let received: Set<Int>
    var complete: Bool = false
}

// MARK: - Client

/// `/api/dashcam` on the Jarvis server. Everything goes through `JarvisAPI` so it carries the
/// pairing's session cookie and Cloudflare Access headers.
struct DashcamAPI: Sendable {
    var api: JarvisAPI = .shared
    static let prefix = "/api/dashcam"

    enum UploadStart: Equatable, Sendable {
        case ticket(DashcamUploadTicket)
        /// The server already has this clip (finished earlier, or uploaded and cleaned up).
        case alreadyThere
        /// 507: the server's staging area is full; try again after this many seconds.
        case full(retryAfter: TimeInterval)
        /// 413: bigger than the server's whole staging area — it can never be sent as things stand.
        case tooLarge
        /// 409: no enabled destination takes this kind of clip — nothing to send it to yet.
        case noDestination
    }

    func state() async throws -> DashcamServerState {
        let o = try await api.get(Self.prefix + "/state").object()
        let settings = o["settings"] as? [String: Any] ?? [:]
        let staging = o["staging"] as? [String: Any] ?? [:]
        var counts: [String: Int] = [:]
        for (k, v) in o["counts"] as? [String: Any] ?? [:] { counts[k] = Int(num(v) ?? 0) }
        return DashcamServerState(
            rules: DashcamRules(json: settings["rules"] as? [String: Any] ?? [:]),
            destinations: (o["destinations"] as? [[String: Any]] ?? []).compactMap(DashcamDestination.init(json:)),
            counts: counts,
            stagingBytes: Int64(num(staging["bytes"]) ?? 0),
            stagingCap: Int64(num(staging["cap"]) ?? 0))
    }

    func upsertCamera(_ info: DashcamCameraInfo, ssid: String) async throws {
        var body = info.wire
        body["ssid"] = ssid
        _ = try await api.post(Self.prefix + "/cameras", json: body)
    }

    /// Reports the camera's file list; returns the server's view of each file (by path).
    func inventory(cameraID: String, files: [DashcamFile]) async throws -> [String: DashcamInventoryRow] {
        let items: [[String: Any]] = files.map {
            ["path": $0.path, "kind": $0.kind.rawValue, "lens": $0.lens.rawValue, "start": $0.start.dashcamISO,
             "duration": $0.durationS, "duration_s": $0.durationS, "size": $0.size, "locked": $0.locked]
        }
        let o = try await api.post(Self.prefix + "/inventory", json: ["camera_id": cameraID, "clips": items], timeout: 60).object()
        var out: [String: DashcamInventoryRow] = [:]
        for row in o["clips"] as? [[String: Any]] ?? [] {
            guard let r = DashcamInventoryRow(json: row) else { continue }
            out[r.path] = r
        }
        return out
    }

    func putFixes(clipID: String, fixes: [DashcamFix]) async throws {
        _ = try await api.post(Self.prefix + "/clips/\(clipID)/gps", json: ["fixes": fixes.map(\.row)], timeout: 60)
    }

    func putThumb(clipID: String, jpeg: Data) async throws {
        _ = try await api.postData(Self.prefix + "/clips/\(clipID)/thumb", jpeg, contentType: "image/jpeg", timeout: 30)
    }

    func setPhone(clipID: String, state: String, error: String? = nil) async throws {
        var body: [String: Any] = ["state": state]
        if let error { body["error"] = error }
        _ = try await api.post(Self.prefix + "/clips/\(clipID)/phone", json: body)
    }

    struct ClipFilter: Equatable, Sendable {
        var kind: DashcamClipKind?
        var lens: DashcamLens?
        var state: String?
        var drive: String?
        var from: Date?
        var to: Date?
    }

    func clips(_ filter: ClipFilter = ClipFilter(), cursor: String? = nil, limit: Int = 100) async throws -> (clips: [DashcamServerClip], next: String?) {
        var q: [String: String] = ["limit": String(limit)]
        if let k = filter.kind { q["kind"] = k.rawValue }
        if let l = filter.lens { q["lens"] = l.rawValue }
        if let s = filter.state { q["state"] = s }
        if let d = filter.drive { q["drive"] = d }
        if let f = filter.from { q["from"] = f.dashcamISO }
        if let t = filter.to { q["to"] = t.dashcamISO }
        if let cursor { q["cursor"] = cursor }
        let o = try await api.get(Self.prefix + "/clips", query: q).object()
        return ((o["clips"] as? [[String: Any]] ?? []).compactMap(DashcamServerClip.init(json:)), str(o["next"]))
    }

    /// Deleted everywhere: the server drops the clip's record too.
    func forgetClip(_ clipID: String) async throws {
        _ = try await api.post(Self.prefix + "/clips/\(clipID)/forget", timeout: 60)
    }

    func deleteFromCloud(clipID: String) async throws {
        _ = try await api.post(Self.prefix + "/clips/\(clipID)/delete_cloud", timeout: 120)
    }

    func clip(_ id: String) async throws -> (clip: DashcamServerClip, fixes: [DashcamFix]) {
        let o = try await api.get(Self.prefix + "/clips/\(id)").object()
        let body = o["clip"] as? [String: Any] ?? o
        guard let clip = DashcamServerClip(json: body) else { throw APIError.badResponse("clip \(id) missing") }
        let fixes = ((o["fixes"] ?? body["fixes"]) as? [Any] ?? []).compactMap(DashcamFix.init(row:))
        return (clip, fixes)
    }

    func retry(clipID: String) async throws { _ = try await api.post(Self.prefix + "/clips/\(clipID)/retry") }

    func drives(from: Date? = nil, to: Date? = nil) async throws -> [DashcamDrive] {
        var q: [String: String] = [:]
        if let from { q["from"] = from.dashcamISO }
        if let to { q["to"] = to.dashcamISO }
        let o = try await api.get(Self.prefix + "/drives", query: q).object()
        return (o["drives"] as? [[String: Any]] ?? []).compactMap(DashcamDrive.init(json:))
    }

    func drive(_ id: String) async throws -> DashcamDriveDetail {
        let o = try await api.get(Self.prefix + "/drives/\(id)").object()
        let body = o["drive"] as? [String: Any] ?? o
        guard let drive = DashcamDrive(json: body) else { throw APIError.badResponse("drive \(id) missing") }
        let poly = ((o["polyline"] ?? body["polyline"]) as? [[Any]] ?? []).compactMap { p -> (lat: Double, lon: Double, speed: Double?, t: Double?)? in
            guard p.count >= 2, let lat = num(p[0]), let lon = num(p[1]) else { return nil }
            return (lat, lon, p.count > 2 ? num(p[2]) : nil, p.count > 3 ? num(p[3]) : nil)
        }
        let clips = ((o["clips"] ?? body["clips"]) as? [[String: Any]] ?? []).compactMap(DashcamServerClip.init(json:))
        return DashcamDriveDetail(drive: drive, polyline: poly, clips: clips)
    }

    func gpx(driveID: String) async throws -> Data {
        try await api.get(Self.prefix + "/drives/\(driveID).gpx").data
    }

    func destinations() async throws -> [DashcamDestination] {
        let o = try await api.get(Self.prefix + "/destinations").object()
        return (o["destinations"] as? [[String: Any]] ?? []).compactMap(DashcamDestination.init(json:))
    }

    /// `fields` may hold a password or token; they go to the server's rclone config and are never echoed back.
    func addDestination(_ fields: [String: Any]) async throws -> DashcamDestination {
        let o = try await api.post(Self.prefix + "/destinations", json: fields, timeout: 60).object()
        guard let d = DashcamDestination(json: o["destination"] as? [String: Any] ?? [:]) else {
            throw APIError.badResponse(str(o["error"]) ?? "the server did not return the destination")
        }
        return d
    }

    func testDestination(_ id: String) async throws -> String? {
        let o = try await api.post(Self.prefix + "/destinations/\(id)/test", timeout: 60).object()
        return bool(o["ok"]) ? nil : (str(o["error"]) ?? "test failed")
    }

    func deleteDestination(_ id: String) async throws { _ = try await api.post(Self.prefix + "/destinations/\(id)/delete") }

    func updateRules(_ rules: DashcamRules) async throws {
        _ = try await api.post(Self.prefix + "/settings", json: ["rules": rules.json])
    }

    func startUpload(clipID: String, size: Int64, sha256: String) async throws -> UploadStart {
        do {
            let o = try await api.post(Self.prefix + "/uploads", json: ["clip_id": clipID, "size": size, "sha256": sha256,
                                                                        "chunk_size": DashcamUploader.chunkSize]).object()
            return try Self.uploadStart(o)
        } catch APIError.http(let status, _) where status == 507 {
            return .full(retryAfter: 60)
        } catch APIError.http(let status, _) where status == 413 {
            return .tooLarge
        } catch APIError.http(let status, _) where status == 409 {
            return .noDestination
        }
    }

    static func uploadStart(_ o: [String: Any]) throws -> UploadStart {
        if bool(o["already_uploaded"]) { return .alreadyThere }
        guard let id = str(o["upload_id"]) else { throw APIError.badResponse("no upload_id") }
        let received = Set((o["received"] as? [Any] ?? []).compactMap { num($0).map(Int.init) })
        return .ticket(DashcamUploadTicket(uploadID: id, chunkSize: Int(num(o["chunk_size"]) ?? 16_777_216),
                                           received: received, complete: bool(o["complete"])))
    }

    /// The request for one chunk, for a background upload task (the body comes from a file).
    func chunkRequest(uploadID: String, index: Int) throws -> URLRequest {
        var req = try api.request("POST", Self.prefix + "/uploads/\(uploadID)/chunk", query: ["n": String(index)],
                                  headers: ["Content-Type": "application/octet-stream"], timeout: 600)
        req.httpBody = nil
        return req
    }

    func completeUpload(_ uploadID: String) async throws {
        _ = try await api.post(Self.prefix + "/uploads/\(uploadID)/complete", timeout: 120)
    }

    func thumbURL(clipID: String) throws -> URLRequest {
        try api.request("GET", Self.prefix + "/clips/\(clipID)/thumb", timeout: 30)
    }

    /// An asset that streams the uploaded clip through the server (Range requests), carrying the
    /// pairing's auth headers — cookie *and* Cloudflare Access — which AVPlayer would otherwise drop.
    func streamAsset(clipID: String) throws -> AVURLAsset {
        let req = try api.request("GET", Self.prefix + "/clips/\(clipID)/stream")
        guard let url = req.url else { throw APIError.badResponse("bad stream URL") }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": req.allHTTPHeaderFields ?? [:]])
    }
}

/// The server's compact reply row for one inventoried file.
struct DashcamInventoryRow: Equatable, Sendable {
    let id: String
    let path: String
    var hasGPS: Bool
    var hasThumb: Bool
    var uploaded: Bool
    var sizeStable: Bool
    /// Deleted from the phone by hand: never pulled again on its own (only "Download again").
    var phoneDeleted = false

    init?(json: [String: Any]) {
        guard let id = str(json["id"]), let path = str(json["path"]) else { return nil }
        self.id = id
        self.path = path
        phoneDeleted = str(json["phone_state"]) == "deleted"
        hasGPS = bool(json["has_gps"])
        hasThumb = bool(json["has_thumb"])
        uploaded = bool(json["uploaded"])
        sizeStable = bool(json["size_stable"])
    }
}
