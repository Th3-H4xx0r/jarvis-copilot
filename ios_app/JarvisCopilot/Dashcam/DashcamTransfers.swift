import AVFoundation
import CryptoKit
import Foundation

/// Where transfer bookkeeping lives (resume data, the upload queue).
enum DashcamPaths {
    /// MP4 copies made for a direct upload, removed once it's done.
    static var uploadTemp: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DashcamUpload", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Dashcam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Camera → phone

/// Downloads clips off the camera with resume. Ordinary URLSession on purpose: background-session
/// tasks created while the app is backgrounded are discretionary and can wait hours; the app is
/// kept alive by the keepalive, so a normal session keeps going (and resume data covers drops).
final class DashcamDownloader: @unchecked Sendable {
    static let shared = DashcamDownloader()

    let session: URLSession
    let resumeDir: URL
    private let lock = NSLock()
    private var active: [ObjectIdentifier: (box: TaskBox, resume: URL)] = [:]

    /// Stops every download in flight, keeping resume data (the live view needs the camera's Wi‑Fi).
    func pauseAll() {
        lock.lock()
        let now = Array(active.values)
        lock.unlock()
        for item in now {
            let file = item.resume
            item.box.task?.cancel { data in if let data { try? data.write(to: file, options: .atomic) } }
        }
    }

    init(session: URLSession? = nil, resumeDir: URL? = nil) {
        let c = URLSessionConfiguration.default
        c.allowsCellularAccess = false          // the camera only exists on its own Wi‑Fi
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 3 * 3600
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 1
        self.session = session ?? URLSession(configuration: c)
        self.resumeDir = resumeDir ?? DashcamPaths.support.appendingPathComponent("resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.resumeDir, withIntermediateDirectories: true)
    }

    private func resumeURL(_ key: String) -> URL {
        resumeDir.appendingPathComponent(key.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) } + ".resume")
    }

    func hasResumeData(_ key: String) -> Bool { FileManager.default.fileExists(atPath: resumeURL(key).path) }

    /// Downloads `url` to `dest`, continuing a previous attempt for the same `key` if one was cut off.
    /// Progress comes from polling the task's byte counts — the async `download(from:)` API never
    /// calls `didWriteData`.
    func download(_ url: URL, to dest: URL, key: String,
                  progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let resumeFile = resumeURL(key)
        if let resume = try? Data(contentsOf: resumeFile) {
            do {
                try await run(resume: resume, url: nil, dest: dest, resumeFile: resumeFile, progress: progress)
                return
            } catch let e as URLError where e.downloadTaskResumeData == nil && e.code != .cancelled {
                // Stale resume data (camera rebooted, file rotated): start over once.
                try? FileManager.default.removeItem(at: resumeFile)
            }
        }
        try await run(resume: nil, url: url, dest: dest, resumeFile: resumeFile, progress: progress)
    }

    private func run(resume: Data?, url: URL?, dest: URL, resumeFile: URL,
                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let box = TaskBox()
        lock.lock(); active[ObjectIdentifier(box)] = (box, resumeFile); lock.unlock()
        defer { lock.lock(); active[ObjectIdentifier(box)] = nil; lock.unlock() }
        let poll = Task {
            while !Task.isCancelled {
                if let t = box.task { progress(t.countOfBytesReceived, t.countOfBytesExpectedToReceive) }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poll.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let handler: @Sendable (URL?, URLResponse?, Error?) -> Void = { tmp, response, error in
                    if let error {
                        if let data = (error as? URLError)?.downloadTaskResumeData { try? data.write(to: resumeFile, options: .atomic) }
                        let e = error as? URLError
                        cont.resume(throwing: e?.code == .cancelled ? CancellationError() as Error
                                    : (e?.downloadTaskResumeData == nil && resume != nil ? error : DashcamError.notConnected))
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard let tmp, status == 200 || status == 206 else {
                        try? FileManager.default.removeItem(at: resumeFile)
                        cont.resume(throwing: DashcamError.http(status))
                        return
                    }
                    // The temp file is gone once this handler returns: move it now.
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        try? FileManager.default.removeItem(at: resumeFile)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                let task = resume.map { session.downloadTask(withResumeData: $0, completionHandler: handler) }
                    ?? session.downloadTask(with: url!, completionHandler: handler)
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel { data in if let data { try? data.write(to: resumeFile, options: .atomic) } }
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
    }
}

// MARK: - Phone → server

/// One clip waiting to reach the server.
struct DashcamUploadJob: Codable, Equatable, Sendable {
    var clipID: String
    var localPath: String
    var size: Int64
    var kind: DashcamClipKind
    var sha256: String?
    var uploadID: String?
    var chunkSize: Int?
    var attempts: Int = 0
    var notBefore: Date?
    var lastError: String?
    /// Direct uploads (Drive): open resumable sessions by destination id, and destinations already done.
    var directSessions: [String: String]?
    var directDone: [String]?
}

/// Anything that can take a chunk upload (the server, or a fake in tests).
protocol DashcamUploadServer: Sendable {
    func startUpload(clipID: String, size: Int64, sha256: String) async throws -> DashcamAPI.UploadStart
    /// Destinations, to send Drive ones directly. Empty = everything through the server (the old way).
    func uploadDestinations() async throws -> [DashcamDestination]
    func driveAccess(destinationID: String) async throws -> DashcamDriveAccess
    func clipInfo(_ clipID: String) async throws -> DashcamServerClip
    func recordDirect(clipID: String, destinationID: String, remotePath: String, fileID: String, size: Int64,
                      preview: (path: String, fileID: String)?) async throws
    /// `sent` reports the bytes of this chunk on their way so far.
    func sendChunk(uploadID: String, index: Int, data: Data, cellular: Bool,
                   sent: @escaping @Sendable (Int64) -> Void) async throws
    func completeUpload(_ uploadID: String) async throws
}

/// Byte-level progress of one chunk's request body.
final class DashcamChunkProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let sent: @Sendable (Int64) -> Void
    init(_ sent: @escaping @Sendable (Int64) -> Void) { self.sent = sent }
    /// Clip uploads fill the LTE uplink for minutes; the app's own requests go first.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { task.priority = URLSessionTask.lowPriority }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        sent(totalBytesSent)
    }
}

extension DashcamUploadServer {
    func uploadDestinations() async throws -> [DashcamDestination] { [] }
    func driveAccess(destinationID: String) async throws -> DashcamDriveAccess { throw DashcamDriveError.unauthorized }
    func clipInfo(_ clipID: String) async throws -> DashcamServerClip { throw APIError.badResponse("no clip info") }
    func recordDirect(clipID: String, destinationID: String, remotePath: String, fileID: String, size: Int64,
                      preview: (path: String, fileID: String)?) async throws {}
}

/// Destination types the phone uploads to itself.
enum DashcamDirect {
    static let types: Set<String> = ["drive"]
}

extension DashcamAPI: DashcamUploadServer {
    func uploadDestinations() async throws -> [DashcamDestination] { try await destinations() }

    func driveAccess(destinationID: String) async throws -> DashcamDriveAccess {
        let o = try await api.post(Self.prefix + "/destinations/\(destinationID)/token", timeout: 90).object()
        guard let token = o["access_token"] as? String, !token.isEmpty else { throw DashcamDriveError.unauthorized }
        let expires = (o["expires_at"] as? NSNumber)?.doubleValue ?? Date().addingTimeInterval(600).timeIntervalSince1970
        return DashcamDriveAccess(destinationID: destinationID, token: token, expiresAt: Date(timeIntervalSince1970: expires),
                                  basePath: o["path"] as? String ?? "", teamDrive: o["team_drive"] as? String)
    }

    func clipInfo(_ clipID: String) async throws -> DashcamServerClip { try await clip(clipID).clip }

    func recordDirect(clipID: String, destinationID: String, remotePath: String, fileID: String, size: Int64,
                      preview: (path: String, fileID: String)?) async throws {
        var body: [String: Any] = ["destination_id": destinationID, "remote_path": remotePath, "file_id": fileID, "size": size]
        if let preview { body["preview_path"] = preview.path; body["preview_file_id"] = preview.fileID }
        _ = try await api.post(Self.prefix + "/clips/\(clipID)/direct", json: body)
    }

    /// Chunks get their own session that fails fast when the network is gone — the shared one waits
    /// up to an hour for connectivity, which would hold the whole upload queue.
    static let chunkSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = false
        // Weak LTE moves ~1 Mbit/s up: a 4 MiB chunk can take a minute, three at once longer.
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 1800
        c.httpMaximumConnectionsPerHost = 4
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()

    func sendChunk(uploadID: String, index: Int, data: Data, cellular: Bool,
                   sent: @escaping @Sendable (Int64) -> Void) async throws {
        var req = try api.request("POST", Self.prefix + "/uploads/\(uploadID)/chunk", query: ["n": String(index)],
                                  headers: ["Content-Type": "application/octet-stream"], timeout: 600)
        req.httpBody = nil
        req.allowsCellularAccess = cellular
        let (body, resp) = try await Self.chunkSession.upload(for: req, from: data, delegate: DashcamChunkProgress(sent))
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, message: APIError.message(status: http.statusCode, body: body))
        }
    }
}

/// Sends finished downloads to the server in 4 MiB chunks, three at a time (one stream over LTE is slow).
/// Resumable: the server keeps the chunks it has and says which on every (re)start, so a dropped
/// connection costs the chunks in flight.
actor DashcamUploader {
    static let shared = DashcamUploader()

    private(set) var jobs: [DashcamUploadJob] = []
    private let file: URL
    private var running = false
    let drive: DashcamDriveClient
    private var access: [String: DashcamDriveAccess] = [:]
    /// Google's per-minute quota ran out (rclone's shared key hits it constantly): every Drive upload waits
    /// until then, and no clip's own retry count grows for it.
    private(set) var driveQuotaUntil: Date?
    static let quotaCooldown: TimeInterval = 90

    static func isQuota(_ error: Error) -> Bool {
        guard case DashcamDriveError.http(let code, let message) = error, code == 403 || code == 429 else { return false }
        let m = message.lowercased()
        return m.contains("quota") || m.contains("ratelimit") || m.contains("rate limit") || code == 429
    }
    static let maxBackoff: TimeInterval = 600

    init(file: URL? = nil, drive: DashcamDriveClient = DashcamGoogleDrive.shared) {
        self.drive = drive
        self.file = file ?? DashcamPaths.support.appendingPathComponent("uploads.json")
        if let data = try? Data(contentsOf: self.file),
           let saved = try? JSONDecoder().decode([DashcamUploadJob].self, from: data) {
            jobs = saved
        }
    }

    func enqueue(clipID: String, local: URL, size: Int64, kind: DashcamClipKind) {
        if let existing = jobs.first(where: { $0.clipID == clipID }) {
            // The same clip downloaded again (a fuller copy): start its upload over.
            guard existing.size != size || Self.resolve(existing.localPath) != local.path else { return }
            jobs.removeAll { $0.clipID == clipID }
        }
        jobs.append(DashcamUploadJob(clipID: clipID, localPath: local.path, size: size, kind: kind))
        jobs.sort { rank($0.kind) < rank($1.kind) }
        persist()
    }

    func remove(clipID: String) { jobs.removeAll { $0.clipID == clipID }; persist() }

    func contains(_ clipID: String) -> Bool { jobs.contains { $0.clipID == clipID } }

    /// Lets parked jobs (no destination, full staging) try again now — a destination was just added.
    func retryParked() {
        for i in jobs.indices { jobs[i].notBefore = nil; jobs[i].attempts = 0 }
        driveQuotaUntil = nil
        persist()
    }

    var pendingCount: Int { jobs.count }

    private func rank(_ k: DashcamClipKind) -> Int {
        switch k { case .event: return 0; case .photo: return 1; case .parking: return 2; case .normal: return 3 }
    }

    private func update(_ job: DashcamUploadJob) {
        if let i = jobs.firstIndex(where: { $0.clipID == job.clipID }) { jobs[i] = job }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: file, options: .atomic) }
    }

    /// Delay before the next try after `attempts` failures: 30 s doubling, capped at 10 min.
    static func backoff(attempts: Int) -> TimeInterval {
        min(maxBackoff, 30 * pow(2, Double(max(0, attempts - 1))))
    }

    /// Works through the queue once. `cellular` = the only way to the server right now is mobile
    /// data. `allow` says which kinds may go now (the upload rules); by default normal footage waits
    /// for Wi‑Fi on mobile data. Returns the clip ids that reached the server.
    @discardableResult
    func run(server: DashcamUploadServer, cellular: Bool, allow: (@Sendable (DashcamClipKind) -> Bool)? = nil,
             finished: (@Sendable (String, String) -> Void)? = nil,
             now: @Sendable () -> Date = { Date() },
             progress: @escaping @Sendable (String, Int64, Int64) -> Void = { _, _, _ in }) async -> [String] {
        let allowed = allow ?? { kind in !(cellular && kind == .normal) }
        // Fetched once a run; nil (server unreachable, older server) = everything through the server.
        let destinations = try? await server.uploadDestinations()
        if let until = driveQuotaUntil, until > now() { return [] }
        guard !running else { return [] }
        running = true
        defer { running = false }
        var done: [String] = []
        for clipID in jobs.map(\.clipID) {
            guard let index = jobs.firstIndex(where: { $0.clipID == clipID }) else { continue }
            var job = jobs[index]
            if let nb = job.notBefore, nb > now() { continue }
            guard allowed(job.kind) else { continue }
            // The app container moves on every reinstall/update: re-anchor the stored path.
            let path = Self.resolve(job.localPath)
            guard FileManager.default.fileExists(atPath: path) else {
                jobs.removeAll { $0.clipID == clipID }; persist(); continue
            }
            if path != job.localPath { job.localPath = path; update(job) }
            do {
                // Drive destinations: straight from the phone (no tunnel, no staging). The server only
                // hears where the clip went, and stays the route for SFTP/FTP/SMB.
                if let dests = destinations {
                    let applicable = dests.filter { $0.enabled && ($0.kinds.isEmpty || $0.kinds.contains(job.kind.rawValue)) }
                    let direct = applicable.filter { DashcamDirect.types.contains($0.type) }
                    for dest in direct where !(job.directDone ?? []).contains(dest.id) {
                        try await uploadDirect(&job, to: dest, server: server, progress: progress)
                        job.directDone = (job.directDone ?? []) + [dest.id]
                        update(job)
                    }
                    if !direct.isEmpty && applicable.allSatisfy({ DashcamDirect.types.contains($0.type) }) {
                        done.append(clipID)
                        jobs.removeAll { $0.clipID == clipID }
                        persist()
                        finished?(clipID, job.localPath)     // every destination has it: the phone copy can go now
                        continue
                    }
                }
                if job.sha256 == nil {
                    job.sha256 = try Self.sha256(of: URL(fileURLWithPath: path))
                    update(job)   // a relaunch must not hash a 1 GB clip again
                }
                switch try await server.startUpload(clipID: job.clipID, size: job.size, sha256: job.sha256 ?? "") {
                case .alreadyThere:
                    done.append(clipID)
                    jobs.removeAll { $0.clipID == clipID }
                    persist()
                case .noDestination:
                    // Short: adding a destination also wakes these (retryParked), this is the fallback.
                    job.notBefore = now().addingTimeInterval(300)
                    job.lastError = "no upload destination takes \(job.kind.label.lowercased()) clips — add one in Destinations"
                    update(job)
                case .tooLarge:
                    job.notBefore = now().addingTimeInterval(24 * 3600)
                    job.lastError = "bigger than the server's upload space — raise the staging cap"
                    update(job)
                case .full(let retryAfter):
                    job.notBefore = now().addingTimeInterval(max(retryAfter, Self.backoff(attempts: job.attempts + 1)))
                    job.lastError = "the server's upload space is full"
                    update(job)
                    return done   // nothing else fits either
                case .ticket(let ticket):
                    job.uploadID = ticket.uploadID
                    job.chunkSize = ticket.chunkSize
                    if !ticket.complete {
                        try await sendMissing(job: job, ticket: ticket, server: server, cellular: cellular, progress: progress)
                        do {
                            try await server.completeUpload(ticket.uploadID)
                        } catch APIError.http(let status, let message) where status == 400 && message.contains("mismatch") {
                            // The server dropped the chunks; hash the file again and start over next run.
                            job.sha256 = nil
                            throw APIError.http(status: status, message: message)
                        }
                    }
                    done.append(clipID)
                    jobs.removeAll { $0.clipID == clipID }
                    persist()
                }
            } catch where Self.isQuota(error) {
                // Not this clip's fault: everything waits a moment, then carries on by itself.
                let until = now().addingTimeInterval(Self.quotaCooldown)
                driveQuotaUntil = until
                job.notBefore = until
                job.lastError = error.localizedDescription
                update(job)
                return done
            } catch {
                job.attempts += 1
                job.notBefore = now().addingTimeInterval(Self.backoff(attempts: job.attempts))
                job.lastError = error.localizedDescription
                update(job)
            }
        }
        return done
    }

    /// One clip to one Drive destination: converted to MP4 (plays anywhere; the original if that fails),
    /// filed where the server's relay would put it, resumable across drops and launches, and idempotent
    /// (a finished copy of the same size is found, not uploaded twice).
    private func uploadDirect(_ job: inout DashcamUploadJob, to dest: DashcamDestination, server: DashcamUploadServer,
                              progress: @escaping @Sendable (String, Int64, Int64) -> Void) async throws {
        let clip = try await server.clipInfo(job.clipID)
        let local = URL(fileURLWithPath: job.localPath)
        var upload = local
        var converted = false
        let temp = DashcamPaths.uploadTemp.appendingPathComponent(job.clipID + ".mp4")
        if DashcamPlayable.needsRemux(local) {
            if !FileManager.default.fileExists(atPath: temp.path) { _ = try? await DashcamRemux.remux(ts: local, to: temp) }
            if FileManager.default.fileExists(atPath: temp.path) { upload = temp; converted = true }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: upload.path)[.size] as? NSNumber)?.int64Value ?? job.size
        let name = DashcamRemotePath.name(clip.name, converted: converted)
        let mime = converted || name.lowercased().hasSuffix(".mp4") ? "video/mp4"
            : name.lowercased().hasSuffix(".jpg") ? "image/jpeg" : "application/octet-stream"
        let clipID = job.clipID, destID = dest.id
        var key = try await accessFor(destID, server: server, renew: false)
        let folders = DashcamRemotePath.folders(base: key.basePath, cameraID: clip.cameraID, start: clip.start,
                                                kind: clip.kind, lens: clip.lens)
        func attempt(_ key: DashcamDriveAccess, session: URL?) async throws -> String {
            let folder = try await drive.folder(folders, access: key)
            if let id = try await drive.existing(name: name, size: size, in: folder, access: key) { return id }
            return try await drive.upload(upload, name: name, mime: mime, folder: folder, access: key, session: session,
                                          saveSession: { url in Task { await self.saveSession(clipID, destID, url) } },
                                          sent: { progress(clipID, min($0, size), size) })
        }
        let session = job.directSessions?[destID].flatMap(URL.init(string:))
        let fileID: String
        do {
            fileID = try await attempt(key, session: session)
        } catch DashcamDriveError.unauthorized {
            key = try await accessFor(destID, server: server, renew: true)
            fileID = try await attempt(key, session: session)
        } catch DashcamDriveError.sessionGone {
            saveSession(clipID, destID, nil)
            fileID = try await attempt(key, session: nil)
        }
        // A light 720p copy for streaming (the original is ~30 Mbit/s, more than LTE carries steadily).
        // Best effort: without it the player streams the original.
        var preview: (path: String, fileID: String)?
        if mime == "video/mp4" {
            let small = DashcamPaths.uploadTemp.appendingPathComponent(job.clipID + ".preview.mp4")
            var ready = FileManager.default.fileExists(atPath: small.path)
            if !ready { ready = await DashcamPreview.make(from: upload, to: small) }
            if ready {
                let previewFolders = DashcamRemotePath.folders(base: key.basePath + "/Previews", cameraID: clip.cameraID,
                                                               start: clip.start, kind: clip.kind, lens: clip.lens)
                let smallSize = (try? FileManager.default.attributesOfItem(atPath: small.path)[.size] as? NSNumber)?.int64Value ?? 0
                if let folder = try? await drive.folder(previewFolders, access: key) {
                    var id = try? await drive.existing(name: name, size: smallSize, in: folder, access: key)
                    if id == nil {
                        id = try? await drive.upload(small, name: name, mime: "video/mp4", folder: folder, access: key, session: nil,
                                                     saveSession: { _ in }, sent: { _ in })
                    }
                    if let id { preview = ((previewFolders + [name]).joined(separator: "/"), id) }
                }
                try? FileManager.default.removeItem(at: small)
            }
        }
        try await server.recordDirect(clipID: clipID, destinationID: destID,
                                      remotePath: (folders + [name]).joined(separator: "/"), fileID: fileID, size: size,
                                      preview: preview)
        if let i = jobs.firstIndex(where: { $0.clipID == clipID }) { job.directSessions = jobs[i].directSessions }
        job.directSessions?[destID] = nil
        try? FileManager.default.removeItem(at: temp)
    }

    private func accessFor(_ destID: String, server: DashcamUploadServer, renew: Bool) async throws -> DashcamDriveAccess {
        if !renew, let cached = access[destID], cached.fresh { return cached }
        let fresh = try await server.driveAccess(destinationID: destID)
        access[destID] = fresh
        return fresh
    }

    private func saveSession(_ clipID: String, _ destID: String, _ url: URL?) {
        guard let i = jobs.firstIndex(where: { $0.clipID == clipID }) else { return }
        var sessions = jobs[i].directSessions ?? [:]
        sessions[destID] = url?.absoluteString
        jobs[i].directSessions = sessions
        persist()
    }

    private func sendMissing(job: DashcamUploadJob, ticket: DashcamUploadTicket, server: DashcamUploadServer,
                             cellular: Bool, progress: @escaping @Sendable (String, Int64, Int64) -> Void) async throws {
        let chunk = max(1, ticket.chunkSize)
        let count = Self.chunkCount(size: job.size, chunk: chunk)
        let missing = (0..<count).filter { !ticket.received.contains($0) }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: job.localPath))
        defer { try? handle.close() }
        let tally = DashcamUploadTally(done: min(job.size, Int64(ticket.received.count) * Int64(chunk)))
        let clipID = job.clipID, size = job.size, uploadID = ticket.uploadID
        progress(clipID, tally.total, size)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() throws {
                guard next < missing.count else { return }
                let n = missing[next]
                next += 1
                try handle.seek(toOffset: UInt64(n) * UInt64(chunk))
                let data = try handle.read(upToCount: chunk) ?? Data()
                group.addTask {
                    try await server.sendChunk(uploadID: uploadID, index: n, data: data, cellular: cellular) { bytes in
                        tally.set(n, bytes)
                        progress(clipID, min(tally.total, size), size)
                    }
                    tally.finish(n, Int64(data.count))
                    progress(clipID, min(tally.total, size), size)
                }
            }
            for _ in 0..<Self.parallelChunks { try launch() }
            while try await group.next() != nil {
                try Task.checkCancellation()
                try launch()
            }
        }
    }

    static let parallelChunks = 3
    static let chunkSize = 4 * 1024 * 1024

    /// A stored absolute path re-anchored to this install's Documents folder when the old container
    /// no longer exists (paths look like …/Containers/Data/Application/<UUID>/Documents/Dashcam/…).
    static func resolve(_ path: String, documents: URL? = nil) -> String {
        if FileManager.default.fileExists(atPath: path) { return path }
        guard let r = path.range(of: "/Documents/") else { return path }
        let docs = documents ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(String(path[r.upperBound...])).path
    }

    static func chunkCount(size: Int64, chunk: Int) -> Int {
        guard size > 0, chunk > 0 else { return 0 }
        return Int((size + Int64(chunk) - 1) / Int64(chunk))
    }

    /// SHA-256 of a file, read 1 MiB at a time.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Each 1 MiB read is autoreleased on its own: without the pool a 1 GB clip held ~1 GB.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Bytes sent so far across the chunks in flight, for the progress bar.
final class DashcamUploadTally: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64
    private var inFlight: [Int: Int64] = [:]
    init(done: Int64) { self.done = done }
    func set(_ chunk: Int, _ bytes: Int64) { lock.lock(); inFlight[chunk] = bytes; lock.unlock() }
    func finish(_ chunk: Int, _ bytes: Int64) { lock.lock(); inFlight[chunk] = nil; done += bytes; lock.unlock() }
    var total: Int64 { lock.lock(); defer { lock.unlock() }; return done + inFlight.values.reduce(0, +) }
}

/// Passes at most a few updates a second (and always the last one) — byte-level progress would flood the UI.
final class DashcamThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    let every: TimeInterval
    init(every: TimeInterval = 0.25) { self.every = every }
    func pass(final: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard final || now.timeIntervalSince(last) >= every else { return false }
        last = now
        return true
    }
}

/// The 720p streaming copy of a clip: hardware-encoded by AVAssetExportSession, index first.
enum DashcamPreview {
    static func make(from source: URL, to out: URL) async -> Bool {
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return false }
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        if session.status != .completed {
            JcLog.devices.notice("dashcam preview failed: \(session.error?.localizedDescription ?? "?", privacy: .public)")
            try? FileManager.default.removeItem(at: out)
        }
        return session.status == .completed
    }
}
