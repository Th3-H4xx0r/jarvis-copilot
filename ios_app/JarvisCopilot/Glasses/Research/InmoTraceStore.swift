import CryptoKit
import Foundation

enum InmoTraceSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case network = "iPhone network / RVI"
    case bluetooth = "Apple Bluetooth / PacketLogger"
    case other = "Other external capture"
    var id: String { rawValue }
}

struct InmoTraceAttachment: Codable, Identifiable, Sendable {
    var id: UUID
    var originalName: String
    var storedName: String
    var source: InmoTraceSource
    var importedAt: Date
    var byteCount: Int
    var sha256: String
    var summary: InmoTraceSummary
}

struct InmoTraceNote: Codable, Identifiable, Sendable {
    var id = UUID()
    var recordedAt = Date()
    var text: String
}

struct InmoTraceSession: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var title: String
    var createdAt = Date()
    var provenance = "Externally recorded files imported by the owner; not captured by Jarvis. Source labels are owner-supplied."
    var attachments: [InmoTraceAttachment] = []
    var notes: [InmoTraceNote] = []
    var totalBytes: Int { attachments.reduce(0) { $0 + $1.byteCount } }
}

/// Actor isolates disk IO from the view and serializes manifest updates and export snapshots.
actor InmoTraceStore {
    static let shared = InmoTraceStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("INMOTraces", isDirectory: true))
    let root: URL
    private let byteLimit: Int
    private let fm = FileManager.default

    init(root: URL, byteLimit: Int = 256 * 1024 * 1024) {
        self.root = root; self.byteLimit = byteLimit
    }

    func sessions() throws -> [InmoTraceSession] {
        try prepareRoot()
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try load(UUID(uuidString: $0.lastPathComponent)!) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func create(title: String) throws -> InmoTraceSession {
        try prepareRoot()
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = InmoTraceSession(title: cleaned.isEmpty ? "INMO experiment" : String(cleaned.prefix(200)))
        let folder = directory(session.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try save(session) } catch { try? fm.removeItem(at: folder); throw error }
        return session
    }

    func importFile(_ url: URL, into id: UUID, source: InmoTraceSource) throws -> InmoTraceSession {
        var session = try load(id)
        guard session.attachments.count < 100 else { throw InmoTraceError.invalid("This session already has 100 files. Create another session.") }
        let ext = url.pathExtension.lowercased()
        guard InmoTraceInspector.allowedExtensions.contains(ext) else {
            throw InmoTraceError.invalid("Choose a .pcap, .cap, .pcapng, .pklg, .btsnoop, Bluetooth snoop .log, or capture.json file.")
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let attachmentID = UUID()
        let storedName = attachmentID.uuidString + "." + ext
        let destination = directory(id).appendingPathComponent(storedName)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: destination) } }
        // Coordinate cloud/document-provider reads. Copy in bounded chunks rather than loading a trace into RAM.
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readable in
            do { try copyBounded(readable, to: destination, limit: byteLimit - session.totalBytes) }
            catch { copyError = error }
        }
        if let error = coordinatorError { throw error }
        if let error = copyError { throw error }
        let summary = try InmoTraceInspector.inspect(destination)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let hash = try Self.hash(destination)
        session.attachments.append(InmoTraceAttachment(id: attachmentID, originalName: url.lastPathComponent,
            storedName: storedName, source: source, importedAt: Date(), byteCount: size, sha256: hash, summary: summary))
        try save(session)
        committed = true
        return session
    }

    func addNote(_ text: String, to id: UUID) throws -> InmoTraceSession {
        var session = try load(id)
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 4_000, session.notes.count < 1_000 else {
            throw InmoTraceError.invalid("Enter 1–4,000 characters (up to 1,000 notes per session).")
        }
        session.notes.append(InmoTraceNote(text: cleaned))
        try save(session)
        return session
    }

    func delete(_ id: UUID) throws { try fm.removeItem(at: directory(id)) }

    func export(_ id: UUID) throws -> URL {
        let session = try load(id)
        let work = fm.temporaryDirectory.appendingPathComponent("INMOExport-" + UUID().uuidString, isDirectory: true)
        let snapshot = work.appendingPathComponent("INMO-" + id.uuidString, isDirectory: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? fm.removeItem(at: work) } }
        try encode(session).write(to: snapshot.appendingPathComponent("manifest.json"), options: .atomic)
        for file in session.attachments {
            // Only UUID-generated local names; validate even when reading a damaged manifest.
            guard file.storedName == file.id.uuidString + "." + URL(fileURLWithPath: file.storedName).pathExtension,
                  InmoTraceInspector.allowedExtensions.contains(URL(fileURLWithPath: file.storedName).pathExtension) else {
                throw InmoTraceError.invalid("Invalid stored trace filename.")
            }
            let original = directory(id).appendingPathComponent(file.storedName)
            guard try Self.hash(original) == file.sha256 else { throw InmoTraceError.invalid("Trace integrity check failed for \(file.originalName).") }
            try fm.copyItem(at: original, to: snapshot.appendingPathComponent(file.storedName))
        }
        let readme = """
        INMO official-app trace evidence — schema 1
        Originals are unchanged. manifest.json maps original names to stored files and SHA-256 hashes.
        Source labels are supplied by the owner, not verified app attribution. Import/note times are
        not packet times. PacketLogger files are opaque here; use Apple's PacketLogger or Wireshark.
        PCAP summaries describe container records, not decoded INMO commands. Encrypted content remains
        encrypted. A trace may contain unrelated phone traffic and private data. No complete-capture claim.
        Session notes may describe actions performed in INMO; correlate their stated times with the trace.
        """
        try Data(readme.utf8).write(to: snapshot.appendingPathComponent("README.txt"))
        // Foundation provides a temporary ZIP for a directory coordinated for uploading.
        let output = work.appendingPathComponent("INMO-" + id.uuidString + ".zip")
        var coordinatorError: NSError?, exportError: Error?
        NSFileCoordinator().coordinate(readingItemAt: snapshot, options: .forUploading, error: &coordinatorError) { archive in
            do { try fm.copyItem(at: archive, to: output) } catch { exportError = error }
        }
        if let error = coordinatorError { throw error }
        if let error = exportError { throw error }
        guard fm.fileExists(atPath: output.path) else { throw InmoTraceError.invalid("Archive export did not produce a file.") }
        try fm.removeItem(at: snapshot)
        success = true
        return output
    }

    private func prepareRoot() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var path = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try path.setResourceValues(values)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
    }

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func load(_ id: UUID) throws -> InmoTraceSession {
        let data = try Data(contentsOf: directory(id).appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(InmoTraceSession.self, from: data)
        guard result.schemaVersion == 1, result.id == id else { throw InmoTraceError.invalid("Unsupported or mismatched capture manifest.") }
        return result
    }
    private func encode(_ session: InmoTraceSession) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(session)
    }
    private func save(_ session: InmoTraceSession) throws {
        try encode(session).write(to: directory(session.id).appendingPathComponent("manifest.json"), options: .atomic)
    }
    private func copyBounded(_ source: URL, to target: URL, limit: Int) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= limit else {
            throw InmoTraceError.invalid("Choose a nonempty trace. Each session can contain at most \(byteLimit / 1024 / 1024) MiB of originals.")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fm.createFile(atPath: target.path, contents: nil) else { throw InmoTraceError.invalid("Could not create local trace copy.") }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var copied = 0
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            copied += chunk.count
            guard copied <= limit else { throw InmoTraceError.invalid("Trace grew beyond the session size limit while importing.") }
            try output.write(contentsOf: chunk)
        }
        guard copied == size else { throw InmoTraceError.invalid("Trace changed during import. Stop the capture before importing it.") }
        try output.synchronize()
    }
    private static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
