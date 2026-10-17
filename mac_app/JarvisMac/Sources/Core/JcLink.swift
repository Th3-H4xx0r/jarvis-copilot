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
        send(body, onReply: reply.map { reply in
            { answer in DispatchQueue.main.async { MainActor.assumeIsolated { reply(answer) } } }
        })
    }

    /// Send a request and wait on this thread for its reply, at most `timeout`
    /// (nil when it times out). For the will-sleep notification: the Mac must
    /// not sleep before jc-client has flushed its transcripts and said so.
    func requestAndWait(_ body: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        let done = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        send(body) { answer in
            box.set(answer)
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? box.get() : nil
    }

    private func send(_ body: [String: Any], onReply: (([String: Any]) -> Void)?) {
        var msg = body
        lock.lock()
        let id = nextId
        nextId += 1
        msg["id"] = id
        if let onReply {
            replies[id] = onReply
        }
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else {
            fail(id)
            return
        }
        var line = data
        line.append(0x0A)
        // Off the main thread, and with the lock held so the read loop can't
        // close (and the system reuse) the descriptor mid-write.
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let fd = self.fd
            let ok = fd >= 0 && line.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, base.advanced(by: sent), raw.count - sent)
                    if n <= 0 { return false }
                    sent += n
                }
                return true
            }
            self.lock.unlock()
            if !ok { self.fail(id) }
        }
    }

    private let writeQueue = DispatchQueue(label: "jc-link.write")

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
        // A write after jc-client closes the socket must fail, not kill the app.
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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

/// One reply handed from the read thread to a waiting caller.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any]?
    func set(_ v: [String: Any]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
}
