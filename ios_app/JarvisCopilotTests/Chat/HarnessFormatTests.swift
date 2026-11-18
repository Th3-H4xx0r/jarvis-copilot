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

    // MARK: the tidy footer (2026-11-02): "model · time", the rest on tap

    func testFooterSummaryIsModelAndTime() {
        var meta = HarnessMeta(kind: "answer", model: "@anthropic-api:claude-haiku-5-5", ms: 8700)
        meta.route = HarnessRoute(label: "default", by: "decision", confidence: 0.28)
        let stats = ChatTurnStats(inputTokens: 8, cachedTokens: 40_000, outputTokens: 825, durationMs: 9100)
        XCTAssertEqual(HarnessFormat.footerSummary(meta: meta, stats: stats, onDevice: false), "Claude Haiku 5.5 · 9.1 s")
        XCTAssertEqual(HarnessFormat.footerSummary(meta: nil, stats: stats, onDevice: true), "On-device · 9.1 s")
        XCTAssertEqual(HarnessFormat.footerSummary(meta: HarnessMeta(kind: "background", model: "@x:claude-sonnet-5-5", ms: 41000),
                                                   stats: nil, onDevice: false), "Claude Sonnet 5.5 · background · 41 s")
    }

    func testFooterDetailsCarryTheRest() {
        var meta = HarnessMeta(kind: "answer", model: "@anthropic-api:claude-haiku-5-5", ms: 8700, handedOff: true)
        meta.route = HarnessRoute(label: "default", by: "decision", confidence: 0.28)
        let stats = ChatTurnStats(inputTokens: 8, cachedTokens: 40_000, outputTokens: 825, durationMs: 9100)
        let rows = HarnessFormat.footerDetails(meta: meta, stats: stats)
        XCTAssertEqual(rows.map(\.0), ["Model", "Route", "Handed off", "Time", "Tokens", "Cache"])
        XCTAssertEqual(rows.first { $0.0 == "Route" }?.1, "default 28%")
        XCTAssertEqual(rows.first { $0.0 == "Tokens" }?.1, "40.0k in · 825 out")
        XCTAssertEqual(rows.first { $0.0 == "Cache" }?.1, "100% hit")
        XCTAssertTrue(HarnessFormat.footerDetails(meta: nil, stats: nil).isEmpty)
    }

    func testAnsweredByAddsRoute() {
        var meta = HarnessMeta(kind: "answer", model: "@claude-code:claude-sonnet-5-5", ms: 3200)
        meta.route = HarnessRoute(label: "deep", by: "decision", confidence: 0.82)
        XCTAssertEqual(HarnessFormat.answeredBy(meta), "Claude Sonnet 5.5 · 3.2 s · routed deep 82%")
        meta.route = HarnessRoute(label: "default", by: "decision", error: "timed out")
        XCTAssertEqual(HarnessFormat.answeredBy(meta), "Claude Sonnet 5.5 · 3.2 s · routed default (router failed)")
        meta.route = HarnessRoute(label: "quick", by: "rules")
        XCTAssertEqual(HarnessFormat.answeredBy(meta), "Claude Sonnet 5.5 · 3.2 s · routed quick")
    }

    /// A background / review reply is its own message: the route belongs to the answer.
    func testSideReplyGetsNoRoute() {
        var meta = HarnessMeta(kind: "background", model: "@claude-code:claude-sonnet-5-5", ms: 3200)
        meta.route = HarnessRoute(label: "deep")
        XCTAssertEqual(HarnessFormat.answeredBy(meta), "Claude Sonnet 5.5 · background · 3.2 s")
    }

    func testRouteParsedFromMetaJSON() {
        let meta = HarnessMeta(json: ["model": "@x:y", "route": ["label": "deep", "by": "decision",
                                                                  "confidence": 0.5, "ms": 71]])
        XCTAssertEqual(meta?.route?.label, "deep")
        XCTAssertEqual(meta?.route?.confidence, 0.5)
        XCTAssertEqual(meta?.route?.ms, 71)
        XCTAssertNil(HarnessMeta(json: ["model": "@x:y"])?.route)
    }

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

// The IT agent's card (W5 `it`): checks and sources live; a lost run names the phase it reached.
final class HarnessJobITTests: XCTestCase {
    func testITLine() {
        var job = HarnessJob(id: "j", label: "IT agent", startedAt: 1)
        XCTAssertNil(HarnessJobFormat.itLine(job))
        job.it = HarnessJobIT(state: "working", phase: "Install", phaseNo: 2, phases: 4, checksPassed: 1, step: "winget",
                              brief: "", sources: 5)
        XCTAssertEqual(HarnessJobFormat.itLine(job), "Checks 1/4 passed · 5 sources")
        job.it = HarnessJobIT(state: "researching", phase: "", phaseNo: 0, phases: 0, checksPassed: 0, step: "",
                              brief: "", sources: 3)
        XCTAssertEqual(HarnessJobFormat.itLine(job), "3 sources read")
    }

    func testLostITLineNamesPhase() {
        let job = HarnessJob(json: ["id": "j", "label": "IT agent", "status": "lost", "started_at": 1,
                                    "it": ["state": "working", "phase": "Enable WSL2", "phase_no": 2, "phases": 4,
                                           "checks_passed": 1, "step": "", "brief": "Needs WSL2", "sources": 5]])!
        XCTAssertEqual(HarnessJobFormat.line(job), "IT agent · stopped when the server restarted · reached phase 2/4 (Enable WSL2)")
        XCTAssertEqual(job.it?.brief, "Needs WSL2")
        XCTAssertEqual(HarnessJobFormat.line(HarnessJob(json: ["id": "k", "label": "IT agent", "status": "lost", "started_at": 1])!),
                       "IT agent · stopped when the server restarted")
    }
}
