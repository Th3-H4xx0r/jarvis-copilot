import Foundation
import XCTest
@testable import JarvisCopilot

/// A transport scripted per `"METHOD /path"`, able to do the two things
/// `MockTransport` cannot and that the chat resilience rules need:
///   * fail a byte stream *after* it already delivered SSE frames (the exact case
///     the "never fall back once an event reached the caller" rule guards), and
///   * hold a stream open forever (so the stall watchdog is what ends the turn).
/// Steps for the same key are consumed in order, so a re-attach can be scripted
/// as two different `GET /api/chat/stream` replies.
final class ScriptedTransport: APITransport, @unchecked Sendable {

    struct Step {
        var status = 200
        var contentType = "application/json"
        var body = Data()
        /// Thrown instead of connecting at all.
        var upfrontError: Error?
        /// Thrown after `body` was delivered — a mid-stream failure.
        var trailingError: Error?
        /// Never finish the stream after `body` (the server is quiet, not gone).
        var hold = false

        static func json(_ obj: Any, status: Int = 200) -> Step {
            Step(status: status, body: try! JSONSerialization.data(withJSONObject: obj))
        }
        static func sse(_ frames: String, then error: Error? = nil) -> Step {
            Step(contentType: "text/event-stream", body: Data(frames.utf8), trailingError: error)
        }
        /// SSE frames followed by silence — the socket stays up with nothing on it.
        static func sseHolding(_ frames: String = "") -> Step {
            Step(contentType: "text/event-stream", body: Data(frames.utf8), hold: true)
        }
        static func failing(_ error: Error) -> Step { Step(upfrontError: error) }
    }

    private let lock = NSLock()
    private var steps: [(key: String, step: Step)] = []
    private var _log: [String] = []
    private var _requests: [URLRequest] = []
    private var openStreams: [AsyncThrowingStream<Data, Error>.Continuation] = []

    /// `key` is `"METHOD /path"` (query ignored).
    @discardableResult
    func on(_ key: String, _ step: Step) -> Self {
        lock.lock(); steps.append((key, step)); lock.unlock(); return self
    }

    /// Every request as `"METHOD /path"`, in order.
    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func count(_ key: String) -> Int { log.filter { $0 == key }.count }
    func lastBody(for key: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        for req in _requests.reversed() where "\(req.httpMethod ?? "") \(req.url?.path ?? "")" == key {
            if let d = req.httpBody { return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
        }
        return [:]
    }
    func query(_ key: String, _ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        for req in _requests.reversed() where "\(req.httpMethod ?? "") \(req.url?.path ?? "")" == key {
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let v = items.first(where: { $0.name == name })?.value { return v }
        }
        return nil
    }

    /// Let every held-open stream finish, so a test can unwind cleanly.
    func closeHeldStreams() {
        lock.lock(); let open = openStreams; openStreams = []; lock.unlock()
        open.forEach { $0.finish() }
    }

    private func take(_ request: URLRequest) throws -> Step {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        lock.lock(); defer { lock.unlock() }
        _log.append(key)
        _requests.append(request)
        guard let i = steps.firstIndex(where: { $0.key == key }) else {
            throw APIError.badResponse("ScriptedTransport: nothing scripted for \(key)")
        }
        return steps.remove(at: i).step
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step = try take(request)
        if let e = step.upfrontError { throw e }
        return (step.body, Self.response(request, step))
    }

    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let step = try take(request)
        if let e = step.upfrontError { throw e }
        let http = Self.response(request, step)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            if !step.body.isEmpty { continuation.yield(step.body) }
            if let e = step.trailingError { continuation.finish(throwing: e) }
            else if step.hold {
                lock.lock(); openStreams.append(continuation); lock.unlock()
            } else { continuation.finish() }
        }
        return (stream, http)
    }

    private static func response(_ request: URLRequest, _ step: Step) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: nil,
                        headerFields: ["Content-Type": step.contentType])!
    }
}

extension JarvisAPI {
    /// A client wired to a `ScriptedTransport`.
    static func scripted() -> (JarvisAPI, ScriptedTransport) {
        let t = ScriptedTransport()
        return (JarvisAPI(credentials: TestCredentials(), transport: t), t)
    }
}

/// Virtual time for the stall watchdog: `sleep` parks until a test moves `now`
/// past the sleeper's deadline, so "45 s of silence" is deterministic and instant.
///
/// Cancelling a sleeping task unparks it immediately, so ``parked`` counts only
/// live watchdogs — a test can wait for the *current* watchdog to arm itself
/// without being fooled by the one whose stream just ended.
final class ManualChatClock: ChatClock, @unchecked Sendable {
    private typealias Waiter = (deadline: Date, continuation: CheckedContinuation<Void, Error>)

    private let lock = NSLock()
    private var current: Date
    private var waiters: [UUID: Waiter] = [:]
    /// Tasks cancelled before their sleep registered.
    private var cancelledEarly: Set<UUID> = []
    private var failing = false

    /// Make every `sleep` fail immediately — a clock that has stopped ticking, so
    /// a polling loop ends on its own rather than by cancellation.
    var failSleeps: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); failing = newValue; lock.unlock() }
    }

    struct Stopped: Error {}

    init(_ start: Date = Date(timeIntervalSince1970: 1_000)) { current = start }

    var now: Date { lock.lock(); defer { lock.unlock() }; return current }

    func sleep(for seconds: TimeInterval) async throws {
        if failSleeps { throw Stopped() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledEarly.remove(id) != nil {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                let deadline = current.addingTimeInterval(seconds)
                if deadline <= current { lock.unlock(); continuation.resume(); return }
                waiters[id] = (deadline, continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            if waiter == nil { cancelledEarly.insert(id) }
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Sleepers currently parked — a test waits for this before advancing so it
    /// can't outrun the watchdog registering its next sleep.
    var parked: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = waiters.filter { $0.value.deadline <= current }
        due.keys.forEach { waiters[$0] = nil }
        lock.unlock()
        due.values.forEach { $0.continuation.resume() }
    }

    /// Release everything (used to unwind a test that is done with the clock).
    func releaseAll() {
        lock.lock(); let all = waiters; waiters = [:]; lock.unlock()
        all.values.forEach { $0.continuation.resume() }
    }
}

/// Spin the cooperative pool until `condition` holds, so a test can wait for
/// another task's progress without sleeping a fixed amount.
func waitUntil(_ description: String, timeout: TimeInterval = 3,
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting for \(description)", file: file, line: line)
            return
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Drains an async stream from a background task while the test inspects what has
/// arrived so far (a plain `var` can't be captured mutably by a `@Sendable` task).
final class StreamCollector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var failure: Error?
    private var done = false

    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }

    @discardableResult
    func consume<S: AsyncSequence>(_ stream: S) -> Task<Void, Never> where S.Element == T {
        Task {
            do {
                for try await item in stream {
                    lock.lock(); items.append(item); lock.unlock()
                }
            } catch {
                lock.lock(); failure = error; lock.unlock()
            }
            lock.lock(); done = true; lock.unlock()
        }
    }
}

/// Build one SSE frame body from `(event, payload)` pairs.
func sseFrames(_ events: [(String, [String: Any])]) -> String {
    events.map { name, payload in
        let data = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return "event: \(name)\ndata: \(data)\n\n"
    }.joined()
}

/// An `SSEEvent` as the parser would produce it, for reducer tests.
func chatEvent(_ name: String, _ payload: [String: Any] = [:]) -> SSEEvent {
    let data = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    return SSEParser.decode(event: name, data: data)
}
