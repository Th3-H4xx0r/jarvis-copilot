import Foundation
import Network

/// The head of one HTTP request, once its blank line has arrived.
struct HoloHTTPHead: Equatable {
    let method: String
    let path: String
    let headers: [String: String]      // lowercased names
    let length: Int                    // bytes through the blank line

    var contentLength: Int? { headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    static let maxHead = 16 * 1024

    /// Nil until "\r\n\r\n" is in `data` (or when it isn't a request line we understand).
    static func parse(_ data: Data) -> HoloHTTPHead? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HoloHTTPHead(method: String(parts[0]), path: String(parts[1]), headers: headers,
                            length: end.upperBound - data.startIndex)
    }

    /// The drop fields the sender put in `X-Holo-Meta` (base64 JSON).
    func meta() -> [String: Any]? {
        guard let b64 = headers["x-holo-meta"], let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// While the app is open, the phone takes drops straight over the local network: it listens on
/// a random port and advertises `{url, token}` through Jarvis (`POST /lan`); a sender on the same
/// Wi-Fi posts the bytes here, skipping the server. Stops (and `DELETE /lan`) in the background.
@MainActor
final class HoloLanReceiver {
    static let shared = HoloLanReceiver()
    static let maxBytes: Int64 = 4 * 1_073_741_824

    private var listener: NWListener?
    private var token = ""
    private var refresh: Task<Void, Never>?

    func start() {
        guard listener == nil, PowerState.shared.isOn("holo-drop") else { return }
        guard let l = try? NWListener(using: .tcp, on: .any) else { return }
        token = Self.randomToken()
        l.newConnectionHandler = { conn in
            Task { @MainActor in HoloLanReceiver.shared.accept(conn) }
        }
        l.stateUpdateHandler = { state in
            Task { @MainActor in
                if case .ready = state { HoloLanReceiver.shared.advertise() }
                if case .failed = state { HoloLanReceiver.shared.stop() }
            }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    func stop() {
        refresh?.cancel()
        refresh = nil
        guard let l = listener else { return }
        l.cancel()
        listener = nil
        token = ""
        Task { _ = try? await HoloDropReceiver.shared.client?.json("DELETE", "/lan") }
    }

    private func advertise() {
        guard let port = listener?.port?.rawValue, let ip = Self.localIPv4() else { return }
        let body: [String: Any] = ["url": "http://\(ip):\(port)", "token": token,
                                   "expires": Date().addingTimeInterval(15 * 60).timeIntervalSince1970]
        refresh?.cancel()
        refresh = Task { @MainActor in
            while !Task.isCancelled, listener != nil {
                _ = try? await HoloDropReceiver.shared.client?.json("POST", "/lan", body: body)
                try? await Task.sleep(for: .seconds(10 * 60))
            }
        }
    }

    // MARK: one request

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        Self.readHead(conn, buffer: Data())
    }

    private nonisolated static func readHead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let head = HoloHTTPHead.parse(buf) {
                let rest = Data(buf.dropFirst(head.length))
                Task { @MainActor in HoloLanReceiver.shared.got(head, body: rest, conn: conn) }
            } else if error != nil || done || buf.count > HoloHTTPHead.maxHead {
                conn.cancel()
            } else {
                readHead(conn, buffer: buf)
            }
        }
    }

    private func got(_ head: HoloHTTPHead, body: Data, conn: NWConnection) {
        guard head.method == "POST", head.path.hasPrefix("/holo-drop") else { return reply(conn, 404, ["ok": false]) }
        guard !token.isEmpty, Self.same(head.headers["x-holo-token"] ?? "", token) else {
            return reply(conn, 403, ["ok": false, "error": "bad token"])
        }
        guard let length = head.contentLength, length >= 0, Int64(length) <= Self.maxBytes,
              var meta = head.meta(), let kind = meta["kind"] as? String else {
            return reply(conn, 400, ["ok": false, "error": "bad request"])
        }
        let id = "direct-\(UUID().uuidString.prefix(8).lowercased())"
        meta["id"] = id
        let isFile = ["image", "video", "file"].contains(kind)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HoloDrop/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(HoloArrival.safeName(meta["name"] as? String ?? "Holo Drop"))
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else { return reply(conn, 500, ["ok": false]) }
        let first = body.prefix(length)
        try? handle.write(contentsOf: first)
        let fields = meta
        Self.readBody(conn, handle: handle, remaining: length - first.count) { ok in
            Task { @MainActor in
                try? handle.close()
                guard ok, let rec = HoloDropRecord(json: fields) else {
                    return HoloLanReceiver.shared.reply(conn, 400, ["ok": false, "error": "incomplete"])
                }
                let outcome = await HoloDropReceiver.shared.receiveDirect(rec, file: isFile ? file : nil)
                HoloLanReceiver.shared.reply(conn, 200, ["ok": outcome != "failed", "outcome": outcome])
            }
        }
    }

    private nonisolated static func readBody(_ conn: NWConnection, handle: FileHandle, remaining: Int,
                                             done finish: @escaping @Sendable (Bool) -> Void) {
        guard remaining > 0 else { return finish(true) }
        conn.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 1 << 20)) { data, _, done, error in
            guard let data, !data.isEmpty else { return finish(false) }
            try? handle.write(contentsOf: data)
            let left = remaining - data.count
            if left <= 0 { return finish(true) }
            if error != nil || done { return finish(false) }
            readBody(conn, handle: handle, remaining: left, done: finish)
        }
    }

    private func reply(_ conn: NWConnection, _ status: Int, _ body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : "Error"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: helpers

    nonisolated static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time compare (the token is the only thing guarding the port).
    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The Wi-Fi address (en0, IPv4), the one a sender on the same network reaches.
    nonisolated static func localIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
            }
        }
        return found
    }
}
