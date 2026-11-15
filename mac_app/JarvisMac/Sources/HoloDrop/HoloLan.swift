import Foundation
import Network

/// The bits of HTTP the LAN receiver speaks (pure; tested).
enum HoloHTTP {
    struct Head: Equatable {
        let method: String
        let path: String
        /// Lower-cased names.
        let headers: [String: String]
        var contentLength: Int? { headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    }

    static let maxHead = 64 * 1024

    /// Where the head ends (just past the blank line), or nil while it hasn't.
    static func headEnd(_ data: Data) -> Int? {
        data.range(of: Data("\r\n\r\n".utf8)).map { $0.upperBound }
    }

    static func parse(_ data: Data) -> Head? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = String(first[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return Head(method: String(first[0]).uppercased(), path: path, headers: headers)
    }

    static func response(_ status: Int, _ json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
                      411: "Length Required", 413: "Payload Too Large", 500: "Internal Server Error",
                      503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Token check that takes the same time however much of it matches.
    static func sameToken(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// This Mac's address on the local network.
enum HoloLanAddress {
    /// Wi-Fi/Ethernet (en*) first, en0 before the others; never loopback, link-local, VPN
    /// tunnels or AirDrop's own links.
    static func pick(_ candidates: [(name: String, ip: String)]) -> String? {
        let usable = candidates.filter { c in
            !c.ip.hasPrefix("127.") && !c.ip.hasPrefix("169.254.") && !c.ip.isEmpty
                && !["utun", "awdl", "llw", "bridge", "lo", "gif", "stf", "anpi", "ap"].contains { c.name.hasPrefix($0) }
        }
        return usable.first { $0.name == "en0" }?.ip ?? usable.first { $0.name.hasPrefix("en") }?.ip ?? usable.first?.ip
    }

    static func current() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var out: [(name: String, ip: String)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            out.append((String(cString: ifa.pointee.ifa_name), String(cString: host)))
        }
        return pick(out)
    }
}

/// The direct receiver: a tiny HTTP server on a random port that takes
/// `POST /holo-drop` with `X-Holo-Token` (one of the tokens it advertised through Jarvis) and
/// `X-Holo-Meta` (base64 JSON of the drop's fields); the body is the bytes, or JSON for a link
/// or text. Replies `{ok, outcome}` once the drop has landed.
final class HoloLanReceiver: @unchecked Sendable {
    /// Lands the drop (on the main actor): fields, the bytes' file (if any), the JSON body.
    typealias Handler = @MainActor (_ fields: [String: Any], _ file: URL?, _ inline: [String: Any]) async -> HoloOutcome

    var handler: Handler?
    private let queue = DispatchQueue(label: "jarvis.holo.lan")
    private let lock = NSLock()
    private var listener: NWListener?
    private var tokens: [(token: String, until: Date)] = []
    private(set) var port: UInt16?

    static let inlineCap = 2 * 1024 * 1024
    static let fileCap: Int = 16 * 1024 * 1024 * 1024

    var running: Bool { lock.lock(); defer { lock.unlock() }; return listener != nil }

    func start(ready: @escaping @Sendable (UInt16) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else {
            if let port { ready(port) }
            return
        }
        guard let l = try? NWListener(using: .tcp) else { return }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready:
                if let p = l?.port?.rawValue {
                    self?.lock.lock()
                    self?.port = p
                    self?.lock.unlock()
                    ready(p)
                }
            case .failed:
                self?.stop()
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let l = listener
        listener = nil
        port = nil
        tokens = []
        lock.unlock()
        l?.cancel()
    }

    /// A fresh token, good for `validFor`; the older ones stay good until their own time runs
    /// out (a sender may have just read the last advert).
    func newToken(validFor: TimeInterval) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let now = Date()
        tokens = tokens.filter { $0.until > now } + [(token, now.addingTimeInterval(validFor))]
        lock.unlock()
        return token
    }

    func accepts(_ token: String?) -> Bool {
        guard let token else { return false }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return tokens.contains { $0.until > now && HoloHTTP.sameToken($0.token, token) }
    }

    private func accept(_ conn: NWConnection) {
        let c = HoloLanConnection(conn: conn, receiver: self)
        c.start(queue: queue)
    }

    fileprivate func land(_ fields: [String: Any], _ file: URL?, _ inline: [String: Any],
                          done: @escaping @Sendable (HoloOutcome) -> Void) {
        let box = HoloSendableBox(fields: fields, inline: inline)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let handler = self?.handler else { done(.failed); return }
                Task { @MainActor in done(await handler(box.fields, file, box.inline)) }
            }
        }
    }
}

/// JSON dictionaries handed across threads (they're never mutated after parsing).
private struct HoloSendableBox: @unchecked Sendable {
    let fields: [String: Any]
    let inline: [String: Any]
}

/// One request on the LAN receiver.
private final class HoloLanConnection: @unchecked Sendable {
    private let conn: NWConnection
    private weak var receiver: HoloLanReceiver?
    private var buffer = Data()
    private var head: HoloHTTP.Head?
    private var remaining = 0
    private var body = Data()
    private var file: FileHandle?
    private var fileURL: URL?
    private var fields: [String: Any] = [:]
    private var inlineKind = true
    private var idle: DispatchWorkItem?
    private var queue: DispatchQueue?

    init(conn: NWConnection, receiver: HoloLanReceiver) {
        self.conn = conn
        self.receiver = receiver
    }

    func start(queue: DispatchQueue) {
        self.queue = queue
        // Strong on purpose: the connection keeps this object alive until it's cancelled
        // (cleanup clears the handler and so the cycle).
        conn.stateUpdateHandler = { state in
            if case .failed = state { self.finish() }
            if case .cancelled = state { self.cleanup() }
        }
        conn.start(queue: queue)
        receive()
    }

    private func touch() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.finish() }
        idle = item
        queue?.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func receive() {
        touch()
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
            if let data, !data.isEmpty { self.consume(data) }
            if error != nil || (complete && self.head == nil) { self.finish(); return }
            if self.head == nil || self.remaining > 0 { if !complete { self.receive() } else { self.finish() } }
        }
    }

    private func consume(_ data: Data) {
        if head == nil {
            buffer.append(data)
            guard let end = HoloHTTP.headEnd(buffer) else {
                if buffer.count > HoloHTTP.maxHead { reply(400, ["ok": false, "error": "head too large"]) }
                return
            }
            guard let h = HoloHTTP.parse(buffer.prefix(end)) else { return reply(400, ["ok": false, "error": "bad request"]) }
            let rest = buffer.suffix(from: end)
            buffer = Data()
            guard h.path == "/holo-drop" else { return reply(404, ["ok": false, "error": "not found"]) }
            guard h.method == "POST" else { return reply(405, ["ok": false, "error": "POST only"]) }
            guard receiver?.accepts(h.headers["x-holo-token"]) == true else {
                return reply(401, ["ok": false, "error": "bad token"])
            }
            guard let length = h.contentLength, length >= 0 else {
                return reply(411, ["ok": false, "error": "Content-Length required"])
            }
            fields = HoloWire.decodeMeta(h.headers["x-holo-meta"]) ?? [:]
            let kind = HoloKind(rawValue: HJ.s(fields["kind"])) ?? .file
            inlineKind = kind.inline
            guard length <= (inlineKind ? HoloLanReceiver.inlineCap : HoloLanReceiver.fileCap) else {
                return reply(413, ["ok": false, "error": "too large"])
            }
            if !inlineKind {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HoloDrop-lan-" + UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let u = folder.appendingPathComponent("payload")
                FileManager.default.createFile(atPath: u.path, contents: nil)
                fileURL = u
                file = try? FileHandle(forWritingTo: u)
                guard file != nil else { return reply(500, ["ok": false, "error": "can't write"]) }
            }
            if h.headers["expect"]?.lowercased() == "100-continue" {
                conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            head = h
            remaining = length
            if !rest.isEmpty { take(Data(rest)) }
            if remaining == 0 { complete() }
            return
        }
        take(data)
        if remaining == 0 { complete() }
    }

    private func take(_ data: Data) {
        let chunk = data.prefix(remaining)
        remaining -= chunk.count
        if inlineKind { body.append(chunk) } else { try? file?.write(contentsOf: chunk) }
    }

    private func complete() {
        guard head != nil else { return }
        try? file?.close()
        file = nil
        let inline = inlineKind ? ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]) : [:]
        let url = fileURL
        fileURL = nil   // handed over: the receiver moves it into its inbox
        idle?.cancel()
        receiver?.land(fields, url, inline) { [weak self] outcome in
            self?.queue?.async {
                self?.reply(outcome == .failed ? 500 : 200,
                            outcome == .failed ? ["ok": false, "outcome": outcome.rawValue]
                                               : ["ok": true, "outcome": outcome.rawValue])
            }
        }
    }

    private func reply(_ status: Int, _ json: [String: Any]) {
        head = head ?? HoloHTTP.Head(method: "", path: "", headers: [:])
        remaining = 0
        conn.send(content: HoloHTTP.response(status, json), completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        idle?.cancel()
        conn.cancel()
    }

    private func cleanup() {
        try? file?.close()
        file = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        fileURL = nil
        conn.stateUpdateHandler = nil
    }
}
