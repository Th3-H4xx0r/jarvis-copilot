import Foundation
import XCTest
@testable import JarvisCopilot

/// Request introspection shared by the "More" API tests. Every endpoint test
/// asserts method + path + query + body, so these keep that one line long.
extension MockTransport {
    var lastMethod: String? { lastRequest?.httpMethod }
    var lastPath: String? { lastRequest?.url?.path }

    /// Decoded query string of the last request (`[:]` when there was none).
    var lastQuery: [String: String] {
        guard let url = lastRequest?.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    }

    /// The nth request (0-based), for multi-call flows.
    func request(_ index: Int) -> URLRequest? {
        index < requests.count ? requests[index] : nil
    }

    func path(_ index: Int) -> String? { request(index)?.url?.path }
    func method(_ index: Int) -> String? { request(index)?.httpMethod }

    func query(_ index: Int) -> [String: String] {
        guard let url = request(index)?.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    }

    func body(_ index: Int) -> JSONObject {
        guard let data = request(index)?.httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject ?? [:]
    }

    /// Every path hit so far, in order — handy for fan-out loads.
    var paths: [String] { requests.compactMap { $0.url?.path } }
}

/// A notifier that records what the connection monitor decided to announce.
final class RecordingNotifier: ConnectionNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(title: String, body: String)] = []

    var posted: [(title: String, body: String)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var titles: [String] { posted.map(\.title) }

    func notify(title: String, body: String) {
        lock.lock(); storage.append((title, body)); lock.unlock()
    }
}

/// Resumes immediately so debounce/poll logic runs without wall-clock waits.
let instantSleeper: @Sendable (TimeInterval) async throws -> Void = { _ in
    await Task.yield()
}

/// Records the designs pushed into the widget's App Group cache.
actor SpyIslandCache: IslandDesignCache {
    private(set) var pushes: [[JSONObject]] = []
    private(set) var clears = 0

    func cacheDesigns(_ payloads: [JSONObject]) async { pushes.append(payloads) }
    func clearCache() async { clears += 1 }

    /// Design ids in the order they were pushed, flattened.
    var pushedIDs: [[String]] {
        pushes.map { batch in batch.map { MoreJSON.text($0["id"]) } }
    }
}

/// Assert a `[String: Any]` dictionary equals the expected pairs, comparing via
/// JSON so `NSNumber` vs `Int` never trips a test up.
func assertJSONEqual(_ actual: JSONObject, _ expected: JSONObject,
                     _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let a = MoreJSON.canonicalJSON(actual)
    let b = MoreJSON.canonicalJSON(expected)
    XCTAssertEqual(a, b, message, file: file, line: line)
}
