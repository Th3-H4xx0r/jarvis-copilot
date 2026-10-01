import XCTest
@testable import JarvisCopilot

final class DashcamRulesTests: XCTestCase {
    private func file(_ kind: DashcamClipKind, _ lens: DashcamLens = .front, size: Int64 = 100,
                      start: TimeInterval = 0, name: String? = nil) -> DashcamFile {
        DashcamFile(path: "/sd/\(kind.rawValue)/\(name ?? "\(kind.rawValue)_\(lens.rawValue)_\(Int(start)).mp4")",
                    kind: kind, lens: lens, start: Date(timeIntervalSince1970: start), durationS: 60, size: size)
    }

    func testEventsParkingAndPhotosAlwaysComeEvenWithNormalOff() {
        let rules = DashcamRules()
        XCTAssertTrue(rules.wants(file(.event), parked: false, normalBytesOnPhone: .max / 2))
        XCTAssertTrue(rules.wants(file(.parking), parked: false, normalBytesOnPhone: 0))
        XCTAssertTrue(rules.wants(file(.photo), parked: false, normalBytesOnPhone: 0))
        XCTAssertFalse(rules.wants(file(.normal), parked: true, normalBytesOnPhone: 0))
    }

    func testNormalFootageFollowsLensWhenAndCap() {
        var rules = DashcamRules()
        rules.normal = .front
        XCTAssertTrue(rules.wants(file(.normal, .front), parked: false, normalBytesOnPhone: 0))
        XCTAssertFalse(rules.wants(file(.normal, .rear), parked: false, normalBytesOnPhone: 0))
        rules.normal = .all
        XCTAssertTrue(rules.wants(file(.normal, .rear), parked: false, normalBytesOnPhone: 0))
        rules.normalWhen = .parked
        XCTAssertFalse(rules.wants(file(.normal), parked: false, normalBytesOnPhone: 0))
        XCTAssertTrue(rules.wants(file(.normal), parked: true, normalBytesOnPhone: 0))
        rules.phoneCapGB = 1
        XCTAssertFalse(rules.wants(file(.normal, size: 600_000_000), parked: true, normalBytesOnPhone: 600_000_000),
                       "the cap stops normal footage")
        XCTAssertTrue(rules.wants(file(.event, size: 600_000_000), parked: true, normalBytesOnPhone: 2_000_000_000),
                      "but never events")
    }

    func testOrderPutsEventsFirstAndNewestFirst() {
        let ordered = DashcamRules.order([file(.normal, start: 5), file(.photo, start: 1), file(.event, start: 2),
                                          file(.event, start: 9), file(.parking, start: 3)])
        XCTAssertEqual(ordered.map(\.kind), [.event, .event, .parking, .photo, .normal])
        XCTAssertEqual(ordered.first?.start, Date(timeIntervalSince1970: 9))
    }

    func testRulesRoundTripThroughJSONAndClampTheCap() {
        var r = DashcamRules()
        r.normal = .all; r.normalWhen = .parked; r.phoneCapGB = 64; r.keepOnPhone = true
        XCTAssertEqual(DashcamRules(json: r.json), r)
        XCTAssertEqual(DashcamRules(json: ["phone_cap_gb": 100_000]).phoneCapGB, 512)
        XCTAssertEqual(DashcamRules(json: ["normal": "bogus"]).normal, .off)
    }

    func testEvictionOnlyRemovesOldUploadedNormalClips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DashcamStorage(root: root)
        func put(_ f: DashcamFile, age: TimeInterval) throws {
            let url = storage.localURL(camera: "cam", file: f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: Int(f.size)).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        let oldUploaded = file(.normal, size: 400, name: "old.mp4")
        let oldPending = file(.normal, size: 400, name: "pending.mp4")
        let newer = file(.normal, size: 400, name: "new.mp4")
        let event = file(.event, size: 400, name: "event.mp4")
        try put(oldUploaded, age: 300); try put(oldPending, age: 200); try put(newer, age: 10); try put(event, age: 500)
        XCTAssertEqual(storage.normalBytes(camera: "cam"), 1200)
        let removed = storage.evict(camera: "cam", needed: 400, cap: 1200,
                                    uploadedNames: ["old.mp4", "new.mp4", "event.mp4"])
        XCTAssertEqual(removed, ["old.mp4"])
        XCTAssertTrue(storage.exists(camera: "cam", file: oldPending), "never evicts what isn't uploaded")
        XCTAssertTrue(storage.exists(camera: "cam", file: event), "never evicts events")
        XCTAssertTrue(storage.exists(camera: "cam", file: newer))
    }
}
