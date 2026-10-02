import Foundation

/// A short-lived Google Drive access token for one destination, handed out by the server (which keeps the
/// login itself), so the phone uploads to Drive directly instead of through the server's tunnel.
struct DashcamDriveAccess: Equatable, Sendable {
    let destinationID: String
    let token: String
    let expiresAt: Date
    /// The destination's folder path ("Dashcam Camry SE 2026"); clips go below it.
    let basePath: String
    let teamDrive: String?

    var fresh: Bool { expiresAt.timeIntervalSinceNow > 120 }
}

/// Where the server's relay would put a clip — the phone must match it exactly so the library, the
/// server and a later relay copy agree: `<base>/<camera_id>/<YYYY-MM-DD UTC>/<kind>/<lens>/<name>`.
enum DashcamRemotePath {
    static func segment(_ value: String, _ fallback: String = "_") -> String {
        let text = value.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespaces)
        return ["", ".", ".."].contains(text) ? fallback : text
    }

    static func folders(base: String, cameraID: String, start: Date?, kind: DashcamClipKind, lens: DashcamLens) -> [String] {
        let day: String
        if let start, start.timeIntervalSince1970 > 0 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            day = f.string(from: start)
        } else {
            day = "undated"
        }
        let baseParts = base.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return baseParts + [segment(cameraID), day, segment(kind.rawValue), segment(lens.rawValue)]
    }

    /// The camera's name, with `.mp4` once the phone converted a `.ts`.
    static func name(_ cameraName: String, converted: Bool) -> String {
        let last = segment(cameraName.split(separator: "/").last.map(String.init) ?? cameraName, "clip")
        guard converted, last.lowercased().hasSuffix(".ts") else { return last }
        return String(last.dropLast(3)) + ".mp4"
    }
}

/// The Drive v3 calls the uploader needs. A protocol so the uploader can be tested without Google.
protocol DashcamDriveClient: Sendable {
    /// The folder at `path` (created as needed), as a Drive file id.
    func folder(_ path: [String], access: DashcamDriveAccess) async throws -> String
    /// A file of that name and size already in the folder (a retried upload that finished before).
    func existing(name: String, size: Int64, in folder: String, access: DashcamDriveAccess) async throws -> String?
    /// Uploads `file` with a resumable session (resumed from `session` when given). `saveSession` is called
    /// with the session URL as soon as there is one; `sent` with the bytes confirmed so far. Returns the file id.
    func upload(_ file: URL, name: String, mime: String, folder: String, access: DashcamDriveAccess, session: URL?,
                saveSession: @escaping @Sendable (URL) -> Void, sent: @escaping @Sendable (Int64) -> Void) async throws -> String
}

enum DashcamDriveError: LocalizedError, Equatable {
    case unauthorized
    case sessionGone
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Google Drive refused the sign-in — test the destination"
        case .sessionGone: return "Google Drive dropped the upload session; starting it again"
        case .http(let code, let message): return "Google Drive said \(code): \(message)"
        }
    }
}

/// The real thing: Drive v3 over HTTPS, resumable uploads in 8 MiB pieces (Google's minimum unit is 256 KiB).
final class DashcamGoogleDrive: DashcamDriveClient, @unchecked Sendable {
    static let shared = DashcamGoogleDrive()
    static let piece = 8 * 1024 * 1024

    let session: URLSession
    private let lock = NSLock()
    private var folderCache: [String: String] = [:]

    init(session: URLSession? = nil) {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 3600
        self.session = session ?? URLSession(configuration: c)
    }

    private func request(_ url: URL, _ method: String, access: DashcamDriveAccess, json: Any? = nil) throws -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = method
        r.setValue("Bearer \(access.token)", forHTTPHeaderField: "Authorization")
        if let json {
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    private func object(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw DashcamDriveError.unauthorized }
        guard (200..<300).contains(code) else { throw DashcamDriveError.http(code, Self.message(data)) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func message(_ data: Data) -> String {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((o?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    private func allDrives(_ items: inout [URLQueryItem], _ access: DashcamDriveAccess) {
        items.append(URLQueryItem(name: "supportsAllDrives", value: "true"))
        if let drive = access.teamDrive {
            items += [URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                      URLQueryItem(name: "corpora", value: "drive"), URLQueryItem(name: "driveId", value: drive)]
        }
    }

    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private func find(_ q: String, access: DashcamDriveAccess) async throws -> [[String: Any]] {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        var items = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "fields", value: "files(id,name,size)"),
                     URLQueryItem(name: "pageSize", value: "10")]
        allDrives(&items, access)
        c.queryItems = items
        return try await object(request(c.url!, "GET", access: access))["files"] as? [[String: Any]] ?? []
    }

    func folder(_ path: [String], access: DashcamDriveAccess) async throws -> String {
        var parent = access.teamDrive ?? "root"
        var walked: [String] = []
        for name in path {
            walked.append(name)
            let key = access.destinationID + "|" + walked.joined(separator: "/")
            lock.lock(); let cached = folderCache[key]; lock.unlock()
            if let cached { parent = cached; continue }
            let q = "name = \(Self.quoted(name)) and \(Self.quoted(parent)) in parents and "
                + "mimeType = 'application/vnd.google-apps.folder' and trashed = false"
            let id: String
            if let hit = try await find(q, access: access).first?["id"] as? String {
                id = hit
            } else {
                var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
                var items = [URLQueryItem(name: "fields", value: "id")]
                allDrives(&items, access)
                c.queryItems = items
                let made = try await object(request(c.url!, "POST", access: access,
                                                    json: ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [parent]]))
                guard let made = made["id"] as? String else { throw DashcamDriveError.http(0, "no folder id") }
                id = made
            }
            lock.lock(); folderCache[key] = id; lock.unlock()
            parent = id
        }
        return parent
    }

    func existing(name: String, size: Int64, in folder: String, access: DashcamDriveAccess) async throws -> String? {
        let q = "name = \(Self.quoted(name)) and \(Self.quoted(folder)) in parents and trashed = false"
        return try await find(q, access: access).first { Int64(($0["size"] as? String) ?? "") == size }?["id"] as? String
    }

    func upload(_ file: URL, name: String, mime: String, folder: String, access: DashcamDriveAccess, session resume: URL?,
                saveSession: @escaping @Sendable (URL) -> Void, sent: @escaping @Sendable (Int64) -> Void) async throws -> String {
        let total = Int64((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0)
        var sessionURL: URL
        var offset: Int64 = 0
        if let resume, let at = try await confirmed(resume, total: total, access: access) {
            sessionURL = resume
            offset = at
        } else {
            var c = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
            var items = [URLQueryItem(name: "uploadType", value: "resumable"), URLQueryItem(name: "fields", value: "id")]
            allDrives(&items, access)
            c.queryItems = items
            var r = try request(c.url!, "POST", access: access, json: ["name": name, "parents": [folder]])
            r.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
            r.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
            let (data, resp) = try await session.data(for: r)
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 401 { throw DashcamDriveError.unauthorized }
            guard http?.statusCode == 200, let loc = http?.value(forHTTPHeaderField: "Location"), let url = URL(string: loc) else {
                throw DashcamDriveError.http(http?.statusCode ?? 0, Self.message(data))
            }
            sessionURL = url
            saveSession(url)
        }
        sent(offset)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let piece = try handle.read(upToCount: Self.piece) ?? Data()
            var r = URLRequest(url: sessionURL, timeoutInterval: 600)
            r.httpMethod = "PUT"
            r.setValue("Bearer \(access.token)", forHTTPHeaderField: "Authorization")
            let end = offset + Int64(piece.count) - 1
            r.setValue(piece.isEmpty ? "bytes */\(total)" : "bytes \(offset)-\(end)/\(total)", forHTTPHeaderField: "Content-Range")
            let base = offset
            let (data, resp) = try await session.upload(for: r, from: piece, delegate: DashcamChunkProgress { sent(base + $0) })
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200, 201:
                sent(total)
                let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard let id = o?["id"] as? String else { throw DashcamDriveError.http(code, "no file id") }
                return id
            case 308:
                offset = Self.nextOffset((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"))
                sent(offset)
            case 401:
                throw DashcamDriveError.unauthorized
            case 404, 410:
                throw DashcamDriveError.sessionGone
            default:
                throw DashcamDriveError.http(code, Self.message(data))
            }
        }
    }

    /// How much of a resumable session Google has (nil: the session is gone, start a new one).
    private func confirmed(_ url: URL, total: Int64, access: DashcamDriveAccess) async throws -> Int64? {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = "PUT"
        r.setValue("Bearer \(access.token)", forHTTPHeaderField: "Authorization")
        r.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        let (_, resp) = try await session.upload(for: r, from: Data())
        let http = resp as? HTTPURLResponse
        if http?.statusCode == 308 { return Self.nextOffset(http?.value(forHTTPHeaderField: "Range")) }
        return nil      // 404/410 gone, or 200/201: finished earlier — `existing` finds that file
    }

    /// `Range: bytes=0-1234` → 1235 (no header: nothing yet).
    static func nextOffset(_ range: String?) -> Int64 {
        guard let range, let dash = range.lastIndex(of: "-"), let last = Int64(range[range.index(after: dash)...]) else { return 0 }
        return last + 1
    }
}
