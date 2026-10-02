import CryptoKit
import Foundation

/// Where transfer bookkeeping lives (resume data, the upload queue).
enum DashcamPaths {
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
}

/// Anything that can take a chunk upload (the server, or a fake in tests).
protocol DashcamUploadServer: Sendable {
    func startUpload(clipID: String, size: Int64, sha256: String) async throws -> DashcamAPI.UploadStart
    func sendChunk(uploadID: String, index: Int, data: Data, cellular: Bool) async throws
    func completeUpload(_ uploadID: String) async throws
}

extension DashcamAPI: DashcamUploadServer {
    /// Chunks get their own session that fails fast when the network is gone — the shared one waits
    /// up to an hour for connectivity, which would hold the whole upload queue.
    static let chunkSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 900
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()

    func sendChunk(uploadID: String, index: Int, data: Data, cellular: Bool) async throws {
        var req = try api.request("POST", Self.prefix + "/uploads/\(uploadID)/chunk", query: ["n": String(index)],
                                  headers: ["Content-Type": "application/octet-stream"], body: data, timeout: 120)
        req.allowsCellularAccess = cellular
        let (body, resp) = try await Self.chunkSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, message: APIError.message(status: http.statusCode, body: body))
        }
    }
}

/// Sends finished downloads to the server in 16 MiB chunks. Resumable: the server keeps the
/// chunks it has and says which on every (re)start, so a dropped connection costs one chunk.
actor DashcamUploader {
    static let shared = DashcamUploader()

    private(set) var jobs: [DashcamUploadJob] = []
    private let file: URL
    private var running = false
    static let maxBackoff: TimeInterval = 600

    init(file: URL? = nil) {
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
        for i in jobs.indices { jobs[i].notBefore = nil }
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
    /// data: normal footage then waits for Wi‑Fi, events and photos still go.
    /// Returns the clip ids that reached the server.
    @discardableResult
    func run(server: DashcamUploadServer, cellular: Bool, now: @Sendable () -> Date = { Date() },
             progress: @Sendable (String, Int64, Int64) -> Void = { _, _, _ in }) async -> [String] {
        guard !running else { return [] }
        running = true
        defer { running = false }
        var done: [String] = []
        for clipID in jobs.map(\.clipID) {
            guard let index = jobs.firstIndex(where: { $0.clipID == clipID }) else { continue }
            var job = jobs[index]
            if let nb = job.notBefore, nb > now() { continue }
            // Normal footage never goes over mobile data; events and photos may.
            if cellular && job.kind == .normal { continue }
            // The app container moves on every reinstall/update: re-anchor the stored path.
            let path = Self.resolve(job.localPath)
            guard FileManager.default.fileExists(atPath: path) else {
                jobs.removeAll { $0.clipID == clipID }; persist(); continue
            }
            if path != job.localPath { job.localPath = path; update(job) }
            do {
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
                    job.notBefore = now().addingTimeInterval(3600)
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
            } catch {
                job.attempts += 1
                job.notBefore = now().addingTimeInterval(Self.backoff(attempts: job.attempts))
                job.lastError = error.localizedDescription
                update(job)
            }
        }
        return done
    }

    private func sendMissing(job: DashcamUploadJob, ticket: DashcamUploadTicket, server: DashcamUploadServer,
                             cellular: Bool, progress: @Sendable (String, Int64, Int64) -> Void) async throws {
        let chunk = max(1, ticket.chunkSize)
        let count = Self.chunkCount(size: job.size, chunk: chunk)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: job.localPath))
        defer { try? handle.close() }
        var sent = Int64(ticket.received.count) * Int64(chunk)
        for n in 0..<count where !ticket.received.contains(n) {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(n) * UInt64(chunk))
            let data = try handle.read(upToCount: chunk) ?? Data()
            try await server.sendChunk(uploadID: ticket.uploadID, index: n, data: data, cellular: cellular)
            sent += Int64(data.count)
            progress(job.clipID, min(sent, job.size), job.size)
        }
    }

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
