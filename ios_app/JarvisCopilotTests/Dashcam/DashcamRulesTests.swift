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

    func testUploadRulesGateByDataAndParking() {
        var r = DashcamRules()
        XCTAssertTrue(r.mayUpload(.normal, metered: true, parked: false), "default: everything, any time, LTE too")
        r.uploadData = .events
        XCTAssertFalse(r.mayUpload(.normal, metered: true, parked: true))
        XCTAssertTrue(r.mayUpload(.event, metered: true, parked: true))
        XCTAssertTrue(r.mayUpload(.normal, metered: false, parked: true), "Wi‑Fi is never limited")
        XCTAssertTrue(r.mayUpload(.normal, metered: true, parked: true, charging: true), "on power, normal footage goes too")
        r.uploadData = .never
        XCTAssertFalse(r.mayUpload(.photo, metered: true, parked: true))
        r.uploadData = .all
        r.uploadWhen = .parked
        XCTAssertFalse(r.mayUpload(.event, metered: false, parked: false))
        XCTAssertTrue(r.mayUpload(.event, metered: false, parked: true))
        r.upload = false
        XCTAssertFalse(r.mayUpload(.event, metered: false, parked: true))
        let back = DashcamRules(json: r.json)
        XCTAssertEqual(back, r)
    }

    /// "Charging only": normal footage and uploads wait for the charger; events still come off
    /// the camera at once.
    func testOnlyWhileChargingWaitsForPower() {
        var r = DashcamRules()
        r.normal = .all
        r.normalWhen = .charging
        XCTAssertFalse(r.wants(file(.normal), parked: true, charging: false, normalBytesOnPhone: 0))
        XCTAssertTrue(r.wants(file(.normal), parked: false, charging: true, normalBytesOnPhone: 0))
        XCTAssertTrue(r.wants(file(.event), parked: false, charging: false, normalBytesOnPhone: 0))
        r.uploadWhen = .charging
        XCTAssertFalse(r.mayUpload(.event, metered: false, parked: true, charging: false))
        XCTAssertTrue(r.mayUpload(.event, metered: false, parked: false, charging: true))
        XCTAssertEqual(DashcamRules(json: r.json), r)
    }

    /// The settings show a value on one line next to its title: a long one ran into the row below.
    func testEveryRuleValueFitsOnOneLine() {
        let labels = DashcamRules.Normal.allCases.map(\.label) + DashcamRules.When.allCases.map(\.label)
            + DashcamRules.UploadData.allCases.map(\.label)
        for label in labels { XCTAssertLessThanOrEqual(label.count, 14, label) }
    }

    func testRulesRoundTripThroughJSONAndClampTheCap() {
        var r = DashcamRules()
        r.normal = .all; r.normalWhen = .parked; r.phoneCapGB = 64; r.keepOnPhone = true
        XCTAssertEqual(DashcamRules(json: r.json), r)
        XCTAssertEqual(DashcamRules(json: ["phone_cap_gb": 100_000]).phoneCapGB, 512)
        XCTAssertEqual(DashcamRules(json: ["normal": "bogus"]).normal, .off)
    }

    func testAListingRoundedUpToWholeKBStillCountsAsDownloaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DashcamStorage(root: root)
        let listed = file(.event, size: 3 * 1024, name: "e.mp4")          // camera says 3 KB
        let url = storage.localURL(camera: "cam", file: listed)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 2 * 1024 + 300).write(to: url)                    // real file is 2.3 KB
        XCTAssertTrue(storage.exists(camera: "cam", file: listed))
        XCTAssertEqual(storage.localSize(camera: "cam", file: listed), 2 * 1024 + 300)
        try Data(count: 100).write(to: url)
        XCTAssertFalse(storage.exists(camera: "cam", file: listed), "far short of the listing")
    }

    func testRearClipsFiledUnderFrontByOlderBuildsAreStillFound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DashcamStorage(root: root)
        let rear = DashcamFile(path: "/mnt/card/video_back/2026-10-02_13_42_36_b.ts", kind: .normal, lens: .rear,
                               start: Date(), durationS: 60, size: 2048)
        let fresh = storage.localURL(camera: "cam", file: rear)
        XCTAssertTrue(fresh.path.contains("/normal/rear/video_back/"))
        // An older build put it under front/.
        let legacy = root.appendingPathComponent("cam/normal/front/video_back/2026-10-02_13_42_36_b.ts")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 2048).write(to: legacy)
        XCTAssertEqual(storage.localURL(camera: "cam", file: rear).standardizedFileURL, legacy.standardizedFileURL)
        XCTAssertTrue(storage.exists(camera: "cam", file: rear))
    }

    /// A locked clip brought back from the cloud is its MP4: found where the camera's `.ts` would be, complete though
    /// smaller, and — like every locked copy — left out of the phone-space count and never evicted.
    func testARestoredLockedCopyIsThePhoneCopyAndNeverCountsAgainstTheCap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DashcamStorage(root: root)
        let ts = file(.normal, size: 5_000, name: "2026-10-21_16_17_37_f.ts")
        XCTAssertFalse(storage.exists(camera: "cam", file: ts))
        let restored = storage.restoredURL(camera: "cam", file: ts, ext: "mp4")
        XCTAssertEqual(restored.lastPathComponent, "2026-10-21_16_17_37_f.mp4")
        XCTAssertEqual(storage.restoredURL(camera: "cam", file: ts, ext: "ts"), storage.localURL(camera: "cam", file: ts))
        try FileManager.default.createDirectory(at: restored.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 3_000).write(to: restored)
        XCTAssertEqual(storage.localURL(camera: "cam", file: ts).standardizedFileURL, restored.standardizedFileURL)
        XCTAssertTrue(storage.exists(camera: "cam", file: ts))
        let key = DashcamStorage.key(restored)
        XCTAssertEqual(storage.normalBytes(camera: "cam"), 3_000)
        XCTAssertEqual(storage.normalBytes(camera: "cam", excluding: [key]), 0)
        XCTAssertEqual(storage.evict(camera: "cam", needed: 10_000, cap: 1, uploadedNames: [restored.lastPathComponent],
                                     locked: [key]), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
    }

    /// The camera's original and a copy brought back from the cloud never both stay; and a download is sniffed for
    /// what it is.
    func testTheCamerasOriginalWinsOverARestoredCopyAndDownloadsAreSniffed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DashcamStorage(root: root)
        let ts = file(.event, size: 2_000, name: "clip_f.ts")
        let restored = storage.restoredURL(camera: "cam", file: ts, ext: "mp4")
        try FileManager.default.createDirectory(at: restored.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 100).write(to: restored)
        storage.dropRestoredCopy(camera: "cam", file: ts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path), "no original yet: the restored copy stays")
        try Data(count: 2_000).write(to: storage.cameraURL(camera: "cam", file: ts))
        storage.dropRestoredCopy(camera: "cam", file: ts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.path))
        XCTAssertEqual(storage.localURL(camera: "cam", file: ts).lastPathComponent, "clip_f.ts")
        var tsBytes = Data(count: 400); tsBytes[0] = 0x47; tsBytes[188] = 0x47
        var mp4Bytes = Data(count: 64); mp4Bytes.replaceSubrange(4..<8, with: Array("ftyp".utf8))
        for (bytes, ext) in [(tsBytes, "ts"), (mp4Bytes, "mp4"), (Data([0xFF, 0xD8, 0xFF, 0xE0]), "jpg")] {
            let url = root.appendingPathComponent("download.bin")
            try bytes.write(to: url)
            XCTAssertEqual(DashcamStorage.sniffedExtension(url), ext)
        }
        try Data(count: 10).write(to: root.appendingPathComponent("download.bin"))
        XCTAssertNil(DashcamStorage.sniffedExtension(root.appendingPathComponent("download.bin")))
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
