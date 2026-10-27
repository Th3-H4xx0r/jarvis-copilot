import XCTest
@testable import JarvisCopilot

final class DashcamUIModelTests: XCTestCase {
    func testSpeedUnitsAndCompass() {
        XCTAssertEqual(DashcamSpeed.text(26.8224), "60")
        XCTAssertEqual(DashcamSpeed.text(nil), "–")
        XCTAssertEqual(DashcamSpeed.compass(0), "N")
        XCTAssertEqual(DashcamSpeed.compass(44), "NE")
        XCTAssertEqual(DashcamSpeed.compass(359), "N")
        XCTAssertEqual(DashcamSpeed.compass(-90), "W")
        XCTAssertNil(DashcamSpeed.compass(nil))
        XCTAssertEqual(DashcamSpeed.miles(1609.344), "1.0 mi")
        XCTAssertEqual(DashcamSpeed.duration(3720), "1 h 2 min")
    }

    func testSpeedColoursRunFromCoolToHot() {
        func red(_ c: UIColor) -> CGFloat { var r: CGFloat = 0; c.getRed(&r, green: nil, blue: nil, alpha: nil); return r }
        XCTAssertLessThan(red(DashcamSpeed.color(1)), red(DashcamSpeed.color(40)), "faster is redder")
        XCTAssertEqual(DashcamSpeed.color(40), DashcamSpeed.color(400), "clamped at the top of the scale")
    }

    func testFixInterpolation() throws {
        let fixes = [DashcamFix(t: 10, lat: 40, lon: -80, speed: 10, heading: 90),
                     DashcamFix(t: 12, lat: 42, lon: -82, speed: 20, heading: 180)]
        let mid = try XCTUnwrap(DashcamTrack.fix(at: 11, in: fixes))
        XCTAssertEqual(mid.lat, 41, accuracy: 1e-9)
        XCTAssertEqual(mid.lon, -81, accuracy: 1e-9)
        XCTAssertEqual(mid.speed ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(DashcamTrack.fix(at: 11.9, in: fixes)?.heading, 180)
        XCTAssertEqual(DashcamTrack.fix(at: 9, in: fixes)?.t, 10, "clamped just before the first fix")
        XCTAssertNil(DashcamTrack.fix(at: 100, in: fixes))
        XCTAssertNil(DashcamTrack.fix(at: 0, in: []))
    }

    func testPendingDeletionStatusWins() throws {
        let clip = try XCTUnwrap(DashcamServerClip(json: ["id": "c", "path": "/p", "uploaded": true, "phone": ["state": "failed"],
                                                         "card_delete": ["forget": false]]))
        XCTAssertEqual(DashcamClipStatus.of(clip).label, "Pending deletion")
        XCTAssertTrue(DashcamClipStatus.pendingLine(DashcamCardDelete(id: "c", path: "/p", forget: true, attempts: 2, lastError: "busy"))
            .contains("refused it (busy)"))
    }

    func testOnlyOnPhone() throws {
        func clip(_ extra: [String: Any]) throws -> DashcamServerClip {
            try XCTUnwrap(DashcamServerClip(json: ["id": "c", "path": "/p", "phone": ["state": "local"]].merging(extra) { $1 }))
        }
        XCTAssertTrue(DashcamClipPlaces.onlyOnPhone(try clip(["on_camera": false])))
        XCTAssertFalse(DashcamClipPlaces.onlyOnPhone(try clip(["on_camera": true])), "still on the card")
        XCTAssertFalse(DashcamClipPlaces.onlyOnPhone(try clip(["on_camera": false, "uploaded": true])), "in the cloud")
        XCTAssertFalse(DashcamClipPlaces.onlyOnPhone(try clip(["on_camera": false, "phone": ["state": "deleted"]])), "not on the phone")
    }

    func testStatusChipPrefersFailureThenUploaded() throws {
        var json: [String: Any] = ["id": "c", "path": "/p", "on_camera": true,
                                   "destinations": ["d": ["state": "failed", "error": "auth"]]]
        XCTAssertEqual(DashcamClipStatus.of(try XCTUnwrap(DashcamServerClip(json: json))).label, "Failed: auth")
        json["destinations"] = ["d": ["state": "done"]]
        XCTAssertEqual(DashcamClipStatus.of(try XCTUnwrap(DashcamServerClip(json: json))).label, "In the cloud")
        json["destinations"] = [:]
        json["phone"] = ["state": "local"]
        XCTAssertEqual(DashcamClipStatus.of(try XCTUnwrap(DashcamServerClip(json: json))).label, "On phone")
        json["phone"] = ["state": "none"]
        XCTAssertEqual(DashcamClipStatus.of(try XCTUnwrap(DashcamServerClip(json: json))).label, "On the SD card")
    }

    @MainActor
    func testLibraryGroupsByLocalDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = Date(timeIntervalSince1970: 1_790_900_000)   // 2026-10-01 ~ 18:13 CDT
        func clip(_ id: String, _ t: TimeInterval) throws -> DashcamServerClip {
            try XCTUnwrap(DashcamServerClip(json: ["id": id, "path": "/\(id)", "start": Date(timeIntervalSince1970: t).dashcamISO]))
        }
        let sections = DashcamLibraryModel.sections([try clip("a", 1_790_890_000), try clip("b", 1_790_899_000),
                                                     try clip("c", 1_790_800_000)], calendar: cal, now: now)
        XCTAssertEqual(sections.map(\.title).first, "Today")
        XCTAssertEqual(sections.first?.clips.map(\.id), ["b", "a"])
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.last?.title, "Yesterday")
    }

    private func page(_ ids: Range<Int>, next: String?) -> [String: Any] {
        ["clips": ids.map { ["id": "c_\($0)", "path": "/sd/\($0).ts", "start": Date(timeIntervalSince1970: 1_790_900_000 - Double($0) * 60).dashcamISO] },
         "next": next as Any]
    }

    /// His list stopped at a spinner for good: a page that failed (or was skipped) was never asked for again.
    @MainActor
    func testAFailedPageOffersARetryAndTheRetryLoadsIt() async {
        let (api, transport) = JarvisAPI.mocked()
        let model = DashcamLibraryModel()
        model.api = DashcamAPI(api: api)
        transport.enqueue(json: page(0..<60, next: "c_59"))
        await model.reload()
        XCTAssertEqual(model.clips.count, 60)
        transport.enqueue(MockTransport.Reply(status: 502, body: Data("<html>Bad gateway</html>".utf8)))
        await model.reachedEnd()
        XCTAssertNotNil(model.moreError, "the end shows a retry, not a spinner")
        XCTAssertNil(model.error, "the list itself stays")
        XCTAssertEqual(model.clips.count, 60)
        await model.reachedEnd()
        XCTAssertEqual(transport.requests.count, 2, "no silent retry loop")
        transport.enqueue(json: page(60..<100, next: nil))
        await model.loadMore()
        XCTAssertNil(model.moreError)
        XCTAssertEqual(model.clips.count, 100)
        XCTAssertNil(model.next)
        XCTAssertTrue(transport.requests.last?.url?.query?.contains("cursor=c_59") == true)
    }

    /// The 10 s refresh used to reset the list to page 1 under the reader.
    @MainActor
    func testRefreshKeepsLoadedPagesAndUpdatesRows() async {
        let (api, transport) = JarvisAPI.mocked()
        let model = DashcamLibraryModel()
        model.api = DashcamAPI(api: api)
        transport.enqueue(json: page(0..<60, next: "c_59"))
        await model.reload()
        transport.enqueue(json: page(60..<120, next: "c_119"))
        await model.reachedEnd()
        XCTAssertEqual(model.clips.count, 120)
        var fresh = page(0..<60, next: "c_59")
        var rows = fresh["clips"] as! [[String: Any]]
        rows.insert(["id": "c_new", "path": "/sd/new.ts", "start": Date(timeIntervalSince1970: 1_790_900_600).dashcamISO], at: 0)
        rows[1]["has_thumb"] = true
        fresh["clips"] = rows
        transport.enqueue(json: fresh)
        await model.refresh()
        XCTAssertEqual(model.clips.count, 121, "pages stay, the new clip joins")
        XCTAssertEqual(model.clips.first?.id, "c_new")
        XCTAssertEqual(model.clips.first { $0.id == "c_0" }?.hasThumb, true)
        XCTAssertEqual(model.next, "c_119", "paging carries on from where it was")
        XCTAssertEqual(model.sections.flatMap(\.clips).count, 121)
    }
}

final class DashcamKnownNetworksTests: XCTestCase {
    func testPrefixDropsTheUnitIdOnly() {
        XCTAssertEqual(DashcamKnownNetworks.prefix(of: "Affver_A4_9F2C"), "Affver_A4_")
        XCTAssertEqual(DashcamKnownNetworks.prefix(of: "PEZTIO-1A2B3C"), "PEZTIO-")
        XCTAssertNil(DashcamKnownNetworks.prefix(of: "MyDashcam"), "no separator")
        XCTAssertNil(DashcamKnownNetworks.prefix(of: "Home_Network"), "tail isn't an id")
    }

    func testLearningKeepsNewestFirstAndAddsThePrefixOnce() {
        let d = UserDefaults(suiteName: "known-\(UUID().uuidString)")!
        DashcamKnownNetworks.learn(ssid: "Affver_A4_0001", defaults: d)
        DashcamKnownNetworks.learn(ssid: "Affver_A4_0002", defaults: d)
        DashcamKnownNetworks.learn(ssid: "Affver_A4_0001", defaults: d)
        XCTAssertEqual(DashcamKnownNetworks.ssids(d), ["Affver_A4_0001", "Affver_A4_0002"])
        XCTAssertEqual(DashcamKnownNetworks.prefixes(d), ["Affver_A4_"])
    }

    @available(iOS 18.0, *)
    @MainActor
    func testPickerListsKnownNetworksFirstThenPrefixes() {
        let d = UserDefaults(suiteName: "known-\(UUID().uuidString)")!
        DashcamKnownNetworks.learn(ssid: "Affver_A4_0001", defaults: d)
        let items = DashcamAccessoryPicker.items(defaults: d)
        XCTAssertEqual(items.first?.descriptor.ssid, "Affver_A4_0001")
        XCTAssertEqual(items[1].descriptor.ssidPrefix, "Affver_A4_")
        XCTAssertEqual(items.count, 1 + 1 + DashcamKnownNetworks.commonPrefixes.count)
    }

    func testProbeAllFindsTheCameraWithEveryFamilyAskedAtOnce() async {
        DashcamStubProtocol.reset()
        DashcamStubProtocol.on("/app/getdeviceattr") { _ in DashcamSamples.json(["result": 0, "info": ["uuid": "X"]]) }
        let started = Date()
        let hit = await DashcamDetect.probeAll(host: "127.0.0.1:8099", timeout: 1, session: DashcamStubProtocol.session())
        XCTAssertEqual(hit?.family, .viidure)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
