import Foundation

// MARK: - State

/// Everything one streaming turn can change. ``ChatStore`` owns an instance and
/// copies ``message`` back into the transcript after each frame; keeping the fold
/// pure means every server event shape is unit-testable without a socket.
struct ChatStreamState: Equatable, Sendable {
    /// The assistant turn being filled in.
    var message: ChatMessage
    /// When the user hit send — the origin for the stats line's elapsed seconds.
    var startedAt: Date

    var streamID: String?
    var sessionID: String?
    /// Set when the server names the session mid-turn.
    var sessionTitle: String?
    var clarify: ClarifyPrompt?

    /// Live usage mirror for the composer (the per-message copy lives on ``message``).
    var inputTokens: Int?
    var outputTokens: Int?
    var estimatedCost: Double?

    /// nil while the turn is still running.
    var outcome: Outcome?
    /// Any frame at all arrived — the signal that a fallback would double-submit.
    var receivedAnyEvent = false

    enum Outcome: Equatable, Sendable {
        case done
        case cancelled
        case failed(String)
    }

    init(message: ChatMessage = .assistant(streaming: true), startedAt: Date = Date()) {
        self.message = message
        self.startedAt = startedAt
    }

    /// The turn said or did something visible, so the server's stored copy would
    /// only overwrite it.
    var producedOutput: Bool { !message.plainText.isEmpty || !message.tools.isEmpty }
}

// MARK: - Reducer

/// Folds `/api/chat/stream` frames into a turn. Pure: no networking, no actor, no
/// clock of its own.
enum ChatStreamReducer {

    /// Apply one frame. Returns true when something changed, so the store can skip
    /// re-publishing for keepalives and no-op frames.
    @discardableResult
    static func apply(_ event: SSEEvent, to state: inout ChatStreamState, now: Date = Date()) -> Bool {
        state.receivedAnyEvent = true
        let object = event.object
        // On the `?stream=1` fast path there is no separate `started` frame, but
        // servers put the turn's id on the early frames — and Stop needs it.
        if let streamID = object.string("stream_id"), !streamID.isEmpty { state.streamID = streamID }

        switch event.event {
        case "started":
            state.streamID = object.string("stream_id") ?? state.streamID
            state.sessionID = object.string("session_id") ?? state.sessionID
            return true

        case "token", "delta", "text":
            let text = object.string("text") ?? object.string("delta") ?? object.string("content") ?? ""
            guard !text.isEmpty else { return false }
            noteFirstToken(&state, now: now)
            state.message.appendToken(text)
            return true

        case "reasoning", "thinking":
            let text = object.string("text") ?? object.string("delta") ?? ""
            guard !text.isEmpty else { return false }
            state.message.reasoning += text
            return true

        case "interim_assistant":
            // Text the agent said between tool rounds. Only adopt it when nothing
            // has streamed yet — otherwise it double-prints the same words.
            guard object["already_streamed"] as? Bool != true, state.message.plainText.isEmpty else { return false }
            let text = object.string("text") ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            noteFirstToken(&state, now: now)
            state.message.appendToken(text)
            return true

        case "tool", "tool_start", "tool_call":
            let name = object.string("name") ?? "tool"
            // `clarify` reaches the UI as a question, not a tool row.
            guard name != "clarify" else { return false }
            let args = JSONValue(object["args"] ?? object["input"]).objectValue ?? [:]
            state.message.startTool(ToolInvocation(
                id: toolID(in: object) ?? UUID().uuidString,
                name: name,
                args: args,
                preview: object.string("preview")))
            return true

        case "tool_complete", "tool_end", "tool_result":
            let name = object.string("name")
            guard name != "clarify" else { return false }
            state.message.completeTool(
                id: toolID(in: object),
                name: name,
                durationSec: object.double("duration") ?? object.double("duration_sec"),
                isError: object["is_error"] as? Bool == true,
                preview: object.string("preview"),
                result: object.string("result") ?? object.string("snippet") ?? object.string("output"))
            return true

        case "metering", "usage":
            return applyUsage(object, to: &state)

        case "clarify":
            let question = (object.string("question") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return false }
            let choices = (object["choices_offered"] as? [Any] ?? object["choices"] as? [Any] ?? [])
                .map { "\($0)" }
            state.clarify = ClarifyPrompt(question: question, choices: choices)
            return true

        case "title":
            let title = (object.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return false }
            state.sessionTitle = title
            return true

        case "error", "apperror":
            fail(&state, object.string("message") ?? object.string("error") ?? "Request failed")
            return true

        case "cancel", "cancelled":
            state.outcome = .cancelled
            return true

        case "done", "stream_end", "complete":
            _ = applyUsage(object, to: &state)
            // The done payload carries the authoritative session; pick up a freshly
            // generated title if we don't have one yet.
            if let title = object.dict("session")?.string("title")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                state.sessionTitle = title
            }
            // Some servers only send the whole answer here.
            if state.message.plainText.isEmpty,
               let text = object.string("answer") ?? object.string("text"), !text.isEmpty {
                state.message.appendToken(text)
            }
            state.outcome = .done
            return true

        default:
            // Unknown events are ignored so future server-side additions don't
            // break a turn — but they still prove the stream is alive.
            return false
        }
    }

    /// End the turn: stamp the elapsed time, stop every spinner, and leave a marker
    /// if a cancel came in before anything was said.
    static func finish(_ state: inout ChatStreamState, cancelled: Bool = false, now: Date = Date()) {
        state.message.streaming = false
        state.message.closeOpenTools()
        state.message.dropEmptyTextBlocks()

        var stats = state.message.stats ?? ChatTurnStats()
        stats.durationMs = Int(now.timeIntervalSince(state.startedAt) * 1_000)
        state.message.stats = stats

        if cancelled, state.message.blocks.isEmpty, state.message.reasoning.isEmpty, !state.message.isError {
            state.message.blocks.append(.text(TextBlock(text: "_(cancelled)_")))
        }
        if state.outcome == nil { state.outcome = cancelled ? .cancelled : .done }
    }

    /// Surface `message` in the reply bubble (Flutter's `_failLive`), keeping any
    /// partial answer above it.
    static func fail(_ state: inout ChatStreamState, _ message: String) {
        state.message.streaming = false
        state.message.isError = true
        state.message.closeOpenTools()
        state.message.dropEmptyTextBlocks()
        state.message.blocks.append(.text(TextBlock(text: message)))
        state.outcome = .failed(message)
    }

    /// History fallback: fill a turn that produced nothing from the server's stored
    /// copy. Never overwrites what we streamed ourselves.
    @discardableResult
    static func adopt(_ snapshot: SessionSnapshot, into state: inout ChatStreamState) -> Bool {
        guard !state.producedOutput,
              let text = snapshot.lastAssistantText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        state.message.appendToken(text)
        return true
    }

    // MARK: Bits

    private static func noteFirstToken(_ state: inout ChatStreamState, now: Date) {
        guard state.message.plainText.isEmpty else { return }
        var stats = state.message.stats ?? ChatTurnStats()
        guard stats.firstTokenMs == nil else { return }
        stats.firstTokenMs = Int(now.timeIntervalSince(state.startedAt) * 1_000)
        state.message.stats = stats
    }

    private static func toolID(in object: [String: Any]) -> String? {
        for key in ["tid", "tool_call_id", "call_id", "id"] {
            if let id = object.string(key), !id.isEmpty { return id }
        }
        return nil
    }

    /// The metering event nests usage inconsistently (top level, `usage`, `data`, or
    /// `data.usage`), and providers disagree on the field names, so dig through all
    /// of them for each field.
    private static func applyUsage(_ object: [String: Any], to state: inout ChatStreamState) -> Bool {
        let nests: [[String: Any]] = [
            object,
            object.dict("usage") ?? [:],
            object.dict("data") ?? [:],
            object.dict("data")?.dict("usage") ?? [:],
        ]
        func dig(_ keys: [String]) -> Int? {
            for nest in nests {
                for key in keys {
                    if let value = nest.int(key) { return value }
                }
            }
            return nil
        }
        func digDouble(_ keys: [String]) -> Double? {
            for nest in nests {
                for key in keys {
                    if let value = nest.double(key) { return value }
                }
            }
            return nil
        }

        let input = dig(["input_tokens", "prompt_tokens", "input"])
        let output = dig(["output_tokens", "completion_tokens", "output"])
        let cost = digDouble(["estimated_cost", "cost"])
        // The server says outright when it can't measure generation speed.
        let tps = object["tps_available"] as? Bool == false ? nil : digDouble(["tps", "tokens_per_second"])
        let estimated = nests.compactMap { $0["estimated"] as? Bool }.first

        guard input != nil || output != nil || cost != nil || tps != nil || estimated != nil else { return false }

        var stats = state.message.stats ?? ChatTurnStats()
        if let input { stats.inputTokens = input; state.inputTokens = input }
        if let output { stats.outputTokens = output; state.outputTokens = output }
        if let tps { stats.tokensPerSecond = tps }
        if let estimated { stats.estimated = estimated }
        if let cost { state.estimatedCost = cost }
        state.message.stats = stats
        return true
    }
}

// MARK: - Time

/// The clock the turn's watchdog reads, injected so "45 seconds of silence" is
/// instant and deterministic in tests.
protocol ChatClock: Sendable {
    var now: Date { get }
    func sleep(for seconds: TimeInterval) async throws
}

struct SystemChatClock: ChatClock {
    var now: Date { Date() }
    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// How hard the store tries to stay attached to a turn.
struct ChatResilience: Equatable, Sendable {
    /// No real event for this long means the phone's consumer was starved (another
    /// client drained the single-consumer queue) or the connection died quietly.
    var idleLimit: TimeInterval = 45
    /// How often the watchdog looks.
    var checkStep: TimeInterval = 5
    /// Re-attach attempts before giving up (~10 minutes at the default limit).
    var maxReattach: Int = 12
}

enum ChatStreamError: LocalizedError, Equatable {
    case stalled
    var errorDescription: String? {
        switch self {
        case .stalled: return "Lost the live stream"
        }
    }
}

/// Wrap an event stream so `limit` seconds without an element surfaces as
/// ``ChatStreamError/stalled``.
///
/// The server keeps the SSE connection alive with heartbeats long after the answer,
/// and its per-turn event queue is single-consumer: when the web UI is open on the
/// same session it drains the queue and our socket stays open and empty. Silence is
/// therefore the only signal we have, and the cure is to snapshot the session and
/// re-attach rather than to fail the turn.
func withStallDetection<T: Sendable>(_ upstream: AsyncThrowingStream<T, Error>,
                                     limit: TimeInterval, step: TimeInterval = 5,
                                     clock: ChatClock) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
        let lastEvent = IdleMark(clock.now)
        let pump = Task {
            do {
                for try await element in upstream {
                    lastEvent.touch(clock.now)
                    continuation.yield(element)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let watchdog = Task {
            while !Task.isCancelled {
                do { try await clock.sleep(for: step) } catch { return }
                if clock.now.timeIntervalSince(lastEvent.value) > limit {
                    continuation.finish(throwing: ChatStreamError.stalled)
                    return
                }
            }
        }
        continuation.onTermination = { _ in pump.cancel(); watchdog.cancel() }
    }
}

/// Timestamp of the last real stream event, shared with the watchdog.
private final class IdleMark: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date { lock.lock(); defer { lock.unlock() }; return stored }
    func touch(_ date: Date) { lock.lock(); stored = date; lock.unlock() }
}
