import Foundation

/// `/api/vault` on the Jarvis server. Every read needs the session token Face ID (or the
/// vault passcode) unlocked; the `inbox` upload path is write-only and needs none, which is
/// what lets an upload outlive a lock.
///
/// Requests go through `JarvisAPI`'s transport: an ephemeral, cookie-less URLSession, so no
/// vault bytes ever land in a disk cache.
struct VaultAPI: Sendable {
    static let prefix = "/api/vault"
    /// Keeps the vault's signatures apart from the car's and the door alarm's.
    static let signingDomain = "jarvis-vault"

    var api: JarvisAPI = .shared

    // MARK: Raw

    func send(_ method: String, _ path: String, token: String?, json: Any? = nil, data: Data? = nil,
              contentType: String? = nil, headers: [String: String] = [:],
              query: [String: String] = [:], timeout: TimeInterval = 60) async throws -> (Data, HTTPURLResponse) {
        var h = headers
        if let token { h["X-Vault-Token"] = token }
        var body = data
        if let json {
            body = try JSONSerialization.data(withJSONObject: json)
            h["Content-Type"] = "application/json"
        } else if let contentType {
            h["Content-Type"] = contentType
        }
        let req = try api.request(method, Self.prefix + path, query: query, headers: h, body: body, timeout: timeout)
        let (out, http) = try await api.transport.send(req)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, token != nil { throw VaultError.locked }
            let obj = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
            if http.statusCode == 429 {
                throw VaultError.server(obj?["error"] as? String ?? "Too many tries. Wait a moment.")
            }
            throw VaultError.http(http.statusCode, obj?["error"] as? String
                                  ?? APIError.message(status: http.statusCode, body: out))
        }
        return (out, http)
    }

    func object(_ method: String, _ path: String, token: String?, json: Any? = nil,
                query: [String: String] = [:], timeout: TimeInterval = 60) async throws -> [String: Any] {
        let (data, _) = try await send(method, path, token: token, json: json, query: query, timeout: timeout)
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: Unlock

    struct Status { let passcodeSet: Bool; let retryAfter: Int? }

    func status() async throws -> Status {
        let o = try await object("GET", "/status", token: nil)
        return Status(passcodeSet: o["passcode_set"] as? Bool ?? false,
                      retryAfter: (o["retry_after_s"] as? NSNumber)?.intValue)
    }

    struct Session { let token: String; let idle: TimeInterval; let max: TimeInterval }

    private func session(_ o: [String: Any]) throws -> Session {
        guard let token = o["token"] as? String, !token.isEmpty else {
            throw VaultError.server("The server didn't open the vault.")
        }
        return Session(token: token,
                       idle: (o["idle_s"] as? NSNumber)?.doubleValue ?? 300,
                       max: (o["max_s"] as? NSNumber)?.doubleValue ?? 1800)
    }

    func unlock(proof: ToyotaApprover.Proof) async throws -> Session {
        try session(try await object("POST", "/unlock", token: nil,
                                     json: ["nonce": proof.nonce, "ts": proof.ts, "signature": proof.signature]))
    }

    func unlock(passcode: String) async throws -> Session {
        try session(try await object("POST", "/unlock/passcode", token: nil, json: ["passcode": passcode]))
    }

    func setPasscode(_ passcode: String, proof: ToyotaApprover.Proof) async throws {
        _ = try await object("POST", "/passcode", token: nil,
                             json: ["passcode": passcode, "nonce": proof.nonce, "ts": proof.ts,
                                    "signature": proof.signature])
    }

    func lock(token: String) async {
        _ = try? await object("POST", "/lock", token: token)
    }

    // MARK: Browse

    struct Listing {
        let folder: VaultFolder
        let path: [VaultFolder]
        let folders: [VaultFolder]
        let items: [VaultItem]
    }

    func folder(_ id: String, token: String) async throws -> Listing {
        let o = try await object("GET", "/folders/\(id)", token: token)
        let f = o["folder"] as? [String: Any] ?? [:]
        let folder = VaultFolder(json: f) ?? VaultFolder(id: id, parentID: nil, name: "Vault", count: 0)
        let path = (f["path"] as? [[String: Any]] ?? []).compactMap { VaultFolder(json: $0) }
        return Listing(folder: folder, path: path,
                       folders: (o["folders"] as? [[String: Any]] ?? []).compactMap(VaultFolder.init(json:)),
                       items: (o["items"] as? [[String: Any]] ?? []).compactMap(VaultItem.init(json:)))
    }

    func tree(token: String) async throws -> [VaultFolder] {
        let o = try await object("GET", "/tree", token: token)
        return (o["folders"] as? [[String: Any]] ?? []).compactMap(VaultFolder.init(json:))
    }

    func search(_ q: String, token: String) async throws -> (folders: [VaultFolder], items: [VaultItem]) {
        let o = try await object("GET", "/search", token: token, query: ["q": q])
        return ((o["folders"] as? [[String: Any]] ?? []).compactMap(VaultFolder.init(json:)),
                (o["items"] as? [[String: Any]] ?? []).compactMap(VaultItem.init(json:)))
    }

    func item(_ id: String, token: String) async throws -> VaultItem {
        let o = try await object("GET", "/items/\(id)", token: token)
        guard let item = VaultItem(json: o["item"] as? [String: Any] ?? [:]) else {
            throw VaultError.server("That item is gone.")
        }
        return item
    }

    func thumb(_ id: String, token: String) async throws -> Data {
        try await send("GET", "/items/\(id)/thumb", token: token).0
    }

    func favicon(_ id: String, token: String) async throws -> Data {
        try await send("GET", "/items/\(id)/favicon", token: token).0
    }

    /// The whole item (photos, PDFs, files to hand on). Videos stream instead (`VaultPlayer`).
    func content(_ id: String, token: String) async throws -> Data {
        try await send("GET", "/items/\(id)/content", token: token, timeout: 600).0
    }

    /// The whole item into a protected file, 8 MB at a time — never the whole thing in memory.
    func download(_ item: VaultItem, to url: URL, token: String) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.complete])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let span: Int64 = 8 * 1024 * 1024
        var offset: Int64 = 0
        repeat {
            let last = min(item.size, offset + span) - 1
            let (data, _) = try await send("GET", "/items/\(item.id)/content", token: token,
                                           headers: item.size > 0 ? ["Range": "bytes=\(offset)-\(last)"] : [:],
                                           timeout: 300)
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            if data.isEmpty { break }
        } while offset < item.size
    }

    // MARK: Change

    func createFolder(name: String, parent: String, token: String) async throws -> VaultFolder {
        let o = try await object("POST", "/folders", token: token, json: ["parent_id": parent, "name": name])
        guard let f = VaultFolder(json: o["folder"] as? [String: Any] ?? [:]) else {
            throw VaultError.server("The folder wasn't made.")
        }
        return f
    }

    func updateFolder(_ id: String, name: String? = nil, parent: String? = nil, token: String) async throws {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let parent { body["parent_id"] = parent }
        _ = try await object("PATCH", "/folders/\(id)", token: token, json: body)
    }

    func deleteFolder(_ id: String, token: String) async throws {
        _ = try await object("DELETE", "/folders/\(id)", token: token)
    }

    func createNote(title: String, body: String, parent: String, token: String) async throws -> VaultItem {
        let o = try await object("POST", "/items", token: token,
                                 json: ["kind": "note", "parent_id": parent, "title": title, "body": body])
        guard let item = VaultItem(json: o["item"] as? [String: Any] ?? [:]) else {
            throw VaultError.server("The note wasn't saved.")
        }
        return item
    }

    func createLink(url: String, parent: String, token: String) async throws -> VaultItem {
        let o = try await object("POST", "/items", token: token,
                                 json: ["kind": "link", "parent_id": parent, "url": url], timeout: 30)
        guard let item = VaultItem(json: o["item"] as? [String: Any] ?? [:]) else {
            throw VaultError.server("The link wasn't saved.")
        }
        return item
    }

    /// Fetch a saved link's preview again (the server's engine improves; sites change).
    func refreshPreview(_ id: String, token: String) async throws -> VaultItem {
        let o = try await object("POST", "/items/\(id)/preview", token: token, timeout: 30)
        guard let item = VaultItem(json: o["item"] as? [String: Any] ?? [:]) else {
            throw VaultError.server("The preview wasn't refreshed.")
        }
        return item
    }

    struct LinkPreview {
        let title: String
        let siteName: String
        let domain: String
        let isVideo: Bool
        let duration: Double?
        let author: String
        let thumb: Data?
    }

    func linkPreview(_ url: String, token: String) async throws -> LinkPreview {
        let o = try await object("POST", "/link-preview", token: token, json: ["url": url], timeout: 20)
        let p = o["preview"] as? [String: Any] ?? [:]
        return LinkPreview(title: p["title"] as? String ?? "",
                           siteName: p["site_name"] as? String ?? "",
                           domain: p["domain"] as? String ?? (URL(string: url)?.host ?? ""),
                           isVideo: (p["kind"] as? String) == "video",
                           duration: (p["duration_s"] as? NSNumber)?.doubleValue,
                           author: p["author"] as? String ?? "",
                           thumb: (o["thumb_jpeg_b64"] as? String).flatMap { Data(base64Encoded: $0) })
    }

    @discardableResult
    func updateItem(_ id: String, fields: [String: Any], token: String) async throws -> VaultItem? {
        let o = try await object("PATCH", "/items/\(id)", token: token, json: fields)
        return VaultItem(json: o["item"] as? [String: Any] ?? [:])
    }

    func move(_ ids: [String], to parent: String, token: String) async throws {
        _ = try await object("POST", "/items/move", token: token, json: ["ids": ids, "parent_id": parent])
    }

    func delete(_ ids: [String], token: String) async throws {
        _ = try await object("POST", "/items/delete", token: token, json: ["ids": ids])
    }

    // MARK: Uploads (write-only inbox: no token, survives a lock)

    struct UploadTicket { let id: String; let chunkSize: Int; let received: Set<Int> }

    private func ticket(_ o: [String: Any]) throws -> UploadTicket {
        guard let id = o["upload_id"] as? String else { throw VaultError.server("The upload didn't start.") }
        let received = Set((o["received"] as? [NSNumber] ?? []).map(\.intValue))
        return UploadTicket(id: id, chunkSize: (o["chunk_size"] as? NSNumber)?.intValue ?? 8 * 1024 * 1024,
                            received: received)
    }

    func startUpload(_ fields: [String: Any]) async throws -> UploadTicket {
        try ticket(try await object("POST", "/inbox/uploads", token: nil, json: fields))
    }

    func uploadState(_ id: String) async throws -> UploadTicket {
        try ticket(try await object("GET", "/inbox/uploads/\(id)", token: nil))
    }

    func putChunk(_ id: String, index: Int, data: Data) async throws {
        _ = try await send("PUT", "/inbox/uploads/\(id)/\(index)", token: nil, data: data,
                           contentType: "application/octet-stream", timeout: 180)
    }

    func putThumb(_ id: String, jpeg: Data) async throws {
        _ = try await send("PUT", "/inbox/uploads/\(id)/thumb", token: nil, data: jpeg, contentType: "image/jpeg")
    }

    func finishUpload(_ id: String) async throws {
        _ = try await object("POST", "/inbox/uploads/\(id)/finish", token: nil, timeout: 120)
    }
}
