import Darwin
import Foundation
import os

/// The WebSocket the bridge talks to (URLSessionWebSocketTask in the app, a fake in tests).
protocol RdpWebSocketLink: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func cancel()
}

final class URLSessionRdpLink: RdpWebSocketLink {
    private let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = 16 * 1024 * 1024
    }
    func resume() { task.resume() }
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
        task.send(message, completionHandler: completion)
    }
    func receive(completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        task.receive(completionHandler: completion)
    }
    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}

/// FreeRDP speaks TCP; the phone reaches the PC only through Jarvis's relay
/// (`wss …/api/rdp/relay/<session>` → the PC's Tailscale address :3389). The bridge listens on a
/// random 127.0.0.1 port, takes FreeRDP's one connection and moves bytes both ways.
///
/// The relay's rules (webui/api/rdp_relay.py, like tcp_relay): the RDP stream is BINARY frames
/// only; TEXT frames are keepalives that both ends drop. The proxy chain in front of the server
/// holds the last frame of a quiet WebSocket until something follows it, so the bridge sends a
/// tiny TEXT "k" right after every data frame (RDP's handshake is one small frame then a wait —
/// without the push the PC never sees FreeRDP's connection request and times out after 10 s) and
/// every 3 s while idle. Incoming TEXT frames are ignored, never written to FreeRDP.
/// RDP's own TLS runs end to end: the bridge and the server only see ciphertext.
final class RdpLoopbackBridge: @unchecked Sendable {
    static let keepalive: TimeInterval = 3
    private static let log = Logger(subsystem: "com.jarviscopilot", category: "rdp-bridge")

    private let request: URLRequest
    private let makeLink: (URLRequest) -> RdpWebSocketLink
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var link: RdpWebSocketLink?
    private var closed = false
    private var lastSend = Date.distantPast
    private var timer: DispatchSourceTimer?
    /// Why it closed (diagnostics only).
    private(set) var closeReason: String?
    /// Bytes moved (to the PC / from the PC), for the quality indicator and the log.
    private(set) var bytesOut = 0
    private(set) var bytesIn = 0
    private(set) var textIgnored = 0
    var onClose: (() -> Void)?
    /// How often an idle bridge sends its TEXT "k" (the relay's own cadence).
    var keepaliveEvery: TimeInterval = RdpLoopbackBridge.keepalive

    init(request: URLRequest, makeLink: ((URLRequest) -> RdpWebSocketLink)? = nil) {
        self.request = request
        self.makeLink = makeLink ?? { req in
            URLSessionRdpLink(task: URLSession(configuration: .ephemeral).webSocketTask(with: req))
        }
    }

    /// Starts listening; returns the loopback port FreeRDP should connect to.
    func start() async throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenFD = fd
        let port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        Self.log.info("listening on 127.0.0.1:\(port, privacy: .public)")
        return port
    }

    private func acceptLoop() {
        let fd = accept(listenFD, nil, nil)   // one connection per session
        lock.lock()
        let wasClosed = closed
        if !wasClosed { clientFD = fd }
        if listenFD >= 0 { Darwin.close(listenFD) }
        listenFD = -1
        lock.unlock()
        guard fd >= 0, !wasClosed else { if fd >= 0 { Darwin.close(fd) }; return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let link = makeLink(request)
        self.link = link
        link.resume()
        Self.log.info("FreeRDP connected; WebSocket opening")
        startKeepalive()
        pumpWS()
        pumpTCP(fd)
    }

    /// Sends one message and waits for it (pacing the TCP reads: backpressure).
    private func sendSync(_ message: URLSessionWebSocketTask.Message) -> Error? {
        guard let link else { return POSIXError(.ENOTCONN) }
        let done = DispatchSemaphore(value: 0)
        var failed: Error?
        link.send(message) { error in failed = error; done.signal() }
        done.wait()
        lock.lock(); lastSend = Date(); lock.unlock()
        return failed
    }

    /// TCP → WebSocket on this thread: each read goes out at once as a BINARY frame, then a TEXT
    /// "k" pushes it past the proxy.
    private func pumpTCP(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !closed {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { close(n == 0 ? "FreeRDP closed" : "tcp read errno \(errno)"); return }
            bytesOut += n
            if let e = sendSync(.data(Data(buffer[0..<n]))) { close("websocket send: \(e.localizedDescription)"); return }
            if let e = sendSync(.string("k")) { close("websocket send: \(e.localizedDescription)"); return }
            if bytesOut == n { Self.log.info("first \(n, privacy: .public) bytes to the PC sent") }
        }
    }

    /// WebSocket → TCP: BINARY frames only; TEXT keepalives are dropped.
    private func pumpWS() {
        link?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error): self.close("websocket: \(error.localizedDescription)")
            case .success(.data(let data)):
                if self.bytesIn == 0 { Self.log.info("first \(data.count, privacy: .public) bytes from the PC") }
                self.bytesIn += data.count
                if !self.writeAll(data) { self.close("tcp write errno \(errno)"); return }
                self.pumpWS()
            case .success:
                self.textIgnored += 1   // the relay's "k" — never part of the RDP stream
                self.pumpWS()
            }
        }
    }

    private func startKeepalive() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + keepaliveEvery, repeating: keepaliveEvery)
        t.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.lock.lock(); let idle = Date().timeIntervalSince(self.lastSend); self.lock.unlock()
            if idle >= self.keepaliveEvery - 0.05 {
                self.link?.send(.string("k")) { _ in }
                self.lock.lock(); self.lastSend = Date(); self.lock.unlock()
            }
            Self.log.debug("bytes to PC \(self.bytesOut, privacy: .public) from PC \(self.bytesIn, privacy: .public)")
        }
        timer = t
        t.resume()
    }

    private func writeAll(_ data: Data) -> Bool {
        lock.lock(); let fd = clientFD; lock.unlock()
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    func close(_ reason: String = "closed") {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        closeReason = reason
        let fd = clientFD, lfd = listenFD
        clientFD = -1
        listenFD = -1
        lock.unlock()
        timer?.cancel()
        link?.cancel()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        if lfd >= 0 { shutdown(lfd, SHUT_RDWR); Darwin.close(lfd) }
        Self.log.info("closed (\(reason, privacy: .public)): to PC \(self.bytesOut, privacy: .public) B, from PC \(self.bytesIn, privacy: .public) B, ignored \(self.textIgnored, privacy: .public) text")
        let done = onClose
        DispatchQueue.main.async { done?() }
    }

    deinit { close("released") }
}
