import Foundation

// Holo Drop's calls to the Jarvis server, over jc-client's loopback proxy (`origin`), which adds
// this Mac's paired session — so neither the app nor the Share extension holds credentials.
// Compiled into the app AND the Share extension.

enum HoloFailure: Error, Equatable, Sendable {
    /// Holo Drop is switched off (the server answers 409).
    case off
    case tooLarge
    case notReachable
    case server(Int, String)

    var message: String {
        switch self {
        case .off: return "Holo Drop is off"
        case .tooLarge: return "Too big to send through Jarvis"
        case .notReachable: return "Jarvis isn't reachable"
        case .server(let code, let text): return text.isEmpty ? "The server said \(code)" : text
        }
    }
}

struct HoloDropAPI: Sendable {
    let origin: String

    private func url(_ path: String) -> URL? { URL(string: origin + path) }

    private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil,
                         timeout: TimeInterval = 20) throws -> URLRequest {
        guard let u = url(path) else { throw HoloFailure.notReachable }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Jarvis-Mac/1 holo-drop", forHTTPHeaderField: "User-Agent")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    /// The reply's JSON; 409 → `.off`, 413 → `.tooLarge`, other errors → `.server`.
    static func check(_ data: Data, _ response: URLResponse?) throws -> [String: Any] {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200..<300: return obj
        case 409: throw HoloFailure.off
        case 413: throw HoloFailure.tooLarge
        case 0: throw HoloFailure.notReachable
        default: throw HoloFailure.server(status, HJ.s(obj["error"]))
        }
    }

    private func call(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw HoloFailure.notReachable
        }
        return try Self.check(data, response)
    }

    // MARK: the contract

    func devices() async throws -> [HoloDevice] {
        HoloDevice.list(try await call(request(HoloWire.base + "/devices", timeout: 8)))
    }

    func sendInline(_ body: [String: Any]) async throws -> HoloDropRecord? {
        let reply = try await call(request(HoloWire.base + "/drops", method: "POST", json: body))
        return HoloDropRecord(json: HJ.obj(reply["drop"]))
    }

    /// Streams the file from disk (big videos never sit in memory).
    func upload(file: URL, kind: HoloKind, target: String, action: HoloAction?,
                position: HoloPosition? = nil, name: String? = nil) async throws -> HoloDropRecord? {
        let path = HoloWire.uploadPath(kind: kind, target: target, name: name ?? file.lastPathComponent,
                                       mime: HoloKind.mime(for: file), action: action, position: position)
        var req = try request(path, method: "POST", timeout: 600)
        req.setValue(HoloKind.mime(for: file), forHTTPHeaderField: "Content-Type")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: req, fromFile: file)
        } catch {
            throw HoloFailure.notReachable
        }
        return HoloDropRecord(json: HJ.obj(try Self.check(data, response)["drop"]))
    }

    func drop(_ id: String) async throws -> HoloDropRecord? {
        let reply = try await call(request(HoloWire.base + "/drops/\(id)", timeout: 8))
        return HoloDropRecord(json: HJ.obj(reply["drop"]).isEmpty ? reply : HJ.obj(reply["drop"]))
    }

    /// The drop's bytes, downloaded to a temporary file (streamed to disk).
    func content(_ id: String) async throws -> URL {
        let req = try request(HoloWire.base + "/drops/\(id)/content", timeout: 600)
        let tmp: URL, response: URLResponse
        do {
            (tmp, response) = try await URLSession.shared.download(for: req)
        } catch {
            throw HoloFailure.notReachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            _ = try Self.check(body, response)
            throw HoloFailure.server(status, "")
        }
        return tmp
    }

    func landed(_ id: String, _ outcome: HoloOutcome, error: String? = nil) async {
        guard !id.isEmpty, let req = try? request(HoloWire.base + "/drops/\(id)/landed", method: "POST",
                                                  json: HoloWire.landed(outcome, error: error)) else { return }
        _ = try? await call(req)
    }

    func pending() async throws -> [HoloDropRecord] {
        HJ.arr(try await call(request(HoloWire.base + "/pending", timeout: 10))["drops"])
            .compactMap(HoloDropRecord.init(json:))
    }

    func advertiseLan(url: String, token: String, expires: Date) async throws {
        _ = try await call(request(HoloWire.base + "/lan", method: "POST",
                                   json: HoloWire.lanAdvert(url: url, token: token, expires: expires), timeout: 10))
    }

    func clearLan() async {
        guard let req = try? request(HoloWire.base + "/lan", method: "DELETE", timeout: 5) else { return }
        _ = try? await call(req)
    }

    func answerScreen(_ request: String, _ report: [String: Any]) async {
        guard let req = try? self.request(HoloWire.base + "/screen/\(request)", method: "POST",
                                          json: report, timeout: 3) else { return }
        _ = try? await call(req)
    }

    func moved() async {
        guard let req = try? request(HoloWire.base + "/moved", method: "POST", json: [:], timeout: 10) else { return }
        _ = try? await call(req)
    }

    /// Holo Drop's switch from `/api/power`: nil when the server has no such row (no Holo Drop
    /// there). Throws when it can't be read — unknown counts as on.
    func powerEnabled() async throws -> Bool? {
        let reply = try await call(request("/api/power", timeout: 10))
        return Self.holoEnabled(inPower: reply)
    }

    static func holoEnabled(inPower reply: [String: Any]) -> Bool? {
        guard let row = HJ.arr(reply["integrations"]).first(where: { HJ.s($0["id"]) == "holo-drop" }) else { return nil }
        return row["enabled"] == nil ? true : HJ.b(row["enabled"])
    }

    /// Wait (polling) until the drop lands or `timeout` passes.
    func waitLanded(_ id: String, timeout: TimeInterval) async -> HoloDropRecord? {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(600))
            if let d = try? await drop(id), d.state == "landed" || d.state == "failed" || !d.outcome.isEmpty {
                return d
            }
        }
        return nil
    }
}

/// Straight to a receiver on the same network (`POST {lan.url}/holo-drop`), no server in the way.
enum HoloDirect {
    /// The receiver's outcome, or nil when it can't be reached in time (send via Jarvis then).
    static func send(lan: HoloLan, fields: [String: Any], file: URL?, inline: [String: Any]?,
                     timeout: TimeInterval = 1.5) async -> HoloOutcome? {
        guard lan.usable(), let u = URL(string: lan.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/holo-drop")
        else { return nil }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(lan.token, forHTTPHeaderField: "X-Holo-Token")
        req.setValue(HoloWire.meta(fields), forHTTPHeaderField: "X-Holo-Meta")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = file == nil ? timeout * 4 : 3_600
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let data: Data, response: URLResponse
            if let file {
                req.setValue(HJ.s(fields["mime"], "application/octet-stream"), forHTTPHeaderField: "Content-Type")
                (data, response) = try await session.upload(for: req, fromFile: file)
            } else {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body = (try? JSONSerialization.data(withJSONObject: inline ?? [:])) ?? Data("{}".utf8)
                (data, response) = try await session.upload(for: req, from: body)
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], HJ.b(obj["ok"])
            else { return nil }
            return HoloOutcome(rawValue: HJ.s(obj["outcome"])) ?? .shown
        } catch {
            return nil
        }
    }
}

/// Sends what the Mac picked to one device: directly over the LAN when the device listens there,
/// else through Jarvis. Shared by the app's Orbit and the Share extension's.
struct HoloSender: Sendable {
    let api: HoloDropAPI
    var tryDirect = true

    struct Sent: Sendable {
        /// Server drop ids (to wait on their landing).
        var ids: [String] = []
        /// Landed already (the direct path answers with the outcome).
        var outcome: HoloOutcome?
    }

    func send(_ item: HoloItem, to device: HoloDevice, action: HoloAction,
              position: HoloPosition? = nil) async throws -> Sent {
        var sent = Sent()
        switch item {
        case .link(let u, let title):
            try await inline(kind: .link, url: u.absoluteString, text: nil, title: title, device: device,
                             action: action, position: position, into: &sent)
        case .text(let t):
            try await inline(kind: .text, url: nil, text: t, title: nil, device: device,
                             action: action, position: position, into: &sent)
        case .files(let urls):
            for file in urls {
                let upload = try Self.uploadable(file)
                defer { if upload != file { try? FileManager.default.removeItem(at: upload) } }
                let kind = HoloKind.forFile(upload)
                let name = upload.lastPathComponent, mime = HoloKind.mime(for: upload)
                if tryDirect, let lan = device.lan,
                   let outcome = await HoloDirect.send(lan: lan, fields: HoloWire.directFields(
                        kind: kind, name: name, mime: mime, action: action, position: position),
                        file: upload, inline: nil, timeout: 2) {
                    sent.outcome = Self.worse(sent.outcome, outcome)
                    // Recorded for history and the sender's landed line; not stored again.
                    _ = try? await api.sendInline(HoloWire.inlineDrop(
                        kind: kind, target: device.id, action: action, position: position, direct: true,
                        name: name, mime: mime, outcome: outcome))
                    continue
                }
                if let d = try await api.upload(file: upload, kind: kind, target: device.id, action: action,
                                                position: position, name: name) {
                    sent.ids.append(d.id)
                }
            }
        }
        return sent
    }

    private func inline(kind: HoloKind, url: String?, text: String?, title: String?, device: HoloDevice,
                        action: HoloAction, position: HoloPosition?, into sent: inout Sent) async throws {
        if tryDirect, let lan = device.lan {
            var body: [String: Any] = [:]
            if let url { body["url"] = url }
            if let text { body["text"] = text }
            if let outcome = await HoloDirect.send(lan: lan, fields: HoloWire.directFields(
                kind: kind, text: text, url: url, title: title, action: action, position: position),
                file: nil, inline: body) {
                sent.outcome = outcome
                _ = try? await api.sendInline(HoloWire.inlineDrop(kind: kind, target: device.id, text: text, url: url,
                                                                  action: action, position: position, title: title,
                                                                  direct: true, outcome: outcome))
                return
            }
        }
        if let d = try await api.sendInline(HoloWire.inlineDrop(kind: kind, target: device.id, text: text, url: url,
                                                                action: action, position: position, title: title)) {
            sent.ids.append(d.id)
        }
    }

    /// A folder goes as a zip (the file coordinator's own "for uploading" copy).
    static func uploadable(_ file: URL) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue else { return file }
        var out: URL?
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: file, options: .forUploading, error: &coordError) { zip in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let target = dest.appendingPathComponent(file.lastPathComponent + ".zip")
                try FileManager.default.copyItem(at: zip, to: target)
                out = target
            } catch {
                copyError = error
            }
        }
        if let out { return out }
        throw copyError ?? coordError ?? HoloFailure.server(0, "Couldn't zip the folder")
    }

    /// Several files landing: the line names the least complete outcome.
    static func worse(_ a: HoloOutcome?, _ b: HoloOutcome) -> HoloOutcome {
        guard let a else { return b }
        if a == .failed || b == .failed { return .failed }
        return a == b ? a : b
    }
}
