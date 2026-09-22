import XCTest
@testable import JarvisCopilot

/// The storage panel's decode and its deletes.
///
/// Worth its own file because everything here is a CROSS-LAYER claim: the keys
/// `live_store.storage_summary` actually returns, and the body
/// `/api/live/delete` actually accepts. A wrong guess in either direction fails
/// silently — an empty list looks exactly like "nothing stored yet", and a delete
/// addressed by the wrong field looks exactly like a server error.
@MainActor
final class LiveStorageTests: XCTestCase {

    /// What `live_store.storage_summary()` really sends, field for field.
    private var serverShape: [String: Any] {
        ["total_bytes": 4096,
         "chunks": 3,
         "note": "per-speaker bytes are estimated from speech time",
         "per_session": [["live_session_id": "7f3c9a2b4d1e6f8a0b2c4d6e8f0a1b2c",
                          "bytes": 3000, "chunks": 2,
                          "title": "Live — 21 Sep, 14:02",
                          "source_label": "iPhone Microphone",
                          "started_at": 1_790_000_000.0]],
         "per_day": [["day": "2026-09-20", "bytes": 1096],
                     ["day": "2026-09-21", "bytes": 3000]],
         "per_speaker_approx": [["id": "sp-1", "name": "Pranav", "kind": "me",
                                 "speech_ms": 12000, "segment_count": 4,
                                 "approx_bytes": 2400]]]
    }

    // MARK: - Decode

    /// The server says `per_day`; the contract said `days`. Reading only the
    /// contract's spelling showed a storage total with no rows under it at all.
    func testTheServersOwnKeysDecode() {
        let storage = LiveStorage.from(serverShape)
        XCTAssertEqual(storage.totalBytes, 4096)
        XCTAssertFalse(storage.note.isEmpty)
        XCTAssertEqual(storage.days.count, 2, "per_day must be read")
        XCTAssertEqual(storage.sessions.count, 1, "per_session must be read")
        XCTAssertEqual(storage.speakers.count, 1, "per_speaker_approx must be read")
    }

    /// The contract's spelling keeps working, because the server half may yet be
    /// changed to match it.
    func testTheContractsKeysStillDecode() {
        let storage = LiveStorage.from([
            "total_bytes": 10,
            "days": [["day": "2026-09-21", "bytes": 10]],
            "sessions": [["id": "abc", "title": "T", "bytes": 10]],
            "speakers": [["id": "sp", "name": "N", "bytes": 10]]])
        XCTAssertEqual(storage.days.first?.id, "2026-09-21")
        XCTAssertEqual(storage.sessions.first?.id, "abc")
        XCTAssertEqual(storage.speakers.first?.bytes, 10)
    }

    /// **The id is what a delete is addressed by.** A day row's id has to be the
    /// `YYYY-MM-DD` the server matches on, and a session row's the hex id — never
    /// the human label, which is what the old fallback produced and which
    /// `/api/live/delete` rejects outright.
    func testRowIDsAreWhatTheDeleteEndpointExpects() {
        let storage = LiveStorage.from(serverShape)
        XCTAssertEqual(storage.days.map(\.id), ["2026-09-21", "2026-09-20"],
                       "biggest first, and identified by the calendar day")
        XCTAssertEqual(storage.sessions.first?.id, "7f3c9a2b4d1e6f8a0b2c4d6e8f0a1b2c")
        XCTAssertNotEqual(storage.sessions.first?.id, storage.sessions.first?.label,
                          "the title is not an id")
    }

    /// Per-speaker bytes are apportioned by speech time, so they arrive under
    /// `approx_bytes` and must still be flagged approximate.
    func testSpeakerBytesAreReadAndStillMarkedApproximate() {
        let speaker = LiveStorage.from(serverShape).speakers.first
        XCTAssertEqual(speaker?.bytes, 2400)
        XCTAssertEqual(speaker?.approximate, true)
    }

    /// Nothing recorded yet is not an error, and must not be a crash either.
    func testAnEmptySummaryIsEmptyNotBroken() {
        let storage = LiveStorage.from(["total_bytes": 0])
        XCTAssertEqual(storage.totalBytes, 0)
        XCTAssertTrue(storage.days.isEmpty)
        XCTAssertTrue(storage.sessions.isEmpty)
    }

    // MARK: - The day delete

    /// `{"kind":"day","id":"YYYY-MM-DD"}` — the exact body the server validates
    /// with `_DAY_RE`.
    func testDeletingADayPostsTheDayKindAndTheCalendarDay() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/live/delete", json: ["day": "2026-09-21",
                                                   "sessions_deleted": 2,
                                                   "freed_bytes": 3000])
        try await LiveAPI(api: api).delete(kind: .day, id: "2026-09-21")

        let body = transport.lastBody()
        XCTAssertEqual(body["kind"] as? String, "day")
        XCTAssertEqual(body["id"] as? String, "2026-09-21")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/live/delete")
    }

    /// The wire names are the server's, not Swift's.
    func testTheDeleteKindsSpellThemselvesTheWayTheServerReadsThem() {
        XCTAssertEqual(LiveDeleteKind.day.rawValue, "day")
        XCTAssertEqual(LiveDeleteKind.session.rawValue, "session")
        XCTAssertEqual(LiveDeleteKind.speakerForget.rawValue, "speaker_forget")
        XCTAssertEqual(LiveDeleteKind.speakerAudio.rawValue, "speaker_audio")
    }

    // MARK: - Reading a day back to the user

    /// A confirmation dialog asks the user to destroy a day, so it has to name one
    /// they recognise rather than an ISO string.
    func testADayIsShownAsSomethingAPersonReads() {
        let label = LiveStorageScreen.dayLabel("2026-09-21")
        XCTAssertNotEqual(label, "2026-09-21", "an ISO date is not a readable day")
        XCTAssertTrue(label.contains("21"), label)
    }

    /// An unparseable day is shown as it came rather than as a wrong date or a
    /// crash — the id still has to match what the server holds.
    func testAnUnreadableDayIsPassedThroughUnchanged() {
        XCTAssertEqual(LiveStorageScreen.dayLabel("(untitled)"), "(untitled)")
        XCTAssertEqual(LiveStorageScreen.dayLabel(""), "")
    }
}
