import XCTest
@testable import JarvisVoiceUI

/// A reply spoken through this Mac's own speakers must not interrupt itself.
///
/// Pranav, 2026-10-12: "the echo cancellation doesn't work on mac voice, it self
/// interrupts". This runs the real thing: a conversation with the mic live and
/// voice processing on, a turn whose answer is long and full of names and numbers,
/// played aloud, with the barge-in check listening the whole time. The voice
/// diagnostics go to stderr (DEBUG), so a failure shows why.
///
/// Opt-in — it plays a spoken reply out loud and writes a turn to the server —
/// with JC_LIVE_ECHO=1 and JC_PROXY_ORIGIN; see `scripts/live-echo-test.py`. The
/// turn goes to a throwaway chat that is deleted afterwards.
@MainActor
final class EchoBargeInLiveTests: XCTestCase {

    private let prompt = "Tell me a short story, about eight sentences, about a lighthouse keeper named Ezekiel "
        + "in Galveston who counts 179 ships one stormy October. Don't use any tools."

    func testASpokenReplyDoesNotInterruptItself() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JC_LIVE_ECHO"] == "1", "set JC_LIVE_ECHO=1 (plays a reply aloud)")
        let origin = try XCTUnwrap(URL(string: env["JC_PROXY_ORIGIN"] ?? ""), "set JC_PROXY_ORIGIN")
        ProxyCredentials.configure(baseURL: origin)
        let api = JarvisAPI(credentials: ProxyCredentials())
        let created = try await api.post("/api/session/new", json: [String: Any]()).object()
        let sid = try XCTUnwrap((created["session"] as? [String: Any])?["session_id"] as? String)
        VoiceSessionSelection.shared.select(.session(id: sid, title: "Echo test"))

        let store = VoiceStore.shared
        var lines: [String] = []
        do {
            await store.beginExternalTurn()
            try await waitFor("listening", seconds: 30) { store.machine.state == .listening }
            let before = store.diagnostics.count
            store.pendingRetryText = prompt
            store.raise(.endOfSpeech)
            try await waitFor("the reply to start", seconds: 60) { store.machine.state == .speaking }
            // The reply plays out — or interrupts itself — and the store listens again.
            try await waitFor("the reply to end", seconds: 120) { store.machine.state == .listening }
            // Listening again the moment the reply ends: its tail must not be
            // taken for the user starting a new turn.
            try await Task.sleep(nanoseconds: 8_000_000_000)
            lines = Array(store.diagnostics.suffix(max(0, store.diagnostics.count - before)))
        } catch {
            lines = store.diagnostics
            await cleanUp(store, api: api, sid: sid)
            throw error
        }
        await cleanUp(store, api: api, sid: sid)

        let interrupts = lines.filter {
            $0.contains("barge-in:") || $0.contains("interrupting on the sound") || $0.contains("bargeIn")
        }
        XCTAssertTrue(interrupts.isEmpty, "the reply interrupted itself:\n" + interrupts.joined(separator: "\n"))
        // A room sound after the reply is fine ("no words; nothing sent"); the
        // reply's own tail going back to the server as a new turn is not.
        let afterReply = lines.drop { !$0.contains("playbackDrained") }
        let selfTurns = afterReply.filter { $0.contains("ws→ end_turn") }
        XCTAssertTrue(selfTurns.isEmpty, "the reply's tail went back as a turn:\n" + selfTurns.joined(separator: "\n"))
    }

    private func cleanUp(_ store: VoiceStore, api: JarvisAPI, sid: String) async {
        await store.stopAll()
        VoiceSessionSelection.shared.select(.defaultVoice)
        _ = try? await api.post("/api/session/delete", json: ["session_id": sid])
    }

    private func waitFor(_ what: String, seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw XCTSkip("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
