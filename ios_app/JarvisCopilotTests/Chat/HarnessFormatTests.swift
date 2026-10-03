import XCTest
@testable import JarvisCopilot

final class HarnessFormatTests: XCTestCase {
    func testAnswerHandedOff() {
        XCTAssertEqual(HarnessFormat.answeredBy(HarnessMeta(kind: "answer", model: "@ollama-cloud:gemma4:31b",
                                                            ms: 900, handedOff: true)),
                       "gemma4:31b · 0.9 s · handed off")
    }

    func testBackground() {
        XCTAssertEqual(HarnessFormat.answeredBy(HarnessMeta(kind: "background",
                                                            model: "@claude-code:claude-sonnet-5-5", ms: 41000)),
                       "Claude Sonnet 5.5 · background · 41 s")
    }

    func testReviewWithNote() {
        XCTAssertEqual(HarnessFormat.answeredBy(HarnessMeta(kind: "review", model: "x",
                                                            note: "harness 'q' not found")),
                       "x · review · harness 'q' not found")
    }

    func testNil() { XCTAssertEqual(HarnessFormat.answeredBy(nil), "") }

    func testMetaFromStoredMessage() {
        let msg = ChatMessage(stored: ["role": "assistant", "content": "done",
                                       "_meta": ["kind": "background", "model": "@claude-code:claude-sonnet-5-5",
                                                 "ms": 1200, "handed_off": false]])
        XCTAssertEqual(msg?.meta?.kind, "background")
        XCTAssertTrue(msg?.meta?.isBackground ?? false)
    }

    func testTurnMetaEndSetsTheLiveMessagesMeta() {
        var state = ChatStreamState(startedAt: Date())
        ChatStreamReducer.apply(chatEvent("turn_meta", ["phase": "start", "model": "m"]), to: &state)
        XCTAssertNil(state.message.meta, "only the end frame carries the final numbers")
        ChatStreamReducer.apply(chatEvent("turn_meta", ["phase": "end", "model": "x", "ms": 500,
                                                        "kind": "answer"]), to: &state)
        XCTAssertEqual(state.message.meta?.model, "x")
        XCTAssertEqual(state.message.meta?.ms, 500)
    }
}
