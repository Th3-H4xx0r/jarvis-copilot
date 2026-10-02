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

    /// A new session: the file starts over.
    static func reset(_ title: String) {
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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

    /// The first `n` events of a kind, then every `every`-th — packet-level detail without flooding.
    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let first: Int, every: Int
        init(first: Int = 25, every: Int = 500) { self.first = first; self.every = every }
        func next() -> Int? {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count <= first || count % every == 0 ? count : nil
        }
    }
}
