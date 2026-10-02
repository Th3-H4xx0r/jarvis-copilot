import Foundation

/// A plain-text trace of the last live-view session, in Documents/Dashcam/live-trace.log, so a failure
/// on the real camera can be read off the phone (`devicectl … copy from`) instead of guessed at. Holds
/// the camera's stream info, every RTSP exchange, packet counts and why frames didn't decode.
enum DashcamLiveTrace {
    private static let queue = DispatchQueue(label: "jc.dashcam.livetrace")
    private static let maxBytes = 400_000
    nonisolated(unsafe) private static var written = 0
    nonisolated(unsafe) private static var started = Date()

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dashcam", isDirectory: true).appendingPathComponent("live-trace.log")
    }

    nonisolated(unsafe) private static var session = 0
    nonisolated(unsafe) private static var captured = 0
    static let captureLimit = 3_000_000

    /// The raw interleaved frames of a session (channel byte, 2-byte length, payload — RTSP's own `$`
    /// framing without the `$`), for replaying the camera's real stream on a Mac.
    static var captureURL: URL { url.deletingLastPathComponent().appendingPathComponent("live-capture.bin") }

    /// A new session: the files start over and the samplers count from zero.
    static func reset(_ title: String) {
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            session += 1
            captured = 0
            try? Data().write(to: captureURL, options: .atomic)
            started = Date()
            let head = "== \(title) \(ISO8601DateFormatter().string(from: started))\n"
            try? Data(head.utf8).write(to: url, options: .atomic)
            written = head.utf8.count
        }
    }

    static func log(_ line: @autoclosure () -> String) {
        let text = line()
        queue.async {
            guard written < maxBytes, let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            let stamped = String(format: "%7.3f ", Date().timeIntervalSince(started)) + text + "\n"
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(stamped.utf8))
            written += stamped.utf8.count
        }
    }

    static func capture(channel: UInt8, _ payload: Data) {
        queue.async {
            guard captured < captureLimit, let h = try? FileHandle(forWritingTo: captureURL) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            let frame = Data([channel, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) + payload
            try? h.write(contentsOf: frame)
            captured += frame.count
        }
    }

    /// Which session a sampler's count belongs to (read on the trace queue's side is fine: a stale read
    /// only means one extra or one missing line).
    static var currentSession: Int { queue.sync { session } }

    /// The first `n` events of a kind in each session, then every `every`-th — detail without flooding.
    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var session = -1
        let first: Int, every: Int
        init(first: Int = 25, every: Int = 500) { self.first = first; self.every = every }
        func next() -> Int? {
            let now = DashcamLiveTrace.currentSession
            lock.lock(); defer { lock.unlock() }
            if now != session { session = now; count = 0 }
            count += 1
            return count <= first || count % every == 0 ? count : nil
        }
    }
}
