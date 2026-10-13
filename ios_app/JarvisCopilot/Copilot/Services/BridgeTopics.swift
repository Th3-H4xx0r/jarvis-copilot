import Foundation

/// What the phone wants the server to push over the bridge socket, instead of asking for it on a
/// timer. Each screen or service that needs a topic says so (`want`) and lets go (`drop`); the
/// server hears the whole set in one `subscribe` frame and coalesces per topic, so a topic wanted
/// "every 1800 s" reaches the phone at most twice an hour however often it changes.
///
/// The server forgets subscriptions with the socket, so the set goes out again after every
/// `hello`, and `onResync` handlers run then: anything pushed while the socket was down was
/// missed, and each owner fetches once to catch up.
@MainActor
final class BridgeTopics {
    static let shared = BridgeTopics()

    /// topic → owner → minimum seconds between pushes.
    private var wants: [String: [String: TimeInterval]] = [:]
    private var handlers: [String: [([String: Any]) -> Void]] = [:]
    private var resyncs: [() -> Void] = []
    private var sent: [String: TimeInterval]?
    /// Where the frame goes; the bridge client in the app, a recorder in tests.
    var send: ([String: Any]) -> Void = { BridgeClient.shared.sendSubscription($0) }

    init() {}

    /// `owner` wants `topic` pushed at most every `every` seconds (0 = every change).
    func want(_ topic: String, owner: String, every: TimeInterval = 0) {
        wants[topic, default: [:]][owner] = max(0, every)
        flush()
    }

    func drop(_ topic: String, owner: String) {
        wants[topic]?[owner] = nil
        if wants[topic]?.isEmpty == true { wants[topic] = nil }
        flush()
    }

    /// Runs `handler` with the push's `data` for every `topic` frame.
    func on(_ topic: String, _ handler: @escaping ([String: Any]) -> Void) {
        handlers[topic, default: []].append(handler)
    }

    /// Runs after the socket comes back and the subscription went out again.
    func onResync(_ handler: @escaping () -> Void) {
        resyncs.append(handler)
    }

    /// The effective set: per topic, the most eager owner wins.
    var topics: [String: TimeInterval] {
        wants.compactMapValues { $0.values.min() }
    }

    var frame: [String: Any] {
        ["type": "subscribe", "topics": topics]
    }

    func isWanted(_ topic: String) -> Bool { wants[topic] != nil }

    /// A `topic` frame from the server.
    func deliver(_ message: [String: Any]) {
        guard let topic = message["topic"] as? String else { return }
        let data = message["data"] as? [String: Any] ?? [:]
        for handler in handlers[topic] ?? [] { handler(data) }
    }

    /// The socket said hello: the server knows nothing of us yet.
    func resubscribe() {
        sent = nil
        flush()
        for handler in resyncs { handler() }
    }

    /// The socket is gone: the next connect has to send the set again.
    func forget() { sent = nil }

    private func flush() {
        let now = topics
        guard now != sent else { return }
        sent = now
        send(frame)
    }
}
