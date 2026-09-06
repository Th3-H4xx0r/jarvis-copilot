import Foundation
import XCTest
@testable import JarvisCopilot

/// Fixed credentials for tests.
struct TestCredentials: APICredentials {
    var baseURL: URL? = URL(string: "https://jarvis.test")
    var headers: [String: String] = ["Cookie": "hermes_session=abc"]
}

/// Scriptable transport. Queue responses with `enqueue`; inspect `requests` afterwards.
/// Shared by every test that exercises a feature API against `JarvisAPI`.
final class MockTransport: APITransport, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = ["Content-Type": "application/json"]
        var error: Error? = nil
    }

    private let lock = NSLock()
    private var replies: [Reply] = []
    private(set) var requests: [URLRequest] = []

    /// Reply that matches a request path (first match wins), else FIFO.
    private var routed: [(String, Reply)] = []

    func enqueue(_ reply: Reply) { lock.lock(); replies.append(reply); lock.unlock() }
    func enqueue(json: Any, status: Int = 200) {
        enqueue(Reply(status: status, body: try! JSONSerialization.data(withJSONObject: json)))
    }
    func enqueue(text: String, status: Int = 200, contentType: String = "text/plain") {
        enqueue(Reply(status: status, body: Data(text.utf8), headers: ["Content-Type": contentType]))
    }
    func enqueueSSE(_ frames: String) {
        enqueue(Reply(status: 200, body: Data(frames.utf8), headers: ["Content-Type": "text/event-stream"]))
    }
    func enqueue(error: Error) { enqueue(Reply(error: error)) }
    /// Route by path substring, regardless of order.
    func route(_ pathContains: String, json: Any, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        routed.append((pathContains, Reply(status: status, body: try! JSONSerialization.data(withJSONObject: json))))
    }

    var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    func lastBody() -> [String: Any] {
        guard let d = lastRequest?.httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    private func next(for request: URLRequest) throws -> Reply {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let path = request.url?.path ?? ""
        if let i = routed.firstIndex(where: { path.contains($0.0) }) { return routed[i].1 }
        guard !replies.isEmpty else {
            throw APIError.badResponse("MockTransport: no reply queued for \(request.httpMethod ?? "") \(path)")
        }
        return replies.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let r = try next(for: request)
        if let e = r.error { throw e }
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: r.headers)!
        return (r.body, http)
    }

    /// Deliberately delivered in small `Data` chunks that cut *across* line
    /// boundaries, so every test that streams also exercises the transport's
    /// chunk reassembly.
    static let chunkSize = 7

    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let r = try next(for: request)
        if let e = r.error { throw e }
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: r.headers)!
        let body = r.body
        let stream = AsyncThrowingStream<Data, Error> { c in
            var index = body.startIndex
            while index < body.endIndex {
                let end = body.index(index, offsetBy: Self.chunkSize, limitedBy: body.endIndex) ?? body.endIndex
                c.yield(body[index..<end])
                index = end
            }
            c.finish()
        }
        return (stream, http)
    }
}

extension JarvisAPI {
    /// A client wired to a fresh `MockTransport`.
    static func mocked() -> (JarvisAPI, MockTransport) {
        let t = MockTransport()
        return (JarvisAPI(credentials: TestCredentials(), transport: t), t)
    }
}

/// Collect an async stream into an array (with a timeout so a hung stream fails
/// instead of stalling the suite).
func collect<T>(_ stream: AsyncThrowingStream<T, Error>, timeout: TimeInterval = 5) async throws -> [T] {
    try await withThrowingTaskGroup(of: [T].self) { group in
        group.addTask {
            var out: [T] = []
            for try await x in stream { out.append(x) }
            return out
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw APIError.badResponse("collect: timed out")
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
