import Foundation

/// One frame waiting to go up the socket.
///
/// Opaque on purpose: the spool must not need to understand the protocol to
/// replay it in order. `text` is an already-encoded JSON envelope, `binary` an
/// already-framed audio packet.
enum LiveOutbound: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

enum LiveSpoolError: LocalizedError, Equatable {
    /// The spool hit its byte bound. Design §8: this stops capture with a loud
    /// visible state — it does NOT silently drop, because the whole point of the
    /// bound is to be noticed instead of losing hours.
    case full(bytes: Int, limit: Int)
    /// The disk refused the write (no space, or a sandbox problem).
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .full(let bytes, let limit):
            return "Live Jarvis has \(LiveFormat.bytes(bytes)) of unsent audio waiting "
                 + "and its \(LiveFormat.bytes(limit)) buffer is full."
        case .unwritable(let why):
            return "Live Jarvis can't write to storage: \(why)"
        }
    }
}

/// A bounded, ordered, crash-surviving on-disk queue of frames the socket could
/// not take.
///
/// Design §8 calls a dropped socket the NORMAL path — the cross-device mirror work
/// proved a real iPhone loses a long-lived stream roughly once a minute — so this
/// is not an error path. Capture keeps running into the spool and the spool drains
/// on reconnect.
///
/// **Format.** One record per line, `T <base64-of-utf8-json>` or `B <base64>`,
/// preceded by a `S <live_session_id>` header line and a `C <codec>` one. Base64
/// because it cannot contain a newline, which is what makes line-splitting a safe
/// framing for arbitrary audio bytes. A partially-written final line (killed
/// mid-append) fails to decode and is discarded, costing one frame rather than the
/// file. A file written before `C` existed is read as `pcm16`, which is not a
/// guess: PCM16 is the only thing this app has ever queued.
///
/// **Nothing here ever deletes conversation on its own.** Every discard is either
/// something the caller explicitly asked for (`reset`) or a record that could not
/// be parsed at all. A file that exists but cannot be read is MOVED ASIDE rather
/// than overwritten, because "unreadable" and "absent" are wildly different
/// situations and only one of them is safe to write over.
///
/// **Not an actor.** Every caller is already on the main actor and the appends are
/// small; an actor here would only add hops between the audio callback and the file.
@MainActor
final class LiveSpool {

    /// ~48 MB. At 16 kHz mono PCM16 (32 kB/s) base64-inflated by a third, that is
    /// roughly eighteen minutes of unsent audio — far more than the once-a-minute
    /// drop needs, and small enough to be an honest bound on a phone.
    static let defaultLimitBytes = 48 * 1024 * 1024

    private let directory: URL
    private let limitBytes: Int
    private let fileManager: FileManager

    /// A queued frame and the bytes it costs on disk, kept together so a drain can
    /// adjust `byteCount` by subtraction instead of re-encoding the remainder —
    /// which, on a 30 MB spool, it was doing from inside the audio callback.
    private struct Record {
        let frame: LiveOutbound
        let cost: Int
    }

    /// Records held right now, oldest first. Kept in memory as well as on disk: the
    /// audio callback appends often, and re-reading the file to count would put
    /// file I/O on every frame.
    private var records: [Record] = []
    private(set) var byteCount = 0
    /// The live session these records belong to. Replaying a previous session's
    /// audio into a new one would attribute a conversation to the wrong transcript.
    private(set) var sessionID = ""
    /// The encoding the queued audio is in — `"pcm16"` or `"opus-packets"`.
    ///
    /// The records are opaque bytes and the codec is declared ONCE per socket, in
    /// `hello`, for everything that follows it. So the codec has to be remembered
    /// with the queue: draining PCM16 records over a socket that declared Opus
    /// would file raw samples in a chunk labelled `opus-packets-len32@48000`, and
    /// a recording that cannot be decoded is worse than one that was never sent.
    private(set) var codec = ""
    /// False once a disk write failed. The class claims to survive a crash; when it
    /// cannot, the caller has to be able to say so rather than keep the promise.
    private(set) var isDurable = true
    /// Set when a file was found that could not be parsed. It is moved aside, not
    /// deleted, and this names where it went.
    private(set) var quarantinedFile: String?

    var count: Int { records.count }
    var isEmpty: Bool { records.isEmpty }
    /// How full the spool is, 0...1 — the status line turns this into a warning
    /// before it becomes a stop.
    var fill: Double { limitBytes <= 0 ? 0 : min(Double(byteCount) / Double(limitBytes), 1) }

    /// `directory` is injected so a test can use a temp dir; production passes nil
    /// and gets Application Support (NOT Caches, which iOS may evict — evicting
    /// unsent conversation is the silent loss this class exists to prevent).
    ///
    /// `limitBytes` is an optional rather than a defaulted `defaultLimitBytes`: a
    /// default argument cannot reference a `@MainActor` static, the same limitation
    /// worked around in `LiveCaptureSources` and `AudioSessionArbiter`.
    init(directory: URL? = nil,
         limitBytes: Int? = nil,
         fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.limitBytes = limitBytes ?? Self.defaultLimitBytes
        if let directory {
            self.directory = directory
        } else {
            let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = root.appendingPathComponent("JarvisLive/spool", isDirectory: true)
        }
        load()
    }

    private var file: URL { directory.appendingPathComponent("outbox.log") }

    // MARK: - Session identity

    /// Bind the spool to a live session.
    ///
    /// An UNBOUND spool (`sessionID == ""`) adopts whatever it is given and KEEPS
    /// what it holds: that is the ordinary case of audio captured between tapping
    /// Record and the server answering with an id, and it used to be deleted the
    /// moment `ready` arrived — the opening of every recording, and the whole of an
    /// offline one.
    ///
    /// A spool bound to a DIFFERENT session is a conversation that has since ended.
    /// Those records are moved aside under their own id rather than dropped, so they
    /// can still be recovered, and the caller is told so it can say something.
    func adopt(sessionID id: String) {
        guard !id.isEmpty, sessionID != id else {
            if sessionID.isEmpty { sessionID = id }
            persist()
            return
        }
        if !sessionID.isEmpty, !records.isEmpty {
            quarantine(reason: "session-\(sessionID)")
            records.removeAll()
            byteCount = 0
        }
        sessionID = id
        persist()
    }

    /// Bind the spool to an audio encoding.
    ///
    /// Two real situations change it: a relaunch on an OS whose CoreAudio refuses
    /// Opus when the previous launch's did not (or the reverse), and an encoder
    /// that fails mid-capture and is honestly abandoned. In both, records in the
    /// OTHER encoding cannot go up this socket — so they are moved aside under
    /// their own codec's name, exactly as a previous session's are, and never
    /// deleted.
    func adopt(codec name: String) {
        guard !name.isEmpty, codec != name else {
            if codec.isEmpty { codec = name }
            persist()
            return
        }
        if !codec.isEmpty, !records.isEmpty {
            quarantine(reason: "codec-\(codec)")
            records.removeAll()
            byteCount = 0
        }
        codec = name
        persist()
    }

    // MARK: - Queueing

    /// Add a frame. Throws `.full` when it would cross the bound — the caller must
    /// then stop capture and say so loudly.
    func append(_ frame: LiveOutbound) throws {
        let line = Self.encode(frame)
        guard let data = (line + "\n").data(using: .utf8) else {
            throw LiveSpoolError.unwritable("could not encode a frame for the buffer")
        }
        let cost = data.count
        guard byteCount + cost <= limitBytes else {
            throw LiveSpoolError.full(bytes: byteCount, limit: limitBytes)
        }
        records.append(Record(frame: frame, cost: cost))
        byteCount += cost
        try appendData(data)
    }

    /// Put frames back at the HEAD of the queue, in their original order.
    ///
    /// For frames that were handed to a socket which then died: `URLSessionWebSocket`
    /// reports a send failure asynchronously, so "written" is not "delivered", and
    /// anything in that window has to go back in front of whatever has been queued
    /// since or the transcript arrives out of order.
    func prepend(_ frames: [LiveOutbound]) throws {
        guard !frames.isEmpty else { return }
        var restored: [Record] = []
        var added = 0
        for frame in frames {
            let line = Self.encode(frame)
            guard let data = (line + "\n").data(using: .utf8) else { continue }
            restored.append(Record(frame: frame, cost: data.count))
            added += data.count
        }
        guard byteCount + added <= limitBytes else {
            throw LiveSpoolError.full(bytes: byteCount + added, limit: limitBytes)
        }
        records.insert(contentsOf: restored, at: 0)
        byteCount += added
        persist()
    }

    /// Replay in order. `send` returns false when the socket refused, which stops
    /// the drain with the rest of the queue intact — a half-drained spool that
    /// forgot the remainder is the same data loss as no spool at all.
    ///
    /// `limit` bounds one drain so recovering a large backlog does not block the
    /// main actor (and the audio callback behind it) for the whole upload. The
    /// caller drains again until `isEmpty`.
    ///
    /// Returns how many frames went out.
    @discardableResult
    func drain(limit: Int = Int.max, _ send: (LiveOutbound) -> Bool) -> Int {
        var sent = 0
        var freed = 0
        for record in records {
            guard sent < limit else { break }
            guard send(record.frame) else { break }
            sent += 1
            freed += record.cost
        }
        guard sent > 0 else { return 0 }
        records.removeFirst(sent)
        byteCount = max(byteCount - freed, 0)
        persist()
        return sent
    }

    /// Throw everything away. Only ever called for something the user asked for —
    /// see the type comment.
    func reset() {
        records.removeAll()
        byteCount = 0
        // Cleared too, so a spool reused for a NEW recording starts unbound and
        // keeps whatever it captures before that recording has an id.
        sessionID = ""
        codec = ""
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: file) else {
            // No file. The ordinary first-run case, and the only one it is safe to
            // write over.
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            // The file EXISTS but is not readable text. Overwriting it would destroy
            // whatever it held, so it is moved aside instead and the caller told.
            JcLog.voice.error("live spool: unreadable file, moving it aside")
            quarantine(reason: "corrupt")
            return
        }
        var restored: [Record] = []
        var bytes = 0
        var discarded = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            if line.hasPrefix("S ") {
                sessionID = String(line.dropFirst(2))
                continue
            }
            if line.hasPrefix("C ") {
                codec = String(line.dropFirst(2))
                continue
            }
            guard let frame = Self.decode(line) else {
                // A torn final line from a kill mid-append. One frame, not the file.
                discarded += 1
                continue
            }
            restored.append(Record(frame: frame, cost: line.utf8.count + 1))
            bytes += line.utf8.count + 1
        }
        records = restored
        byteCount = bytes
        // A file with records but no codec line was written by a build that only
        // ever queued PCM16. Leaving it untagged would let an Opus launch adopt
        // those samples and send them up under an Opus label.
        if codec.isEmpty, !restored.isEmpty { codec = "pcm16" }
        if discarded > 0 {
            JcLog.voice.notice("live spool: discarded \(discarded, privacy: .public) unreadable records")
        }
        if !restored.isEmpty {
            JcLog.voice.notice("live spool: recovered \(restored.count, privacy: .public) unsent records")
        }
    }

    /// Move the current file out of the way under a new name. Never deletes: the
    /// bytes may be the only copy of part of a conversation.
    private func quarantine(reason: String) {
        guard fileManager.fileExists(atPath: file.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "outbox.\(reason).\(stamp).log"
        let destination = directory.appendingPathComponent(name)
        do {
            try fileManager.moveItem(at: file, to: destination)
            quarantinedFile = name
        } catch {
            JcLog.dropped(JcLog.voice, "quarantine the live spool file", error)
        }
    }

    /// Append one line without rewriting the file — the hot path, hit once per
    /// audio frame while the socket is down.
    private func appendData(_ data: Data) throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                // First write of a fresh file, or the header was never laid down.
                try headerAndBody().write(to: file, options: .atomic)
            }
            isDurable = true
        } catch {
            isDurable = false
            throw LiveSpoolError.unwritable(error.localizedDescription)
        }
    }

    /// Rewrite the whole file. Only after a drain, an adopt or a reset — never per
    /// frame.
    private func persist() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try headerAndBody().write(to: file, options: .atomic)
            isDurable = true
        } catch {
            // The in-memory queue is intact, so capture continues — but the promise
            // that it survives a relaunch is now false, and `isDurable` is what lets
            // the status line say so instead of the class quietly lying.
            isDurable = false
            JcLog.dropped(JcLog.voice, "persist live spool", error)
        }
    }

    private func headerAndBody() throws -> Data {
        var text = "S \(sessionID)\n"
        if !codec.isEmpty { text += "C \(codec)\n" }
        for record in records { text += Self.encode(record.frame) + "\n" }
        guard let data = text.data(using: .utf8) else {
            throw LiveSpoolError.unwritable("could not encode the spool")
        }
        return data
    }

    // MARK: - Line codec (pure — the part the tests pin)

    static func encode(_ frame: LiveOutbound) -> String {
        switch frame {
        case .text(let s):
            return "T " + Data(s.utf8).base64EncodedString()
        case .binary(let d):
            return "B " + d.base64EncodedString()
        }
    }

    static func decode(_ line: String) -> LiveOutbound? {
        guard line.count > 2 else { return nil }
        let body = String(line.dropFirst(2))
        guard let data = Data(base64Encoded: body) else { return nil }
        if line.hasPrefix("T ") {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return .text(text)
        }
        if line.hasPrefix("B ") { return .binary(data) }
        return nil
    }
}
