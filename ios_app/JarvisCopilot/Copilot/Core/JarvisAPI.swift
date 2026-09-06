import Foundation

// MARK: - Boundaries (protocol-based DI so everything above is testable)

/// Where requests go and what they carry. The production implementation reads the
/// pairing from `BridgeClient` (Keychain-backed); tests supply fixed values.
protocol APICredentials: Sendable {
    /// `https://host[:port]` with no trailing slash, or nil when not paired.
    var baseURL: URL? { get }
    /// Session cookie + Cloudflare Access service token, when present.
    var headers: [String: String] { get }
}

/// Raw HTTP. One method for buffered replies, one for byte streams (SSE / NDJSON).
///
/// The stream vends `Data` **chunks**, not single bytes: a per-byte
/// `AsyncThrowingStream` costs one continuation yield and one cross-task await
/// per byte, which on a fast reply is most of the CPU the turn spends. Chunks
/// are cut on newlines (the frame delimiter of both SSE and NDJSON), so nothing
/// is buffered past the point where it becomes useful.
protocol APITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)
}

struct BridgeCredentials: APICredentials {
    var baseURL: URL? { BridgeClient.shared.apiBaseURL() }
    var headers: [String: String] { BridgeClient.shared.apiAuthHeaders() }
}

/// Cookie-free URLSession so the only credential on the wire is the one we set.
final class URLSessionTransport: APITransport {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        self.session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse("not HTTP") }
        return (data, http)
    }

    /// Coalesce URLSession's byte sequence into line-sized `Data` chunks. A frame
    /// is only usable once its line is complete, so cutting on `\n` costs no
    /// latency while collapsing one continuation yield per byte into one per line.
    /// The size cap keeps a pathological line (a base64 image in one NDJSON row)
    /// from growing the buffer without bound.
    private static let chunkLimit = 16 * 1024

    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse("not HTTP") }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var buffer = Data()
                buffer.reserveCapacity(Self.chunkLimit)
                do {
                    for try await b in bytes {
                        if Task.isCancelled { break }
                        buffer.append(b)
                        if b == 0x0A || buffer.count >= Self.chunkLimit {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
}

// MARK: - Errors

enum APIError: LocalizedError, Equatable {
    /// No server URL / cookie stored yet.
    case notPaired
    /// Non-2xx. `message` is the server's `{error: …}` when it sent one, else a
    /// short body, else empty.
    case http(status: Int, message: String)
    /// The reply was not what we expected (not JSON, missing field, …).
    case badResponse(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Not paired with a Jarvis server"
        case .http(let status, let message):
            return message.isEmpty ? "Request failed (\(status))" : message
        case .badResponse(let why): return "Unexpected server reply: \(why)"
        case .cancelled: return "Cancelled"
        }
    }

    /// Mirrors the Flutter `apiErrorMessage`: prefer the server's `error` field, then
    /// a short text body, then the status code. An HTML error page or an empty
    /// body carries nothing a user can act on, so the status is the answer there —
    /// "Request failed (502)" beats a blank line in a bubble.
    static func message(status: Int, body: Data) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let err = obj["error"] { return "\(err)" }
            if let detail = obj["detail"] as? String { return detail }
        }
        let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty && text.count < 300 && !text.hasPrefix("<") { return text }
        return "Request failed (\(status))"
    }
}

/// One user-facing line for any error thrown by the API layer.
///
/// Every swallowed failure in the port funnels through here, so this is also the
/// one place that guarantees a diagnostic reaches the log — a `try?` on a network
/// call is invisible otherwise (silent-failures H5).
func apiErrorMessage(_ error: Error) -> String {
    let message = apiErrorLine(error)
    JcLog.core.error("api: \(message, privacy: .public) [\(String(describing: type(of: error)), privacy: .public)]")
    return message
}

/// The same line without the log entry — for callers that log it themselves
/// (``JcLog/report(_:_:_:)``) and would otherwise double-report.
func apiErrorLine(_ error: Error) -> String {
    if let e = error as? APIError { return e.errorDescription ?? "Error" }
    if (error as NSError).domain == NSURLErrorDomain {
        switch (error as NSError).code {
        case NSURLErrorNotConnectedToInternet: return "No internet connection"
        case NSURLErrorTimedOut: return "The server took too long to answer"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "Can't reach the server"
        default: break
        }
    }
    return error.localizedDescription
}

// MARK: - Responses

struct APIResponse {
    let status: Int
    let data: Data
    let headers: [String: String]

    /// Body as a JSON object; empty dictionary for an empty body.
    ///
    /// A 2xx with no body is normal for the mutation endpoints, but it is also
    /// what a truncated tunnel reply looks like — the caller can't tell, so at
    /// least the log can (silent-failures L4).
    func object() throws -> [String: Any] {
        if data.isEmpty {
            JcLog.core.notice("empty 2xx body (status \(status, privacy: .public)) read as {}")
            return [:]
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw APIError.badResponse("not JSON")
        }
        if let dict = obj as? [String: Any] { return dict }
        return ["data": obj]
    }

    /// Wrapper keys the server actually uses, in the order we try them. A plain
    /// `for value in dict.values` picks an *arbitrary* array — dictionary
    /// iteration order is unspecified, so a body carrying two arrays parsed
    /// differently from one launch to the next (silent-failures M6).
    static let arrayKeys = ["items", "sessions", "data", "results", "models", "devices", "list"]

    func array() throws -> [Any] {
        if data.isEmpty { return [] }
        let obj = try jsonBody()
        if let arr = obj as? [Any] { return arr }
        if let dict = obj as? [String: Any] {
            for key in Self.arrayKeys { if let arr = dict[key] as? [Any] { return arr } }
            throw APIError.badResponse(
                "expected an array; object has \(dict.keys.sorted().joined(separator: ", "))")
        }
        throw APIError.badResponse("expected an array")
    }

    /// The array under a named key — for callers that know the server's shape and
    /// should not be guessing at it.
    func array(key: String) throws -> [Any] {
        if data.isEmpty { return [] }
        let obj = try jsonBody()
        if let dict = obj as? [String: Any] {
            guard let arr = dict[key] as? [Any] else {
                throw APIError.badResponse("expected an array under \"\(key)\"")
            }
            return arr
        }
        if let arr = obj as? [Any] { return arr }
        throw APIError.badResponse("expected an array under \"\(key)\"")
    }

    private func jsonBody() throws -> Any {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw APIError.badResponse("not JSON")
        }
        return obj
    }

    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JarvisAPI.decoder) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw APIError.badResponse("\(T.self): \(error.localizedDescription)") }
    }

    var text: String { String(data: data, encoding: .utf8) ?? "" }
}

/// One server-sent event. `data` is the decoded JSON object when the payload was an
/// object (plus `event` filled in), otherwise `["event": …, "data": <string or scalar>]`.
struct SSEEvent: Equatable {
    var event: String
    var raw: String
    var object: [String: Any]

    static func == (l: SSEEvent, r: SSEEvent) -> Bool { l.event == r.event && l.raw == r.raw }

    subscript(key: String) -> Any? { object[key] }
    func string(_ key: String) -> String? {
        if let s = object[key] as? String { return s }
        if let v = object[key], !(v is NSNull) { return "\(v)" }
        return nil
    }
}

/// `POST …?stream=1` answers either with SSE or, on an older server, a single JSON
/// body. The stream yields exactly one `.json` in the latter case.
enum SSEOrJSON {
    case event(SSEEvent)
    case json([String: Any])
}

// MARK: - Pure parsers (unit-tested without any networking)

/// Incremental `text/event-stream` parser. Feed lines; get events.
struct SSEParser {
    private var event = "message"
    private var dataLines: [String] = []

    /// Returns an event when `line` completes one (a blank line), else nil.
    mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { event = "message"; dataLines.removeAll() }
            return flushIfNeeded()
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            var d = String(line.dropFirst(5))
            if d.hasPrefix(" ") { d.removeFirst() }
            dataLines.append(d)
        }
        return nil
    }

    /// Call at end of stream for a trailing event without a final blank line.
    mutating func finish() -> SSEEvent? {
        defer { dataLines.removeAll() }
        return flushIfNeeded()
    }

    private func flushIfNeeded() -> SSEEvent? {
        guard !dataLines.isEmpty else { return nil }
        let raw = dataLines.joined(separator: "\n")
        return SSEParser.decode(event: event, data: raw)
    }

    static func decode(event: String, data: String) -> SSEEvent {
        var object: [String: Any] = ["event": event]
        if let d = data.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: d) {
            if let dict = decoded as? [String: Any] {
                for (k, v) in dict { object[k] = v }
                // Server frames carry their own "event" key; keep the SSE name if absent.
                if object["event"] == nil { object["event"] = event }
            } else {
                object["data"] = decoded
            }
        } else {
            object["data"] = data
        }
        let name = (object["event"] as? String) ?? event
        return SSEEvent(event: name, raw: data, object: object)
    }
}

/// `multipart/form-data` body builder.
struct MultipartBody {
    struct File { let field: String; let filename: String; let mime: String; let data: Data }
    let boundary: String
    private(set) var fields: [(String, String)] = []
    private(set) var files: [File] = []

    init(boundary: String = "JarvisBoundary\(UUID().uuidString)") { self.boundary = boundary }

    mutating func add(_ name: String, _ value: String) { fields.append((name, value)) }
    mutating func add(file: File) { files.append(file) }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    func encoded() -> Data {
        var out = Data()
        func line(_ s: String) { out.append(s.data(using: .utf8)!) }
        for (name, value) in fields {
            line("--\(boundary)\r\n")
            line("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            line(value); line("\r\n")
        }
        for f in files {
            line("--\(boundary)\r\n")
            line("Content-Disposition: form-data; name=\"\(f.field)\"; filename=\"\(f.filename)\"\r\n")
            line("Content-Type: \(f.mime)\r\n\r\n")
            out.append(f.data); line("\r\n")
        }
        line("--\(boundary)--\r\n")
        return out
    }
}

// MARK: - Client

/// Typed access to the paired JarvisCopilot server. Thin: auth + encoding + streaming;
/// feature APIs (`ChatAPI`, `SessionsAPI`, …) sit on top and know the endpoints.
final class JarvisAPI: @unchecked Sendable {
    static let shared = JarvisAPI()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    let credentials: APICredentials
    let transport: APITransport

    init(credentials: APICredentials = BridgeCredentials(), transport: APITransport = URLSessionTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    var isPaired: Bool { credentials.baseURL != nil && !credentials.headers.isEmpty }

    // MARK: Request building

    func request(_ method: String, _ path: String, query: [String: String] = [:],
                 headers: [String: String] = [:], body: Data? = nil,
                 timeout: TimeInterval = 60) throws -> URLRequest {
        guard let base = credentials.baseURL else { throw APIError.notPaired }
        // The base URL comes out of the Keychain, so it is only as well-formed as
        // whatever was paired; a crash here would be a stored-string bug.
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.badResponse("the paired server URL is unusable")
        }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/" + trimmed
        if !query.isEmpty {
            comps.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        guard let url = comps.url else { throw APIError.badResponse("bad URL") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in credentials.headers { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    private func jsonBody(_ body: Any) throws -> Data {
        if let data = body as? Data { return data }
        if let enc = body as? Encodable { return try JarvisAPI.encoder.encode(AnyEncodable(enc)) }
        guard JSONSerialization.isValidJSONObject(body) else { throw APIError.badResponse("body is not JSON") }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func perform(_ req: URLRequest) async throws -> APIResponse {
        let (data, http) = try await transport.send(req)
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[("\(k)").lowercased()] = "\(v)" }
        let response = APIResponse(status: http.statusCode, data: data, headers: headers)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, message: APIError.message(status: http.statusCode, body: data))
        }
        return response
    }

    // MARK: Buffered calls

    func get(_ path: String, query: [String: String] = [:], headers: [String: String] = [:],
             timeout: TimeInterval = 60) async throws -> APIResponse {
        try await perform(try request("GET", path, query: query, headers: headers, timeout: timeout))
    }

    func post(_ path: String, json body: Any = [String: Any](), query: [String: String] = [:],
              headers: [String: String] = [:], timeout: TimeInterval = 60) async throws -> APIResponse {
        var h = headers; h["Content-Type"] = "application/json"
        return try await perform(try request("POST", path, query: query, headers: h, body: try jsonBody(body), timeout: timeout))
    }

    func patch(_ path: String, json body: Any, query: [String: String] = [:]) async throws -> APIResponse {
        try await perform(try request("PATCH", path, query: query, headers: ["Content-Type": "application/json"], body: try jsonBody(body)))
    }

    func put(_ path: String, json body: Any, query: [String: String] = [:]) async throws -> APIResponse {
        try await perform(try request("PUT", path, query: query, headers: ["Content-Type": "application/json"], body: try jsonBody(body)))
    }

    func delete(_ path: String, json body: Any? = nil, query: [String: String] = [:]) async throws -> APIResponse {
        var h: [String: String] = [:]
        var data: Data?
        if let body { h["Content-Type"] = "application/json"; data = try jsonBody(body) }
        return try await perform(try request("DELETE", path, query: query, headers: h, body: data))
    }

    /// Multipart upload (`/api/upload`, `/api/coding/upload`).
    func postMultipart(_ path: String, _ body: MultipartBody, timeout: TimeInterval = 120) async throws -> APIResponse {
        try await perform(try request("POST", path, headers: ["Content-Type": body.contentType], body: body.encoded(), timeout: timeout))
    }

    /// Binary GET — images from `/api/media`, etc. `absolute` skips the base URL.
    ///
    /// An absolute URL can come out of a model's markdown (`![](https://…)`), so
    /// the session cookie and the Cloudflare service token go on the wire ONLY
    /// when the URL points at the paired server. Anything else is fetched bare —
    /// still fetched, because a public image should still render, but never with
    /// our credentials attached (security M7).
    func bytes(_ pathOrURL: String, absolute: Bool = false) async throws -> Data {
        if absolute {
            guard let url = URL(string: pathOrURL) else { throw APIError.badResponse("bad URL") }
            var req = URLRequest(url: url)
            if JarvisAPI.isPairedOrigin(url, base: credentials.baseURL) {
                for (k, v) in credentials.headers { req.setValue(v, forHTTPHeaderField: k) }
            } else {
                JcLog.core.notice("fetching \(url.host ?? "?", privacy: .public) without credentials")
            }
            return try await perform(req).data
        }
        return try await get(pathOrURL).data
    }

    /// Same scheme, host and port as the paired server — i.e. the same origin.
    static func isPairedOrigin(_ url: URL, base: URL?) -> Bool {
        guard let base,
              let host = url.host?.lowercased(), let baseHost = base.host?.lowercased(),
              host == baseHost,
              let scheme = url.scheme?.lowercased(), let baseScheme = base.scheme?.lowercased(),
              scheme == baseScheme
        else { return false }
        func port(_ u: URL, _ s: String) -> Int { u.port ?? (s == "https" ? 443 : 80) }
        return port(url, scheme) == port(base, baseScheme)
    }

    // MARK: Streams

    private func openStream(_ req: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (bytes, http) = try await transport.stream(req)
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await chunk in bytes { body.append(chunk); if body.count > 64 * 1024 { break } }
            throw APIError.http(status: http.statusCode, message: APIError.message(status: http.statusCode, body: body))
        }
        return (bytes, http)
    }

    /// GET `text/event-stream`.
    func streamSSE(_ path: String, query: [String: String] = [:], headers: [String: String] = [:]) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var h = headers; h["Accept"] = "text/event-stream"
                    let req = try request("GET", path, query: query, headers: h, timeout: 60 * 60)
                    let (bytes, _) = try await openStream(req)
                    try await Self.pumpSSE(bytes) { continuation.yield($0) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// POST JSON asking for SSE; yields events, or a single `.json` when the server
    /// answered with a plain JSON body instead (older servers).
    ///
    /// `onOpen` fires once, with the response headers, the moment the server has
    /// answered 2xx — i.e. the moment the POST is *committed*, whatever the body
    /// turns out to contain. A caller that would otherwise retry the request needs
    /// that signal: retrying a committed POST runs the turn twice (chat H13).
    func postSSEOrJSON(_ path: String, json body: Any, query: [String: String] = [:],
                       onOpen: (@Sendable (HTTPURLResponse) -> Void)? = nil) -> AsyncThrowingStream<SSEOrJSON, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try request("POST", path, query: query,
                                          headers: ["Content-Type": "application/json",
                                                    "Accept": "text/event-stream, application/json"],
                                          body: try jsonBody(body), timeout: 60 * 60)
                    let (bytes, http) = try await openStream(req)
                    onOpen?(http)
                    let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                    if !ctype.contains("event-stream") {
                        var data = Data()
                        for try await chunk in bytes { data.append(chunk) }
                        // A 2xx that isn't JSON is not "an empty result": it is a
                        // proxy page or a truncated tunnel reply, and swallowing it
                        // into `[:]` reads downstream as "the server said nothing
                        // useful, try again" (silent-failures M5).
                        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                            throw APIError.badResponse(
                                "\(path) returned \(ctype.isEmpty ? "no content type" : ctype), not JSON")
                        }
                        continuation.yield(.json(obj))
                        continuation.finish()
                        return
                    }
                    try await Self.pumpSSE(bytes) { continuation.yield(.event($0)) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Line-delimited JSON (GET or POST).
    func streamNDJSON(_ path: String, method: String = "GET", json body: Any? = nil,
                      query: [String: String] = [:]) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var h = ["Accept": "application/x-ndjson"]
                    var data: Data?
                    if let body { h["Content-Type"] = "application/json"; data = try jsonBody(body) }
                    let req = try request(method, path, query: query, headers: h, body: data, timeout: 60 * 60)
                    let (bytes, _) = try await openStream(req)
                    var yielded = 0
                    var skipped = 0
                    for try await line in bytes.allLines {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty { continue }
                        guard let d = t.data(using: .utf8),
                              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                            skipped += 1
                            continue
                        }
                        yielded += 1
                        continuation.yield(obj)
                    }
                    // Skipping the odd malformed row is resilience; skipping ALL of
                    // them is a broken endpoint reported as an empty result — the
                    // push-to-talk lane rides this stream (silent-failures M7).
                    if yielded == 0 && skipped > 0 {
                        throw APIError.badResponse("\(path): \(skipped) unparseable line(s), no JSON rows")
                    }
                    if skipped > 0 {
                        JcLog.core.warning("\(path, privacy: .public): skipped \(skipped) malformed NDJSON line(s)")
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func pumpSSE(_ bytes: AsyncThrowingStream<Data, Error>, _ emit: (SSEEvent) -> Void) async throws {
        var parser = SSEParser()
        for try await line in bytes.allLines {
            if let ev = parser.feed(line: line) { emit(ev) }
        }
        if let ev = parser.finish() { emit(ev) }
    }
}

/// Lets `post(json:)` accept any `Encodable` value.
struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

// MARK: - JSON helpers used by the feature APIs

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let v = self[key], !(v is NSNull), !(v is [Any]), !(v is [String: Any]) { return "\(v)" }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let i = self[key] as? Int { return i }
        if let d = self[key] as? Double { return Int(d) }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }
    func double(_ key: String) -> Double? {
        if let d = self[key] as? Double { return d }
        if let i = self[key] as? Int { return Double(i) }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let i = self[key] as? Int { return i != 0 }
        if let s = self[key] as? String { return ["1", "true", "yes"].contains(s.lowercased()) }
        return nil
    }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func list(_ key: String) -> [[String: Any]] { (self[key] as? [[String: Any]]) ?? [] }
    func strings(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

// MARK: - Line splitting that keeps empty lines (Foundation's `.lines` drops them,
// and a blank line is the SSE frame delimiter).

extension AsyncThrowingStream where Element == Data, Failure == Error {
    /// Every line, including empty ones; `\r\n` and `\n` both terminate a line. A final
    /// unterminated line is emitted too. Chunk boundaries are invisible: a line
    /// split across two `Data`s comes out whole.
    var allLines: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var buffer = [UInt8]()
                func emit() {
                    if buffer.last == 0x0D { buffer.removeLast() }
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll(keepingCapacity: true)
                }
                do {
                    for try await chunk in self {
                        // One pass per chunk rather than one await per byte: this is
                        // the hot path of every streamed turn.
                        var start = chunk.startIndex
                        while let newline = chunk[start...].firstIndex(of: 0x0A) {
                            buffer.append(contentsOf: chunk[start..<newline])
                            emit()
                            start = chunk.index(after: newline)
                        }
                        buffer.append(contentsOf: chunk[start...])
                    }
                    if !buffer.isEmpty { emit() }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AsyncThrowingStream where Element == UInt8, Failure == Error {
    /// The byte-at-a-time variant, kept for the parser tests and any caller that
    /// still has a byte sequence in hand. Production streams are `Data` chunks.
    var allLines: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var buffer = [UInt8]()
                do {
                    for try await b in self {
                        if b == 0x0A {
                            if buffer.last == 0x0D { buffer.removeLast() }
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(b)
                        }
                    }
                    if !buffer.isEmpty {
                        if buffer.last == 0x0D { buffer.removeLast() }
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
