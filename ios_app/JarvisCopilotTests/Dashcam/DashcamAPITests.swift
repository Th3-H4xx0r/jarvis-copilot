import XCTest
@testable import JarvisCopilot

/// Server replies → Swift models, tolerant of missing and string-typed fields.
final class DashcamAPITests: XCTestCase {
    func testClipDecodesStatusAndDestinations() throws {
        let json: [String: Any] = [
            "id": "c_1", "camera_id": "FAKE", "path": "/mnt/card/emr/a.mp4", "kind": "event", "lens": "rear",
            "start": "2026-10-01T20:40:00Z", "duration_s": 20, "size": "2048", "on_camera": false,
            "has_gps": true, "has_thumb": true,
            "phone": ["state": "local"], "upload": ["state": "staged"],
            "destinations": ["d_1": ["state": "done", "remote_path": "Dashcam/a.mp4"],
                             "d_2": ["state": "failed", "error": "permission denied"]],
            "drive_id": "dr_1",
        ]
        let c = try XCTUnwrap(DashcamServerClip(json: json))
        XCTAssertEqual(c.kind, .event)
        XCTAssertEqual(c.lens, .rear)
        XCTAssertEqual(c.size, 2048)
        XCTAssertEqual(c.start, Date(timeIntervalSince1970: 1_790_887_200))
        XCTAssertFalse(c.onCamera)
        XCTAssertTrue(c.failed)
        XCTAssertFalse(c.uploaded)
        XCTAssertEqual(c.destinations["d_2"]?.error, "permission denied")
        XCTAssertEqual(c.name, "a.mp4")
        XCTAssertNil(DashcamServerClip(json: ["path": "/x"]), "no id → dropped")
    }

    func testDriveAndDestinationDecode() throws {
        let d = try XCTUnwrap(DashcamDrive(json: ["id": "dr_1", "start": "2026-10-01T20:40:00Z", "end": "2026-10-01T21:10:00Z",
                                                  "distance_m": 24000, "avg_mps": 13.3, "max_mps": 29,
                                                  "bounds": [41.8, -87.7, 41.9, -87.6], "clip_ids": ["c_1", "c_2"]]))
        XCTAssertEqual(d.durationS, 1800)
        XCTAssertEqual(d.clipIDs.count, 2)
        let dest = try XCTUnwrap(DashcamDestination(json: ["id": "d_1", "type": "sftp", "name": "NAS", "path": "/dash"]))
        XCTAssertTrue(dest.enabled)
        XCTAssertEqual(dest.kinds.count, DashcamClipKind.allCases.count, "no kinds → every kind")
    }

    func testFixRowsRoundTrip() throws {
        let f = DashcamFix(t: 1.5, lat: 41, lon: -87, speed: nil, heading: 90)
        let back = try XCTUnwrap(DashcamFix(row: f.row))
        XCTAssertEqual(back, f)
        XCTAssertNil(DashcamFix(row: ["x"]))
    }

    func testUploadStartReplies() throws {
        XCTAssertEqual(try DashcamAPI.uploadStart(["ok": true, "upload_id": NSNull(), "complete": true, "already_uploaded": true]), .alreadyThere)
        guard case .ticket(let t) = try DashcamAPI.uploadStart(["upload_id": "u1", "chunk_size": 4, "received": [0, 2], "complete": false]) else {
            return XCTFail("expected a ticket")
        }
        XCTAssertEqual(t.received, [0, 2])
        XCTAssertFalse(t.complete)
        XCTAssertThrowsError(try DashcamAPI.uploadStart(["ok": true]))
    }

    func testServerClipReadsCardDelete() throws {
        let pending = try XCTUnwrap(DashcamServerClip(json: ["id": "c", "path": "/p",
                                                            "card_delete": ["forget": true, "attempts": 2, "last_error": "x"]]))
        XCTAssertTrue(pending.deletePending)
        XCTAssertEqual(pending.cardDelete, DashcamCardDelete(id: "c", path: "/p", forget: true, attempts: 2, lastError: "x"))
        let plain = try XCTUnwrap(DashcamServerClip(json: ["id": "c", "path": "/p"]))
        XCTAssertFalse(plain.deletePending)
        XCTAssertEqual(DashcamInventoryRow(json: ["id": "c", "path": "/p", "card_delete": true])?.cardDelete, true)
    }

    func testServerUploadedFlagWins() throws {
        let c = try XCTUnwrap(DashcamServerClip(json: ["id": "c", "path": "/p", "uploaded": true, "destinations": [:]]))
        XCTAssertTrue(c.uploaded)
    }

    func testInventoryRowNeedsIdAndPath() {
        XCTAssertNotNil(DashcamInventoryRow(json: ["id": "c", "path": "/p", "has_gps": 1, "uploaded": true]))
        XCTAssertNil(DashcamInventoryRow(json: ["id": "c"]))
    }
}

/// "Google Drive is signed out": every Drive token answer sets or clears the one state the dashcam screens read.
@MainActor
final class DashcamDriveSignInTests: XCTestCase {
    func testA409SetsTheSignedOutStateAndATokenClearsIt() async throws {
        let state = DashcamDriveSignIn()
        state.lookupName = { _ in nil }
        let (api, transport) = JarvisAPI.mocked()
        var dashcam = DashcamAPI(api: api)
        dashcam.tokenAnswered = { id, expired in await state.tokenAnswered(id, expired: expired) }
        transport.enqueue(json: ["ok": false, "reason": "signin_expired"], status: 409)
        do {
            _ = try await dashcam.driveAccess(destinationID: "d_drive")
            XCTFail("a dead sign-in handed out a token")
        } catch {
            XCTAssertEqual(error as? DashcamDriveError, .signInExpired("d_drive"))
        }
        XCTAssertEqual(state.needed?.destinationID, "d_drive")
        transport.enqueue(json: ["ok": true, "access_token": "t", "expires_at": Date().timeIntervalSince1970 + 3600, "path": "Dashcam"])
        let key = try await dashcam.driveAccess(destinationID: "d_drive")
        XCTAssertEqual(key.token, "t")
        XCTAssertNil(state.needed, "signed in again: the popup's state clears")
    }

    /// A destinations list that no longer calls it signed out (signed in elsewhere) or no longer has it (removed)
    /// ends the state; one that still does keeps it and fills in the name.
    func testADestinationsListEndsAStaleSignedOutState() throws {
        let state = DashcamDriveSignIn()
        state.lookupName = { _ in nil }
        state.tokenAnswered("d1", expired: true)
        let expired = try XCTUnwrap(DashcamDestination(json: ["id": "d1", "type": "drive", "name": "Camry", "signin_expired": true]))
        state.destinationsListed([expired])
        XCTAssertEqual(state.needed?.name, "Camry")
        let fixed = try XCTUnwrap(DashcamDestination(json: ["id": "d1", "type": "drive", "name": "Camry"]))
        state.destinationsListed([fixed])
        XCTAssertNil(state.needed)
        state.tokenAnswered("d1", expired: true)
        state.destinationsListed([])
        XCTAssertNil(state.needed, "removed")
    }

    /// The card-delete answer carries the server's refusals of locked clips.
    func testCardDeleteMarksCarryTheLockedRefusals() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true, "marked": ["a"], "missing": ["m"], "locked": ["l"]])
        let marks = try await DashcamAPI(api: api).markCardDeletes([(id: "a", forget: false), (id: "m", forget: false),
                                                                     (id: "l", forget: true), (id: "x", forget: false)])
        XCTAssertEqual(marks.locked, ["l"])
        XCTAssertTrue(marks.allows("a"))
        XCTAssertTrue(marks.allows("m"), "no record on the server: nothing can lock it")
        XCTAssertFalse(marks.allows("l"))
        XCTAssertFalse(marks.allows("x"), "not queued: not deleted")
        XCTAssertTrue(DashcamCardMarks(marked: nil, locked: ["l"]).allows("x"), "an older server that doesn't say")
    }

    func testOneDestinationAtATimeAndOnlyItsOwnTokenClearsIt() async {
        let state = DashcamDriveSignIn()
        state.lookupName = { id in id == "a" ? "Dashcam Camry" : nil }
        state.tokenAnswered("a", expired: true)
        state.tokenAnswered("b", expired: true)
        XCTAssertEqual(state.needed?.destinationID, "a")
        state.tokenAnswered("b", expired: false)
        XCTAssertEqual(state.needed?.destinationID, "a", "another destination's token says nothing about this one")
        for _ in 0..<20 where state.needed?.name == nil { await Task.yield() }
        XCTAssertEqual(state.needed?.name, "Dashcam Camry")
        XCTAssertTrue(DashcamDriveSignIn.message(state.needed).contains("“Dashcam Camry”"))
        state.tokenAnswered("a", expired: false)
        XCTAssertNil(state.needed)
    }
}
