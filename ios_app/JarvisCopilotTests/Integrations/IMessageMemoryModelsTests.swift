import Foundation
import XCTest
@testable import JarvisCopilot

/// The iMessage memory card as `GET /api/imessage-memory` sends it, and the `agent`
/// field's round trip with `AgentChoice`.
final class IMessageMemoryModelsTests: XCTestCase {

    private func decode(_ json: String) throws -> IMessageMemoryCard {
        try IMessageMemoryCard.decode(Data(json.utf8))
    }

    private let fullCard = """
    {"enabled": true, "memory_active": true,
     "agent": {"harness_id": "main"},
     "runs_on": "harness Main → @anthropic:claude-haiku-5-5",
     "mac_seen_at": 1760900000.5,
     "chats": [
       {"guid": "iMessage;-;+15550001", "name": "Mum", "is_group": false,
        "participants": [{"handle": "+15550001", "label": "Mum"}],
        "last_message_at": 1760890000, "pick": null, "effective": true, "remembered": 12},
       {"guid": "chat123", "name": "", "is_group": true,
        "participants": [{"handle": "+15550001", "label": "Mum"}, {"handle": "a@b.com", "label": ""}],
        "last_message_at": null, "pick": false, "effective": false, "remembered": 0}
     ],
     "skip": [{"handle": "+15559999", "label": "Bank"}],
     "jobs": [
       {"id": "j1", "start": 1760000000, "end": 1760500000, "chats": null, "status": "done",
        "received": 400, "stored": 9, "skipped": 3, "created_at": 1760600000, "updated_at": 1760600100,
        "error": null},
       {"id": "j2", "start": 1760000000, "end": 1760500000, "chats": ["chat123"], "status": "running",
        "received": 40, "stored": 1, "skipped": 0, "created_at": 1760700000, "updated_at": 1760700100,
        "error": null}
     ],
     "active_job": {"id": "j2", "start": 1760000000, "end": 1760500000, "chats": ["chat123"],
        "status": "running", "received": 40, "stored": 1, "skipped": 0, "created_at": 1760700000,
        "updated_at": 1760700100, "error": null},
     "totals": {"memories": 120, "bursts": 30, "pending": 2},
     "ask_facts": false, "push_facts": false, "pending_facts": 3, "mac_connected": true}
    """

    // MARK: Decoding

    func testTheWholeCardDecodes() throws {
        let card = try decode(fullCard)
        XCTAssertTrue(card.enabled)
        XCTAssertTrue(card.memoryActive)
        XCTAssertEqual(card.agent, .harness("main"))
        XCTAssertEqual(card.runsOn, "harness Main → @anthropic:claude-haiku-5-5")
        XCTAssertEqual(card.macSeenAt, 1760900000.5)
        XCTAssertEqual(card.chats.count, 2)
        XCTAssertEqual(card.chats[0].pick, nil)
        XCTAssertTrue(card.chats[0].effective)
        XCTAssertEqual(card.chats[0].remembered, 12)
        XCTAssertEqual(card.chats[1].pick, false)
        XCTAssertTrue(card.chats[1].isGroup)
        XCTAssertNil(card.chats[1].lastMessageAt)
        XCTAssertEqual(card.skip, [IMessagePerson(handle: "+15559999", label: "Bank")])
        XCTAssertEqual(card.jobs.count, 2)
        XCTAssertNil(card.jobs[0].chats)
        XCTAssertEqual(card.jobs[0].status, .done)
        XCTAssertEqual(card.activeJob?.id, "j2")
        XCTAssertEqual(card.activeJob?.chats, ["chat123"])
        XCTAssertEqual(card.totals.memories, 120)
        XCTAssertEqual(card.totals.pending, 2)
    }

    func testNullsDecodeAsAbsent() throws {
        let card = try decode("""
        {"enabled": false, "memory_active": false, "agent": null, "runs_on": "",
         "mac_seen_at": null, "chats": [], "skip": [], "jobs": [], "active_job": null,
         "totals": {"memories": 0, "bursts": 0, "pending": 0}}
        """)
        XCTAssertNil(card.agent)
        XCTAssertNil(card.macSeenAt)
        XCTAssertNil(card.activeJob)
        XCTAssertTrue(card.chats.isEmpty)
    }

    func testAModelAgentWithANullProviderDecodes() throws {
        let card = try decode(#"{"agent": {"model": "claude-haiku-5-5", "provider": null}}"#)
        XCTAssertEqual(card.agent, .model(id: "claude-haiku-5-5", provider: nil))
    }

    func testMissingFieldsFallBackRatherThanFail() throws {
        let card = try decode("{}")
        XCTAssertFalse(card.enabled)
        XCTAssertEqual(card.totals.memories, 0)
        XCTAssertTrue(card.jobs.isEmpty)
    }

    func testAnUnknownJobStatusReadsAsAnError() throws {
        let card = try decode(#"{"jobs": [{"id": "x", "status": "exploded"}]}"#)
        XCTAssertEqual(card.jobs.first?.status, .error)
    }

    // MARK: Agent round trip

    private func roundTrip(_ choice: AgentChoice?) throws -> AgentChoice? {
        let wire = IMessageMemoryAgent(choice).json
        let card = try JSONSerialization.data(withJSONObject: ["agent": wire])
        return try IMessageMemoryCard.decode(card).agent
    }

    func testAHarnessRoundTrips() throws {
        XCTAssertEqual(IMessageMemoryAgent(.harness("main")).json as? [String: String], ["harness_id": "main"])
        XCTAssertEqual(try roundTrip(.harness("main")), .harness("main"))
    }

    func testAModelRoundTrips() throws {
        let wire = IMessageMemoryAgent(.model(id: "gpt-5", provider: "openrouter")).json as? [String: Any]
        XCTAssertEqual(wire?["model"] as? String, "gpt-5")
        XCTAssertEqual(wire?["provider"] as? String, "openrouter")
        XCTAssertNil(wire?["harness_id"])
        XCTAssertEqual(try roundTrip(.model(id: "gpt-5", provider: "openrouter")),
                       .model(id: "gpt-5", provider: "openrouter"))
        XCTAssertEqual(try roundTrip(.model(id: "gpt-5", provider: nil)), .model(id: "gpt-5", provider: nil))
    }

    func testSameAsDefaultIsNull() throws {
        XCTAssertTrue(IMessageMemoryAgent(nil).json is NSNull)
        XCTAssertNil(try roundTrip(nil))
    }

    // MARK: What the screens read

    func testTheSubtitleLeadsWithWhetherItIsOn() throws {
        var card = try decode(fullCard)
        XCTAssertEqual(card.subtitle, "On · 1 chat · 120 memories")
        card.enabled = false
        XCTAssertEqual(card.subtitle, "Off")
        card.macSeenAt = nil
        XCTAssertEqual(card.subtitle, "Mac not seen yet")
    }

    func testTheFactCardFieldsDecode() throws {
        let card = try decode(fullCard)
        XCTAssertFalse(card.askFacts)
        XCTAssertFalse(card.pushFacts)
        XCTAssertEqual(card.pendingFacts, 3)
        XCTAssertTrue(card.macConnected)
        XCTAssertEqual(card.pendingFactsLine, "3 facts waiting")
    }

    func testAnOlderServerWithoutFactFieldsGetsTheDefaults() throws {
        let card = try decode(#"{"enabled": true, "mac_seen_at": 1760900000}"#)
        XCTAssertTrue(card.askFacts)
        XCTAssertTrue(card.pushFacts)
        XCTAssertEqual(card.pendingFacts, 0)
        XCTAssertFalse(card.macConnected)
        XCTAssertNil(card.pendingFactsLine)
    }

    func testAnOfflineMacIsTheWarning() throws {
        var card = try decode(fullCard)
        card.macConnected = false
        XCTAssertEqual(card.warning, IMessageMemoryCard.macOffline)
        card.macSeenAt = nil
        XCTAssertTrue(card.warning?.contains("hasn't reported") == true, "never seen says what to do instead")
    }

    func testTheWarningNamesWhatIsWrong() throws {
        var card = try decode(fullCard)
        XCTAssertNil(card.warning)
        card.macSeenAt = nil
        XCTAssertNotNil(card.warning)
        card.memoryActive = false
        XCTAssertTrue(card.warning?.contains("memory provider") == true)
    }

    func testSkippablePeopleAreUniqueAndLeaveOutTheSkipped() throws {
        var card = try decode(fullCard)
        XCTAssertEqual(card.skippablePeople.map(\.handle), ["a@b.com", "+15550001"])
        card.skip.append(IMessagePerson(handle: "+15550001", label: "Mum"))
        XCTAssertEqual(card.skippablePeople.map(\.handle), ["a@b.com"])
    }

    // MARK: Backfill progress

    private func job(_ fields: String) throws -> IMessageBackfillJob? {
        try decode(#"{"active_job": {"id": "a1", "created_at": 5, "#.appending(fields).appending("}}"))
            .activeJob
    }

    func testAnalyzingDecodesWithItsCount() throws {
        let job = try XCTUnwrap(try job(#""status": "analyzing", "received": 200, "analyzed": 50, "stored": 4, "skipped": 1"#))
        XCTAssertEqual(job.status, .analyzing)
        XCTAssertEqual(job.analyzed, 50)
        XCTAssertEqual(job.progress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(job.progressLine, "Analysing conversations — 50 of 200 messages")
        XCTAssertEqual(job.savedLine, "4 saved · 1 skipped")
        XCTAssertTrue(job.status.isLive)
        XCTAssertNotEqual(job.status.title, "Done")
    }

    func testAMissingAnalyzedCountReadsAsZero() throws {
        let job = try XCTUnwrap(try job(#""status": "running", "received": 40"#))
        XCTAssertEqual(job.analyzed, 0)
        XCTAssertEqual(job.progress, 0)
        XCTAssertEqual(job.progressLine, "Uploading from your Mac…")
    }

    func testProgressStaysInsideTheBar() throws {
        let over = try XCTUnwrap(try job(#""status": "analyzing", "received": 10, "analyzed": 15"#))
        XCTAssertEqual(over.progress, 1)
        XCTAssertEqual(over.progressLine, "Analysing conversations — 10 of 10 messages")
        let empty = try XCTUnwrap(try job(#""status": "analyzing", "received": 0, "analyzed": 0"#))
        XCTAssertEqual(empty.progress, 0, "nothing received yet is an empty bar, not a NaN")
    }

    func testAPendingJobWaitsForTheMac() throws {
        let job = try XCTUnwrap(try job(#""status": "pending""#))
        XCTAssertEqual(job.progressLine, "Waiting for your Mac…")
        XCTAssertTrue(job.status.isLive)
    }

    func testEveryActiveStateIsTheRunningCard() throws {
        for status in ["pending", "running", "analyzing"] {
            let card = try decode(#"{"jobs": [{"id": "a1", "status": "\#(status)"}], "#
                                  + #""active_job": {"id": "a1", "status": "\#(status)"}}"#)
            XCTAssertEqual(card.liveJob?.id, "a1", status)
            XCTAssertTrue(card.recentJobs.isEmpty, "\(status) is running, not finished")
        }
    }

    func testAnActiveJobInAnUnknownStateReadsAsFinished() throws {
        let card = try decode(#"{"jobs": [], "active_job": {"id": "a1", "status": "exploded", "created_at": 9}}"#)
        XCTAssertNil(card.liveJob, "no stuck running card")
        XCTAssertEqual(card.recentJobs.map(\.id), ["a1"])
        XCTAssertEqual(card.recentJobs.first?.status, .error)
    }

    @MainActor
    func testTheScreenKeepsPollingWhileJarvisIsStillReading() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/imessage-memory", json: ["active_job": [
            "id": "a1", "status": "analyzing", "received": 10, "analyzed": 3,
        ]])
        let store = IMessageMemoryStore(api: IMessageMemoryAPI(api: client), sleeper: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        store.appeared()
        await store.refresh()
        XCTAssertEqual(store.card?.liveJob?.status, .analyzing)
        XCTAssertTrue(store.isPolling)
        store.disappeared()
        XCTAssertFalse(store.isPolling)
    }

    @MainActor
    func testAFinishedJobStopsThePoll() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/imessage-memory", json: ["active_job": ["id": "a1", "status": "done"]])
        let store = IMessageMemoryStore(api: IMessageMemoryAPI(api: client), sleeper: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        store.appeared()
        await store.refresh()
        XCTAssertNil(store.card?.liveJob)
        XCTAssertFalse(store.isPolling)
    }

    func testRecentJobsLeaveOutTheActiveOne() throws {
        let card = try decode(fullCard)
        XCTAssertEqual(card.recentJobs.map(\.id), ["j1"])
    }

    func testAnUnnamedChatIsCalledByItsPeople() throws {
        let card = try decode(fullCard)
        XCTAssertEqual(card.chats[1].displayName, "Mum, a@b.com")
        XCTAssertTrue(card.chats[1].matches("a@b"))
        XCTAssertFalse(card.chats[1].matches("dad"))
    }

    func testPresetsEndNowAndGoBack() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let week = IMessageBackfillPreset.week.range(endingAt: now)
        XCTAssertEqual(week.to, now)
        XCTAssertEqual(week.to.timeIntervalSince(week.from), 7 * 86_400, accuracy: 3_600)
        let three = IMessageBackfillPreset.threeMonths.range(endingAt: now)
        XCTAssertLessThan(three.from, IMessageBackfillPreset.month.range(endingAt: now).from)
    }
}
