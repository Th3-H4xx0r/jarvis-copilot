import Foundation

/// `/api/holo-drop` for the app and the share extension (credentials injected), plus the
/// direct LAN path: a receiver that advertised an endpoint gets the bytes straight from
/// this device; the server still records the drop.
struct HoloDropClient {
    let baseURL: URL
    let headers: [String: String]
    var session: URLSession = .shared
    var lanTimeout: TimeInterval = 1.5
    /// The LAN path's own session: never waits for connectivity, so a dead address fails fast.
    var directSession: URLSession = HoloDropClient.makeDirectSession()

    static func makeDirectSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForResource = 900
        return URLSession(configuration: cfg)
    }

    /// A query string that keeps "+" and "&" in names (form-style decoding turns "+" into a space).
    static func query(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?/")
        return items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    func devices() async throws -> [HoloDevice] {
        let o = try await json("GET", "/devices")
        return (o["devices"] as? [[String: Any]] ?? []).compactMap(HoloDevice.init(json:))
    }

    func screen(of device: HoloDevice) async throws -> HoloScreen? {
        HoloScreen(json: try await json("GET", "/devices/\(device.id)/screen"))
    }

    func postBearings(_ rows: [[String: Any]]) async {
        _ = try? await json("POST", "/bearings", body: ["bearings": rows])
    }

    func beacon(_ device: String, mode: String, nonce: String, token: String? = nil) async {
        var body: [String: Any] = ["mode": mode, "nonce": nonce]
        if let token { body["token"] = token }
        _ = try? await json("POST", "/beacon/\(device)", body: body)
    }

    /// A best-guess link for a screenshot: `{url?, title?, confidence, best_guess}`.
    func screenGuess(_ png: Data) async throws -> [String: Any] {
        var req = request("POST", "/screen-guess")
        req.timeoutInterval = 20
        req.setValue("image/png", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, from: png)
        try check(response, data: data)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func drop(_ id: String) async throws -> [String: Any] { try await json("GET", "/drops/\(id)") }

    func pending() async throws -> [[String: Any]] {
        try await json("GET", "/pending")["drops"] as? [[String: Any]] ?? []
    }

    func landed(_ id: String, outcome: String, error: String? = nil) async {
        var body: [String: Any] = ["outcome": outcome]
        if let error { body["error"] = error }
        _ = try? await json("POST", "/drops/\(id)/landed", body: body)
    }

    func content(_ id: String, to destination: URL) async throws -> URL {
        var req = request("GET", "/drops/\(id)/content")
        req.timeoutInterval = 600
        let (tmp, response) = try await session.download(for: req)
        try check(response, data: nil)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        return destination
    }

    /// Send: direct over the LAN when the target advertises it, else through Jarvis.
    func send(_ item: HoloItem, to device: HoloDevice, action: HoloAction,
              position: HoloPosition?, allowDirect: Bool = true) async throws -> [String: Any] {
        if allowDirect, let url = device.lanURL, let token = device.lanToken,
           let outcome = try await sendDirect(item, url: url, token: token, action: action, position: position) {
            var body = meta(item, device: device, action: action, position: position)
            body["delivered_direct"] = true                    // the record only: the bytes already went
            body["outcome"] = outcome
            if case .file(_, _, let mime, _) = item { body["mime"] = mime }
            return try await json("POST", "/drops", body: body)
        }
        switch item {
        case .link, .text:
            return try await json("POST", "/drops", body: meta(item, device: device, action: action, position: position))
        case .file(let fileURL, let name, let mime, let kind):
            var q = [("kind", kind), ("target", device.id), ("name", name), ("mime", mime), ("action", action.rawValue)]
            if let position { q += [("x", String(position.x)), ("y", String(position.y))] }
            var req = request("POST", "/drops/upload?" + Self.query(q))
            req.timeoutInterval = 900
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            req.setValue(String(size), forHTTPHeaderField: "Content-Length")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.upload(for: req, fromFile: fileURL)
            try check(response, data: data)
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
    }

    /// The receiver's outcome ("opened", "saved", …); nil when the receiver isn't reachable (then the
    /// drop goes through Jarvis). A receiver that answered "no" throws: re-sending would land it twice.
    func sendDirect(_ item: HoloItem, url: URL, token: String, action: HoloAction, position: HoloPosition?) async throws -> String? {
        // Reachable at all? Any HTTP answer to a quick GET says yes; silence means another network.
        var probe = URLRequest(url: url.appendingPathComponent("holo-drop"), timeoutInterval: lanTimeout)
        probe.httpMethod = "GET"
        guard (try? await directSession.data(for: probe)) != nil else { return nil }
        var req = URLRequest(url: url.appendingPathComponent("holo-drop"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-Holo-Token")
        var m = meta(item, device: nil, action: action, position: position)
        if case .file(_, let name, let mime, let kind) = item { m["name"] = name; m["mime"] = mime; m["kind"] = kind }
        let metaData = try JSONSerialization.data(withJSONObject: m)
        req.setValue(metaData.base64EncodedString(), forHTTPHeaderField: "X-Holo-Meta")
        let (data, response): (Data, URLResponse)
        do {
            switch item {
            case .file(let fileURL, _, _, _):
                req.timeoutInterval = 600
                (data, response) = try await directSession.upload(for: req, fromFile: fileURL)
            default:
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                (data, response) = try await directSession.upload(for: req, from: metaData)
            }
        } catch {
            return nil                                   // the connection broke: Jarvis takes it
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 200, o["ok"] as? Bool == true { return o["outcome"] as? String ?? "delivered" }
        // 4xx: turned away before anything happened (stale token, size, bad request) → Jarvis takes it.
        // 5xx or 200 with ok:false: the device acted and failed → reported, never sent twice.
        if (400..<500).contains(status) { return nil }
        throw NSError(domain: "HoloDrop", code: status, userInfo: [NSLocalizedDescriptionKey:
            "\(o["error"] as? String ?? "The device couldn't take it")"])
    }

    func meta(_ item: HoloItem, device: HoloDevice?, action: HoloAction, position: HoloPosition?) -> [String: Any] {
        var body: [String: Any] = ["action": action.rawValue]
        if let device { body["target"] = device.id }
        if let position { body["position"] = ["x": position.x, "y": position.y] }
        switch item {
        case .link(let url, let title):
            body["kind"] = "link"; body["url"] = url.absoluteString
            if let title { body["title"] = title }
        case .text(let t):
            body["kind"] = "text"; body["text"] = t
        case .file(_, let name, _, let kind):
            body["kind"] = kind; body["name"] = name
        }
        return body
    }

    // MARK: plumbing

    func request(_ method: String, _ path: String) -> URLRequest {
        let full = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/holo-drop" + path
        var req = URLRequest(url: URL(string: full)!, timeoutInterval: 30)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    func json(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = request(method, path)
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        try check(response, data: data)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func check(_ response: URLResponse, data: Data?) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = data.flatMap { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["error"] as? String }
            throw NSError(domain: "HoloDrop", code: status,
                          userInfo: [NSLocalizedDescriptionKey: msg ?? (status == 409 ? "Holo Drop is switched off" : "The server said \(status).")])
        }
    }
}
