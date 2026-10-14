import Foundation

/// The app's line to jc-client: `~/.jarviscopilot-client/ui.sock`, newline JSON
/// (see desktop_client/jc_client/ui_server.py). jc-client pushes `hello`,
/// `sessions`, `pending`, `usage`, `config` and `topic` messages; requests carry
/// an `id` and get one `reply`. Reconnects on its own every 2 s while jc-client
/// is down — the island then shows "Jarvis isn't running".
final class JcLink: @unchecked Sendable {
    static let shared = JcLink()

    /// Every pushed message, on the main actor.
    var onMessage: (@MainActor ([String: Any]) -> Void)?
    var onConnection: (@MainActor (Bool) -> Void)?

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var nextId = 1
    private var replies: [Int: ([String: Any]) -> Void] = [:]
    private var started = false

    static var socketPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".jarviscopilot-client/ui.sock")
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "jc-link"
        thread.start()
    }

    /// Send a request; `reply` runs on the main actor with the answer (or
    /// `["ok": false]` when the link is down).
    func request(_ body: [String: Any], reply: (@MainActor ([String: Any]) -> Void)? = nil) {
        var msg = body
        lock.lock()
        let id = nextId
        nextId += 1
        msg["id"] = id
        if let reply {
            replies[id] = { answer in DispatchQueue.main.async { MainActor.assumeIsolated { reply(answer) } } }
        }
        let fd = self.fd
        lock.unlock()
        guard fd >= 0, let data = try? JSONSerialization.data(withJSONObject: msg) else {
            fail(id)
            return
        }
        var line = data
        line.append(0x0A)
        let ok = line.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        if !ok { fail(id) }
    }

    private func fail(_ id: Int) {
        lock.lock()
        let cb = replies.removeValue(forKey: id)
        lock.unlock()
        cb?(["ok": false, "error": "Jarvis isn't running on this Mac"])
    }

    // MARK: the read loop (its own thread)

    private func loop() {
        while true {
            let s = connectSocket()
            guard s >= 0 else {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            lock.lock()
            fd = s
            lock.unlock()
            notifyConnection(true)
            readLines(s)
            lock.lock()
            fd = -1
            let pendingReplies = replies
            replies = [:]
            lock.unlock()
            for (_, cb) in pendingReplies { cb(["ok": false, "error": "the link dropped"]) }
            close(s)
            notifyConnection(false)
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func connectSocket() -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Self.socketPath
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else { close(s); return -1 }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { _ = strncpy($0, path, maxLen) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, size) }
        }
        if rc != 0 { close(s); return -1 }
        return s
    }

    private func readLines(_ s: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(s, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                dispatch(obj)
            }
        }
    }

    private func dispatch(_ obj: [String: Any]) {
        if J.s(obj["type"]) == "reply", let id = obj["id"] as? Int {
            lock.lock()
            let cb = replies.removeValue(forKey: id)
            lock.unlock()
            cb?(obj)
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onMessage?(obj) }
        }
    }

    private func notifyConnection(_ up: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onConnection?(up) }
        }
    }
}
