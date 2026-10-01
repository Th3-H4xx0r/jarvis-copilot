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

    func testInventoryRowNeedsIdAndPath() {
        XCTAssertNotNil(DashcamInventoryRow(json: ["id": "c", "path": "/p", "has_gps": 1, "uploaded": true]))
        XCTAssertNil(DashcamInventoryRow(json: ["id": "c"]))
    }
}
