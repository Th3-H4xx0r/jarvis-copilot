import Darwin
import Foundation

/// FreeRDP speaks TCP; the phone reaches the PC only through Jarvis's relay
/// (`wss …/api/rdp/relay/<session>` → the PC's Tailscale address :3389). The bridge listens on a
/// random 127.0.0.1 port, takes FreeRDP's one connection and moves bytes both ways as binary
/// WebSocket frames. RDP's own TLS runs end to end: the bridge and the server only see ciphertext.
/// Plain BSD sockets (one accept, blocking reads on a thread): simple and predictable.
final class RdpLoopbackBridge: @unchecked Sendable {
    private let request: URLRequest
    private let session: URLSession
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var socket: URLSessionWebSocketTask?
    private var closed = false
    /// Why it closed (diagnostics only).
    private(set) var closeReason: String?
    /// Bytes moved, for the quality indicator.
    private(set) var bytesIn = 0
    private(set) var bytesOut = 0
    var onClose: (() -> Void)?

    init(request: URLRequest, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.request = request
        self.session = session
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
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 16 * 1024 * 1024
        socket = ws
        ws.resume()
        pumpWS()
        pumpTCP(fd)
    }

    /// TCP → WebSocket on this thread: each send completes before the next read (backpressure).
    private func pumpTCP(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !closed {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { close(n == 0 ? "tcp closed" : "tcp read \(errno)"); return }
            bytesOut += n
            let done = DispatchSemaphore(value: 0)
            var failed: Error?
            socket?.send(.data(Data(buffer[0..<n]))) { error in failed = error; done.signal() }
            done.wait()
            if let failed { close("websocket send: \(failed.localizedDescription)"); return }
        }
    }

    /// WebSocket → TCP.
    private func pumpWS() {
        socket?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error): self.close("websocket: \(error.localizedDescription)")
            case .success(let message):
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                self.bytesIn += data.count
                if !self.writeAll(data) { self.close("tcp write \(errno)"); return }
                self.pumpWS()
            }
        }
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
        socket?.cancel(with: .normalClosure, reason: nil)
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        if lfd >= 0 { shutdown(lfd, SHUT_RDWR); Darwin.close(lfd) }
        let done = onClose
        DispatchQueue.main.async { done?() }
    }

    deinit { close("released") }
}
