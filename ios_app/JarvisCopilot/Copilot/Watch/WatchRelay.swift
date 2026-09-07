import Foundation

// Ported verbatim from the Flutter client's Runner/WatchBridge.swift. These are
// pure — no networking, no WCSession — and keep their original unit tests.

// MARK: - Pure, testable relay helpers (no I/O — unit-tested in WatchBridgeTests)

enum WatchRelay {
    /// Parse an SSE buffer in the webui chat-stream format:
    ///   event: <name>\n data: <json>\n\n
    /// The server (webui/api/streaming.py) emits assistant text as `token`
    /// events, signals failures as `apperror`, and terminates the stream with
    /// `stream_end` (`done` carries {session,usage}, no top-level text). We
    /// accept `done` too as a terminator and `cancel`/`error` as failures for
    /// forward-compat. Returns accumulated text, whether the stream ended, and
    /// whether it errored.
    static func accumulateSSE(_ buffer: String) -> (text: String, done: Bool, errored: Bool) {
        var text = ""
        var done = false
        var errored = false
        var currentEvent = ""
        for rawLine in buffer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(":") { continue } // heartbeat comment
            if line.hasPrefix("event:") {
                currentEvent = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                guard let d = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { continue }
                switch currentEvent {
                case "token": if let t = obj["text"] as? String { text += t }
                case "stream_end", "done": done = true
                case "apperror", "error", "cancel": errored = true
                default: break
                }
            }
        }
        return (text, done, errored)
    }

    /// `/api/session/new` nests the id under `session.session_id`; some endpoints
    /// expose it top-level. Handle both.
    static func extractSessionId(_ obj: [String: Any]) -> String? {
        if let s = obj["session_id"] as? String, !s.isEmpty { return s }
        if let inner = obj["session"] as? [String: Any],
           let s = inner["session_id"] as? String, !s.isEmpty { return s }
        return nil
    }

    /// plan 1.6a — incremental sentence splitter fed SSE text deltas as they
    /// arrive, so synthesis of sentence N can start while the stream keeps
    /// going instead of waiting for the whole reply (`WatchBridge.streamReply`
    /// used to accumulate everything first).
    ///
    /// Mirrors the server's `_take_complete_sentences`
    /// (webui/api/voice.py:1105): the FIRST sentence flushes at ANY
    /// terminator (min_len 0 — a near-instant ack), every later one only
    /// once the buffer holds >=110 chars (so we don't fire off a synth call
    /// per word). One call may flush more than one sentence at once — it
    /// takes everything up to the LAST terminator in the buffer, exactly
    /// like the server.
    final class SentenceSplitter {
        /// Non-first-sentence flush threshold. plan 1.6a.
        private static let minLenAfterFirst = 110
        private static let terminator = try! NSRegularExpression(
            pattern: "[.!?](?:[\"')\\]]+)?(?:\\s|$)")

        private var buffer = ""
        private var firstEmitted = false

        /// Feed one text delta; returns zero or more sentence chunks now
        /// ready to speak (usually zero or one).
        func feed(_ delta: String) -> [String] {
            buffer += delta
            var out: [String] = []
            while let chunk = takeComplete() { out.append(chunk) }
            return out
        }

        /// Stream ended — flush whatever remains, even without a terminator.
        func finish() -> String? {
            let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            return rest.isEmpty ? nil : rest
        }

        private func takeComplete() -> String? {
            let minLen = firstEmitted ? Self.minLenAfterFirst : 0
            guard buffer.count >= minLen else { return nil }
            let ns = buffer as NSString
            let matches = Self.terminator.matches(in: buffer, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { return nil }
            let cut = last.range.location + last.range.length
            let head = ns.substring(to: cut).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ns.substring(from: cut)
            firstEmitted = true
            return head.isEmpty ? nil : head
        }
    }

    /// plan 1.6c — pure decision logic for the watch's instant spoken ack.
    ///
    /// This is a byte-for-byte port of `AckTimer` in
    /// `JarvisWatch Watch App/AckTimer.swift`. It has to be duplicated rather
    /// than shared: the Watch App and Runner are separate compiled targets
    /// with no common framework between them, and `RunnerTests` (the only
    /// test target that actually exists in project.pbxproj — see the
    /// "no JarvisWatch Watch AppTests target" note in F-report.md) can only
    /// see Runner-visible code. Keep the two copies in sync if the decision
    /// logic ever changes.
    enum AckTimer {
            /// How long the watch waits for the JARVIS clip before falling back to its
        /// own voice.
        ///
        /// This is a FAILURE backstop, not a race the built-in voice is meant to
        /// win. At 700 ms it won almost every time: a real turn synthesizes on the
        /// server and is relayed by the phone, which takes longer than that even
        /// when the phone is in the foreground — so the watch spoke in the system
        /// voice and the JARVIS clip arrived to a stopped synthesizer. Long enough
        /// now that the clip normally wins, short enough that a turn whose audio
        /// never arrives is still spoken.
        static let localVoiceFallbackMs = 6000

        enum Decision: Equatable {
            case wait          // keep waiting for the hi-fi clip
            case speakLocally  // speak the sentence with the built-in voice now
            case clipWon       // the hi-fi clip already arrived — nothing to do
        }

        static func decide(elapsedMs: Int, clipArrived: Bool, preferLocalVoice: Bool) -> Decision {
            if clipArrived { return .clipWon }
            if preferLocalVoice { return .speakLocally }
            return elapsedMs >= localVoiceFallbackMs ? .speakLocally : .wait
        }
    }
}
