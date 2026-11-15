import AppKit
import SwiftUI
import XCTest
@testable import Jarvis

/// Holo Drop on the Mac: the wire format (exactly the plan's API contract), where a drop lands
/// on screen, what arriving does, what "grab what's in front" picks, the Orbit's geometry, the
/// beacon codes and the LAN receiver's HTTP.
final class HoloDropTests: XCTestCase {

    // MARK: contract encoding

    func testLinkDropBodyCarriesEveryContractField() {
        let body = HoloWire.inlineDrop(kind: .link, target: "iphone-1", url: "https://apple.com/vision-pro",
                                       action: .saveOpen, position: HoloPosition(x: 0.8, y: 0.2),
                                       title: "Apple Vision Pro", direct: true)
        XCTAssertEqual(body["kind"] as? String, "link")
        XCTAssertEqual(body["target"] as? String, "iphone-1")
        XCTAssertEqual(body["url"] as? String, "https://apple.com/vision-pro")
        XCTAssertEqual(body["action"] as? String, "save_open")
        XCTAssertEqual(body["title"] as? String, "Apple Vision Pro")
        XCTAssertEqual(body["delivered_direct"] as? Bool, true)
        XCTAssertEqual(HJ.d(HJ.obj(body["position"])["x"]), 0.8)
        XCTAssertEqual(HJ.d(HJ.obj(body["position"])["y"]), 0.2)
        XCTAssertNil(body["text"])
        // A plain text drop leaves the optional fields out.
        let text = HoloWire.inlineDrop(kind: .text, target: "mac-2", text: "hi", action: nil)
        XCTAssertEqual(Set(text.keys), ["kind", "target", "text"])
    }

    func testUploadPathEncodesTheQuery() {
        let path = HoloWire.uploadPath(kind: .image, target: "iphone 1", name: "IMG 1+2&3.HEIC", mime: "image/heic",
                                       action: .copy, position: HoloPosition(x: 0.25, y: 1.4))
        XCTAssertTrue(path.hasPrefix("/api/holo-drop/drops/upload?"))
        let items = URLComponents(string: "http://x" + path)!.queryItems!
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["kind"], "image")
        XCTAssertEqual(q["target"], "iphone 1")
        XCTAssertEqual(q["name"], "IMG 1+2&3.HEIC")
        XCTAssertEqual(q["mime"], "image/heic")
        XCTAssertEqual(q["action"], "copy")
        XCTAssertEqual(q["x"], "0.25")
        XCTAssertEqual(q["y"], "1", "positions are clamped to 0–1")
        XCTAssertFalse(path.contains("+"), "a literal + would read as a space on the server")
        // No action or position: those keys are absent.
        let bare = HoloWire.uploadPath(kind: .file, target: "m", name: "a.bin", mime: "application/octet-stream",
                                       action: nil)
        XCTAssertFalse(bare.contains("action=") || bare.contains("x=") || bare.contains("y="))
    }

    func testADirectDropsRecordCarriesTheReceiversOutcome() {
        let record = HoloWire.inlineDrop(kind: .image, target: "iphone-1", action: .save, direct: true,
                                         name: "IMG.HEIC", mime: "image/heic", outcome: .saved)
        XCTAssertEqual(record["kind"] as? String, "image")
        XCTAssertEqual(record["name"] as? String, "IMG.HEIC")
        XCTAssertEqual(record["mime"] as? String, "image/heic")
        XCTAssertEqual(record["delivered_direct"] as? Bool, true)
        XCTAssertEqual(record["outcome"] as? String, "saved")
        XCTAssertNil(HoloWire.inlineDrop(kind: .text, target: "x", text: "t", action: nil, outcome: .copied)["outcome"],
                     "only a direct drop's record says how it landed")
    }

    func testBluetoothNameIsTheFNVOfThePairedID() {
        XCTAssertEqual(HoloBLEAdvertiser.fnv1a(""), 0x811C_9DC5)          // FNV-1a's published vectors
        XCTAssertEqual(HoloBLEAdvertiser.fnv1a("a"), 0xE40C_292C)
        XCTAssertEqual(HoloBLEAdvertiser.fnv1a("foobar"), 0xBF9C_F968)
        XCTAssertEqual(HoloBLEAdvertiser.localName(deviceID: "a"), "HDe40c292c")
        XCTAssertEqual(HoloBLEAdvertiser.localName(deviceID: "").count, 10)
        XCTAssertEqual(HoloBLEAdvertiser.service.uuidString, "6F1D5A3E-9C2B-4E7A-8D11-3B6A2C9E0F42")
    }

    func testLandedLanAndScreenBodies() {
        XCTAssertEqual(HoloWire.landed(.savedOpened)["outcome"] as? String, "saved_opened")
        XCTAssertNil(HoloWire.landed(.saved)["error"])
        XCTAssertEqual(HoloWire.landed(.failed, error: "disk full")["error"] as? String, "disk full")
        let lan = HoloWire.lanAdvert(url: "http://192.168.1.20:50111", token: "abc",
                                     expires: Date(timeIntervalSince1970: 1_800_000_000.4))
        XCTAssertEqual(lan["url"] as? String, "http://192.168.1.20:50111")
        XCTAssertEqual(lan["token"] as? String, "abc")
        XCTAssertEqual(HJ.d(lan["expires"]), 1_800_000_000)
        let report = HoloWire.screenReport(width: 1512, height: 982, scale: 2, windows: [
            HoloWindowOutline(x: 0.1, y: 0.2, w: 0.5, h: 0.4, app: "Safari")])
        XCTAssertEqual(HJ.d(report["width"]), 1512)
        XCTAssertEqual(HJ.d(report["scale"]), 2)
        let w = HJ.arr(report["windows"])
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(Set(w[0].keys), ["x", "y", "w", "h", "app"])
        XCTAssertEqual(w[0]["app"] as? String, "Safari")
    }

    func testMetaHeaderRoundTrips() {
        let fields = HoloWire.directFields(kind: .file, name: "Report.pdf", mime: "application/pdf", action: .save,
                                           position: HoloPosition(x: 0.5, y: 0.5), from: "iphone-1")
        let header = HoloWire.meta(fields)
        XCTAssertFalse(header.contains("{"), "base64, never raw JSON in a header")
        let back = HoloWire.decodeMeta(header)!
        XCTAssertEqual(back["kind"] as? String, "file")
        XCTAssertEqual(back["name"] as? String, "Report.pdf")
        XCTAssertEqual(back["action"] as? String, "save")
        XCTAssertEqual(back["from"] as? String, "iphone-1")
        XCTAssertNil(HoloWire.decodeMeta("not base64!"))
        XCTAssertNil(HoloWire.decodeMeta(nil))
    }

    func testDevicesParse() {
        let reply: [String: Any] = ["devices": [
            ["id": "iphone-1", "name": "Pranav's iPhone", "kind": "iphone", "online": true,
             "accepts": ["link", "text", "image", "video", "file"], "aim": false, "default_action": "save_copy",
             "lan": ["url": "http://10.0.0.5:6000", "token": "t", "expires": 4_000_000_000],
             "bearing": ["deg": 30, "confidence": 0.9, "source": "uwb", "at": 1], "distance_m": 1.5],
            ["id": "glasses", "name": "Glasses", "kind": "glasses", "online": false, "accepts": ["link", "text"],
             "default_action": "bogus", "lan": NSNull(), "bearing": NSNull(), "distance_m": NSNull()],
            ["name": "no id"],
        ]]
        let devices = HoloDevice.list(reply)
        XCTAssertEqual(devices.map(\.id), ["iphone-1", "glasses"])
        let phone = devices[0]
        XCTAssertEqual(phone.defaultAction, .saveCopy)
        XCTAssertEqual(phone.lan?.token, "t")
        XCTAssertTrue(phone.lan!.usable())
        XCTAssertEqual(phone.bearing, 30)
        XCTAssertEqual(phone.distance, 1.5)
        XCTAssertEqual(phone.symbol, "iphone")
        let glasses = devices[1]
        XCTAssertEqual(glasses.defaultAction, .open, "unknown actions fall back to open")
        XCTAssertNil(glasses.lan)
        XCTAssertFalse(glasses.accepts(.image))
        XCTAssertTrue(glasses.accepts(.link))
        XCTAssertFalse(HoloLan(url: "http://x", token: "t", expires: 1).usable(), "an expired endpoint isn't tried")
    }

    func testDropRecordParsesAndNamesItself() {
        let link = HoloDropRecord(json: ["id": "d1", "kind": "link", "from": "iphone-1", "target": "mac-1",
                                         "url": "https://www.apple.com/x", "action": "open",
                                         "position": ["x": 0.8, "y": 0.2], "state": "delivered",
                                         "created": 1_800_000_000.0])!
        XCTAssertEqual(link.position, HoloPosition(x: 0.8, y: 0.2))
        XCTAssertEqual(link.webURL?.host, "www.apple.com")
        XCTAssertEqual(link.displayName, "www.apple.com")
        XCTAssertEqual(link.created, Date(timeIntervalSince1970: 1_800_000_000))
        let text = HoloDropRecord(json: ["id": "d2", "kind": "text", "text": "first line\nsecond", "position": NSNull()])!
        XCTAssertNil(text.position)
        XCTAssertNil(text.webURL)
        XCTAssertEqual(text.displayName, "first line")
        let urlText = HoloDropRecord(json: ["id": "d3", "kind": "text", "text": "  https://example.com/a  "])!
        XCTAssertEqual(urlText.webURL?.absoluteString, "https://example.com/a")
        let odd = HoloDropRecord(json: ["id": "d4", "kind": "link", "url": "file:///etc/passwd"])!
        XCTAssertNil(odd.webURL, "only web links count as openable")
        XCTAssertNil(HoloDropRecord(json: ["id": "x", "kind": "hologram"]))
        XCTAssertEqual(HoloDropRecord.landedLine(device: "iPhone", outcome: "saved"), "Landed on iPhone · Saved")
        XCTAssertEqual(HoloDropRecord.landedLine(device: "iPhone", outcome: "failed", error: "no space"),
                       "Didn't land on iPhone — no space")
    }

    func testPowerRowDecidesOnOff() {
        XCTAssertEqual(HoloDropAPI.holoEnabled(inPower: ["integrations": [["id": "holo-drop", "enabled": false]]]), false)
        XCTAssertEqual(HoloDropAPI.holoEnabled(inPower: ["integrations": [["id": "holo-drop", "enabled": true]]]), true)
        XCTAssertNil(HoloDropAPI.holoEnabled(inPower: ["integrations": [["id": "car", "enabled": true]]]),
                     "a server without Holo Drop has no row")
    }

    func testServerStatusesMapToFailures() {
        func status(_ code: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "http://x")!, statusCode: code, httpVersion: nil, headerFields: nil)!
        }
        XCTAssertThrowsError(try HoloDropAPI.check(Data(), status(409))) { XCTAssertEqual($0 as? HoloFailure, .off) }
        XCTAssertThrowsError(try HoloDropAPI.check(Data(), status(413))) { XCTAssertEqual($0 as? HoloFailure, .tooLarge) }
        XCTAssertThrowsError(try HoloDropAPI.check(Data(#"{"error":"unknown target"}"#.utf8), status(400))) {
            XCTAssertEqual($0 as? HoloFailure, .server(400, "unknown target"))
        }
        XCTAssertEqual(HJ.s(try HoloDropAPI.check(Data(#"{"ok":true,"x":"y"}"#.utf8), status(200))["x"]), "y")
    }

    // MARK: where it lands

    func testPositionMapsToTheVisibleFrameFromTheTopLeft() {
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)   // dock below, menu bar above
        XCTAssertEqual(HoloGeometry.point(for: HoloPosition(x: 0, y: 0), in: visible), CGPoint(x: 0, y: 945))
        XCTAssertEqual(HoloGeometry.point(for: HoloPosition(x: 1, y: 1), in: visible), CGPoint(x: 1512, y: 70))
        XCTAssertEqual(HoloGeometry.point(for: HoloPosition(x: 0.8, y: 0.2), in: visible).x, 1209.6, accuracy: 0.001)
        XCTAssertEqual(HoloGeometry.point(for: HoloPosition(x: 0.8, y: 0.2), in: visible).y, 770, accuracy: 0.001)
        XCTAssertEqual(HoloGeometry.point(for: nil, in: visible), CGPoint(x: 756, y: 507.5), "no aim: the middle")
    }

    func testCardIsCentredOnTheSpotAndStaysOnScreen() {
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)
        let size = HoloGeometry.cardSize
        let mid = HoloGeometry.cardFrame(position: nil, visible: visible)
        XCTAssertEqual(mid.midX, visible.midX, accuracy: 0.5)
        XCTAssertEqual(mid.midY, visible.midY, accuracy: 0.5)
        XCTAssertEqual(mid.size, size)
        let corner = HoloGeometry.cardFrame(position: HoloPosition(x: 1, y: 0), visible: visible)
        XCTAssertLessThanOrEqual(corner.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(corner.maxY, visible.maxY)
        let other = HoloGeometry.cardFrame(position: HoloPosition(x: 0, y: 1), visible: visible)
        XCTAssertGreaterThanOrEqual(other.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(other.minY, visible.minY)
        // A second display left of the main one: still inside the frame given.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1050)
        XCTAssertTrue(left.contains(HoloGeometry.cardFrame(position: HoloPosition(x: 0.5, y: 0.5), visible: left)))
    }

    func testAPictureCardTakesThePicturesShapeWithinItsBounds() {
        let lo = HoloGeometry.heroMin, hi = HoloGeometry.heroMax
        // 4:3, 3:4, 16:9, 9:16, square, panoramas, an iPhone screenshot, nonsense.
        let shapes: [CGFloat] = [1.3333, 0.75, 1.7778, 0.5625, 1, 3, 0.3333, 0.4615, 0.01, 100]
        for aspect in shapes {
            let s = HoloGeometry.heroSize(aspect: aspect)
            XCTAssertTrue((lo.width...hi.width).contains(s.width) && (lo.height...hi.height).contains(s.height),
                          "\(aspect) → \(s) leaves the bounds")
        }
        // Ordinary shapes are shown whole, at their own ratio (no letterbox, no crop)...
        let ordinary: [CGFloat] = [1.3333, 0.75, 1.5, 0.6667, 1]
        for aspect in ordinary {
            let s = HoloGeometry.heroSize(aspect: aspect)
            XCTAssertEqual(s.width / s.height, aspect, accuracy: 0.01, "\(aspect)")
        }
        // ...at about the same area whatever the shape.
        let landscape = HoloGeometry.heroSize(aspect: 4.0 / 3.0)
        let portrait = HoloGeometry.heroSize(aspect: 0.75)
        XCTAssertEqual(landscape.width * landscape.height, portrait.width * portrait.height, accuracy: 400)
        XCTAssertEqual(landscape.width, portrait.height)
        // Nonsense from a broken preview still gives a card.
        XCTAssertGreaterThan(HoloGeometry.heroSize(aspect: .nan).width, 0)
        XCTAssertGreaterThan(HoloGeometry.heroSize(aspect: 0).height, 0)
    }

    func testARefitGrowsTheCardWhereItSitsAndKeepsItOnScreen() {
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)
        let small = CGRect(x: 600, y: 400, width: 340, height: 62)
        let grown = HoloGeometry.refit(small, to: CGSize(width: 320, height: 240), visible: visible)
        XCTAssertEqual(grown.midX, small.midX, accuracy: 0.5)
        XCTAssertEqual(grown.midY, small.midY, accuracy: 0.5)
        XCTAssertEqual(grown.size, CGSize(width: 320, height: 240))
        // Near the bottom edge it grows upward instead of off the screen.
        let low = HoloGeometry.refit(CGRect(x: 600, y: 80, width: 340, height: 62), to: CGSize(width: 240, height: 400),
                                     visible: visible)
        XCTAssertTrue(visible.contains(low))
    }

    @MainActor
    func testTheCardSizesItselfToItsPictureOrItsContent() throws {
        let photo = HoloCardModel(drop: try XCTUnwrap(HoloDropRecord(json: ["id": "p", "kind": "image", "name": "IMG_1.HEIC"])),
                                  fromName: "iPhone")
        let compact = HoloCardView.size(for: photo)
        XCTAssertEqual(compact.width, HoloGeometry.compactWidth, "no picture yet: the compact card")
        XCTAssertLessThan(compact.height, 100, "a compact card has no empty picture area")
        photo.thumbnail = NSImage(size: CGSize(width: 400, height: 300))
        XCTAssertEqual(HoloCardView.size(for: photo), HoloGeometry.heroSize(aspect: 4.0 / 3.0))
        // A link never becomes a picture card, whatever is set on it.
        let link = HoloCardModel(drop: try XCTUnwrap(HoloDropRecord(json: ["id": "l", "kind": "link",
                                                                           "url": "https://apple.com"])), fromName: "iPhone")
        link.thumbnail = NSImage(size: CGSize(width: 400, height: 300))
        XCTAssertNil(link.heroAspect)
        XCTAssertEqual(HoloCardView.size(for: link).width, HoloGeometry.compactWidth)
    }

    @MainActor
    func testOneCardButtonAtATime() async throws {
        let text = HoloCardModel(drop: try XCTUnwrap(HoloDropRecord(json: ["id": "t", "kind": "text", "text": "hi"])),
                                 fromName: "iPad")
        text.state = .receiving
        text.run(.copy)
        XCTAssertNil(text.busy, "nothing runs while the drop is still arriving")
        text.state = .ready
        var ran: [HoloCardModel.Action] = []
        text.perform = { ran.append($0) }
        text.run(.copy)
        XCTAssertEqual(text.busy, .copy)
        text.run(.save)
        XCTAssertEqual(text.busy, .copy, "a second button waits for the first")
        while text.busy != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(ran, [.copy])
        text.run(.save)
        while text.busy != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(ran, [.copy, .save], "free again once the first is done")
    }

    func testWindowOutlinesAreFractionsOfTheDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let out = HoloGeometry.outlines([
            (CGRect(x: 100, y: 50, width: 400, height: 250), "Safari"),
            (CGRect(x: 800, y: 400, width: 400, height: 300), "Notes"),       // hangs off: clipped
            (CGRect(x: 10, y: 10, width: 20, height: 20), "Tiny"),            // too small
            (CGRect(x: 2000, y: 0, width: 300, height: 300), "Other screen"), // off this display
            (CGRect(x: 0, y: 0, width: 300, height: 300), ""),                // no app name
        ], display: display)
        XCTAssertEqual(out.map(\.app), ["Safari", "Notes"])
        XCTAssertEqual(out[0], HoloWindowOutline(x: 0.1, y: 0.1, w: 0.4, h: 0.5, app: "Safari"))
        XCTAssertEqual(out[1].w, 0.2, accuracy: 1e-9)
        XCTAssertEqual(out[1].h, 0.2, accuracy: 1e-9)
        let many = (0..<50).map { (CGRect(x: 0, y: 0, width: 100, height: 100), "App \($0)") }
        XCTAssertEqual(HoloGeometry.outlines(many, display: display).count, 30)
    }

    // MARK: what arriving does

    private func drop(_ kind: String, _ extra: [String: Any] = [:]) -> HoloDropRecord {
        HoloDropRecord(json: ["id": "d", "kind": kind, "name": "a.pdf"].merging(extra) { _, b in b })!
    }

    func testArrivalPlans() {
        let web = drop("link", ["url": "https://apple.com"])
        XCTAssertEqual(HoloArrivalPlan.make(web, action: .open), HoloArrivalPlan(open: true))
        XCTAssertEqual(HoloArrivalPlan.make(web, action: .saveCopy), HoloArrivalPlan(save: true, copy: true))
        let odd = drop("link", ["url": "x-apple.systempreferences:com.apple.preference"])
        XCTAssertEqual(HoloArrivalPlan.make(odd, action: .open), HoloArrivalPlan(openHeld: true),
                       "a non-web link only opens from the card's button")
        let text = drop("text", ["text": "hello"])
        XCTAssertEqual(HoloArrivalPlan.make(text, action: .open), HoloArrivalPlan(show: true))
        XCTAssertEqual(HoloArrivalPlan.make(text, action: .copy), HoloArrivalPlan(copy: true))
        let file = drop("file")
        XCTAssertEqual(HoloArrivalPlan.make(file, action: .open), HoloArrivalPlan(fetch: true, open: true))
        XCTAssertEqual(HoloArrivalPlan.make(file, action: .save), HoloArrivalPlan(fetch: true, save: true))
        XCTAssertEqual(HoloArrivalPlan.make(drop("image"), action: .saveOpen),
                       HoloArrivalPlan(fetch: true, save: true, open: true))
        XCTAssertEqual(HoloArrivalPlan.make(file, action: .open, executable: true),
                       HoloArrivalPlan(fetch: true, openHeld: true), "apps and scripts never open by themselves")
    }

    func testExecutablesAreRecognised() {
        for name in ["Installer.pkg", "run.command", "tool.sh", "Thing.app", "x.scpt", "y.dmg", "z.webloc"] {
            XCTAssertTrue(HoloArrivalPlan.isExecutable(name: name, mime: ""), name)
        }
        for name in ["photo.heic", "doc.pdf", "notes.txt", "movie.mov"] {
            XCTAssertFalse(HoloArrivalPlan.isExecutable(name: name, mime: ""), name)
        }
    }

    func testOutcomeFollowsWhatWorked() {
        XCTAssertEqual(HoloOutcome(saved: true, opened: true, copied: false, shown: true), .savedOpened)
        XCTAssertEqual(HoloOutcome(saved: true, opened: false, copied: true, shown: true), .savedCopied)
        XCTAssertEqual(HoloOutcome(saved: false, opened: true, copied: false, shown: true), .opened)
        XCTAssertEqual(HoloOutcome(saved: false, opened: false, copied: true, shown: true), .copied)
        XCTAssertEqual(HoloOutcome(saved: false, opened: false, copied: false, shown: true), .shown)
        XCTAssertEqual(HoloOutcome(saved: false, opened: false, copied: false, shown: false), .failed)
        XCTAssertTrue(HoloAction.saveOpen.saves && HoloAction.saveOpen.opens && !HoloAction.saveOpen.copies)
        XCTAssertEqual(HoloAction.allCases.map(\.rawValue), ["save", "open", "copy", "save_open", "save_copy"])
    }

    func testFileNamesAreSafeAndNeverOverwrite() {
        XCTAssertEqual(HoloFiles.safeName("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(HoloFiles.safeName(".hidden"), "hidden")
        XCTAssertEqual(HoloFiles.safeName("  "), "Holo Drop")
        XCTAssertEqual(HoloFiles.safeName("a:b\u{0}c.txt"), "a-bc.txt")
        let long = HoloFiles.safeName(String(repeating: "x", count: 300) + ".pdf")
        XCTAssertLessThanOrEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix(".pdf"))
        let taken: Set<String> = ["IMG.HEIC", "IMG 2.HEIC"]
        XCTAssertEqual(HoloFiles.unique("IMG.HEIC") { taken.contains($0) }, "IMG 3.HEIC")
        XCTAssertEqual(HoloFiles.unique("new.txt") { taken.contains($0) }, "new.txt")
        XCTAssertEqual(HoloFiles.unique("IMG") { ["IMG"].contains($0) }, "IMG 2")
    }

    // MARK: grab what's in front

    private struct FakeProbe: HoloFrontProbe {
        var page: (url: String, title: String)?
        var finder: [String] = []
        var document: String?
        var selection: String?

        func browserPage(bundleID: String) async -> (url: String, title: String)? { page }
        func finderSelection() async -> [String] { finder }
        func documentPath(pid: pid_t) -> String? { document }
        func selectedText(pid: pid_t) -> String? { selection }
    }

    private func grab(_ app: String?, _ probe: FakeProbe, exists: Set<String> = []) async -> HoloItem? {
        await HoloGrab.grab(bundleID: app, pid: 1, probe: probe, exists: { exists.contains($0) })
    }

    func testGrabTakesTheBrowsersPageFirst() async {
        let probe = FakeProbe(page: ("https://apple.com/vision-pro", "Apple Vision Pro"),
                              document: "file:///Users/p/a.pdf", selection: "selected words")
        let item = await grab("com.apple.Safari", probe, exists: ["/Users/p/a.pdf"])
        XCTAssertEqual(item, .link(URL(string: "https://apple.com/vision-pro")!, title: "Apple Vision Pro"))
        let arc = await grab("company.thebrowser.Browser", FakeProbe(page: ("https://x.y/", "")))
        XCTAssertEqual(arc, .link(URL(string: "https://x.y/")!, title: nil))
    }

    func testGrabFallsBackWhenTheBrowserWontSay() async {
        // Automation refused, or a non-web page: the selection still goes.
        let item = await grab("com.google.Chrome", FakeProbe(page: ("chrome://settings", ""), selection: "some text"))
        XCTAssertEqual(item, .text("some text"))
        let blocked = await grab("com.google.Chrome", FakeProbe(page: nil, document: "https://news.site/a"))
        XCTAssertEqual(blocked, .link(URL(string: "https://news.site/a")!, title: nil), "AXDocument can carry the page")
    }

    func testGrabTakesFindersSelectionThenTheDocumentThenTheSelectedText() async {
        let finder = await grab("com.apple.finder", FakeProbe(finder: ["/Users/p/a.pdf", "/gone.txt", ""],
                                                               selection: "text"), exists: ["/Users/p/a.pdf"])
        XCTAssertEqual(finder, .files([URL(fileURLWithPath: "/Users/p/a.pdf")]))
        let emptyFinder = await grab("com.apple.finder", FakeProbe(finder: [], selection: "picked"))
        XCTAssertEqual(emptyFinder, .text("picked"))
        let doc = await grab("com.apple.Preview", FakeProbe(document: "file:///Users/p/My%20Doc.pdf", selection: "x"),
                             exists: ["/Users/p/My Doc.pdf"])
        XCTAssertEqual(doc, .files([URL(fileURLWithPath: "/Users/p/My Doc.pdf")]))
        let unsaved = await grab("com.apple.TextEdit", FakeProbe(document: "file:///nowhere.rtf", selection: "draft"))
        XCTAssertEqual(unsaved, .text("draft"), "a document that isn't on disk falls through")
        let link = await grab("com.apple.Notes", FakeProbe(selection: " https://example.com/page "))
        XCTAssertEqual(link, .link(URL(string: "https://example.com/page")!, title: nil), "a selected address goes as a link")
        let nothing = await grab("com.apple.Terminal", FakeProbe(selection: "   "))
        XCTAssertNil(nothing, "nothing in front: the popup asks to paste or drop")
        let noApp = await grab(nil, FakeProbe())
        XCTAssertNil(noApp)
    }

    func testBrowserScriptsNameTheirOwnTab() {
        XCTAssertTrue(HoloGrab.browserScript("com.apple.Safari").contains("current tab"))
        XCTAssertTrue(HoloGrab.browserScript("com.google.Chrome").contains("active tab"))
        XCTAssertTrue(HoloGrab.browserScript("company.thebrowser.Browser").contains("application id \"company.thebrowser.Browser\""))
    }

    // MARK: the Orbit

    func testDevicesSpreadAroundTheRingOrSitAtTheirBearing() {
        let devices = [HoloDevice(id: "a", name: "A", kind: "iphone"), HoloDevice(id: "b", name: "B", kind: "ipad"),
                       HoloDevice(id: "c", name: "C", kind: "web"), HoloDevice(id: "d", name: "D", kind: "glasses")]
        XCTAssertEqual(HoloOrbitLayout.angles(devices), ["a": 0, "b": 90, "c": 180, "d": 270])
        let withBearing = [HoloDevice(id: "m", name: "Mac", kind: "mac", bearing: -45), HoloDevice(id: "p", name: "P", kind: "iphone")]
        XCTAssertEqual(HoloOrbitLayout.angles(withBearing), ["m": 315, "p": 0])
        let pos = HoloOrbitLayout.positions(devices, centre: CGPoint(x: 200, y: 200), radius: 100)
        XCTAssertEqual(pos["a"]!.y, 100, accuracy: 0.001)   // up
        XCTAssertEqual(pos["b"]!.x, 300, accuracy: 0.001)   // right
        XCTAssertEqual(pos["c"]!.y, 300, accuracy: 0.001)   // down
    }

    func testFlingPicksTheDeviceItPointsAt() {
        let devices = [HoloDevice(id: "up", name: "U", kind: "mac"), HoloDevice(id: "right", name: "R", kind: "ipad"),
                       HoloDevice(id: "down", name: "D", kind: "web"), HoloDevice(id: "left", name: "L", kind: "glasses")]
        XCTAssertEqual(HoloOrbitLayout.target(for: CGVector(dx: 5, dy: -200), devices: devices)?.id, "up")
        XCTAssertEqual(HoloOrbitLayout.target(for: CGVector(dx: 150, dy: 20), devices: devices)?.id, "right")
        XCTAssertEqual(HoloOrbitLayout.target(for: CGVector(dx: -150, dy: -10), devices: devices)?.id, "left")
        XCTAssertNil(HoloOrbitLayout.target(for: CGVector(dx: 10, dy: -10), devices: devices), "a nudge throws nothing")
        let two = [HoloDevice(id: "up", name: "U", kind: "mac"), HoloDevice(id: "down", name: "D", kind: "web")]
        XCTAssertNil(HoloOrbitLayout.target(for: CGVector(dx: 200, dy: 0), devices: two), "nothing within 35°")
    }

    func testNearestIsLit() {
        let devices = [HoloDevice(id: "far", name: "F", kind: "ipad", distance: 6),
                       HoloDevice(id: "near", name: "N", kind: "iphone", distance: 0.8),
                       HoloDevice(id: "sure", name: "S", kind: "mac", bearing: 10, bearingConfidence: 0.9)]
        XCTAssertEqual(HoloOrbitLayout.nearest(devices)?.id, "near")
        XCTAssertEqual(HoloOrbitLayout.nearest(Array(devices.suffix(1)))?.id, "sure")
        XCTAssertNil(HoloOrbitLayout.nearest([HoloDevice(id: "x", name: "X", kind: "web")]))
    }

    @MainActor
    func testTheChipsFollowTheDeviceUntilChanged() {
        let model = HoloOrbitModel()
        model.devices = [HoloDevice(id: "phone", name: "iPhone", kind: "iphone", defaultAction: .save, distance: 1),
                         HoloDevice(id: "glasses", name: "Glasses", kind: "glasses", accepts: ["link", "text"],
                                    defaultAction: .open)]
        XCTAssertEqual(model.action, .save, "the nearest device's default")
        model.aimed = "glasses"
        XCTAssertEqual(model.action, .open)
        model.override = .copy
        XCTAssertEqual(model.action, .copy)
        model.setItem(.files([URL(fileURLWithPath: "/tmp/a.png")]))
        XCTAssertEqual(model.targets.map(\.id), ["phone"], "glasses take text and links only")
        model.setItem(.link(URL(string: "https://a.b")!, title: nil))
        XCTAssertEqual(model.targets.count, 2)
        var sent: (String, HoloAction)?
        model.onSend = { d, a in sent = (d.id, a) }
        model.choose(model.devices[1])
        XCTAssertEqual(sent?.0, "glasses")
        XCTAssertEqual(sent?.1, .copy)
    }

    func testPastedTextThatIsAnAddressGoesAsALink() {
        XCTAssertEqual(HoloItem.fromText("https://apple.com"), .link(URL(string: "https://apple.com")!, title: nil))
        XCTAssertEqual(HoloItem.fromText("see https://apple.com"), .text("see https://apple.com"))
        XCTAssertNil(HoloItem.fromText(" \n "))
        XCTAssertEqual(HoloItem.files([URL(fileURLWithPath: "/a.mov")]).kinds, [.video])
        XCTAssertEqual(HoloKind.forFile(URL(fileURLWithPath: "/a.heic")), .image)
        XCTAssertEqual(HoloKind.forFile(URL(fileURLWithPath: "/a.pdf")), .file)
    }

    // MARK: beacons

    func testBeaconCodesAreStableAndFramed() {
        XCTAssertEqual(HoloBeaconCode.code16("4660"), 4660)
        XCTAssertEqual(HoloBeaconCode.code16("1a2b"), 0x1A2B)
        XCTAssertEqual(HoloBeaconCode.code16("0xBEEF"), 0xBEEF)
        XCTAssertEqual(HoloBeaconCode.code16("n-7f3c-abc"), HoloBeaconCode.code16("n-7f3c-abc"))
        XCTAssertNotEqual(HoloBeaconCode.code16("n-7f3c-abc"), HoloBeaconCode.code16("n-7f3c-abd"))
        let bits = HoloBeaconCode.chirpBits("4660")   // 0x1234
        XCTAssertEqual(bits.count, 20)
        XCTAssertEqual(Array(bits.prefix(4)), [true, false, true, false])
        XCTAssertEqual(Array(bits.suffix(16)).map { $0 ? "1" : "0" }.joined(), "0001001000110100")
        XCTAssertEqual(Double(bits.count) * HoloBeaconCode.chirpSymbol, 0.3, accuracy: 1e-9, "about 300 ms")
        let frames = HoloBeaconCode.flashFrames("4660")
        XCTAssertEqual(frames.count, 15, "1.5 s at 10 Hz")
        XCTAssertEqual(Array(frames.suffix(11)).map { $0 ? "1" : "0" }.joined(), "01000110100")
    }

    func testChirpSamplesAreQuietAndTheRightLength() {
        let samples = HoloBeacons.chirpSamples("4660", rate: 48_000)
        XCTAssertEqual(samples.count, 20 * 720)
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 1, 0.25 + 1e-6)
        XCTAssertEqual(samples.first ?? 1, 0, accuracy: 1e-6, "soft edges: no click")
    }

    // MARK: LAN receiver

    func testHTTPHeadParses() {
        let raw = Data("POST /holo-drop?x=1 HTTP/1.1\r\nHost: 10.0.0.2:5000\r\nX-Holo-Token: abc\r\nContent-Length: 12\r\nX-Holo-Meta: e30=\r\n\r\nBODY".utf8)
        let end = HoloHTTP.headEnd(raw)!
        XCTAssertEqual(String(data: raw.suffix(from: end), encoding: .utf8), "BODY")
        let head = HoloHTTP.parse(raw.prefix(end))!
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.path, "/holo-drop")
        XCTAssertEqual(head.headers["x-holo-token"], "abc")
        XCTAssertEqual(head.contentLength, 12)
        XCTAssertNil(HoloHTTP.headEnd(Data("POST / HTTP/1.1\r\nHost: x\r\n".utf8)))
        let reply = String(data: HoloHTTP.response(200, ["ok": true, "outcome": "saved"]), encoding: .utf8)!
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(reply.contains("Content-Length: "))
        XCTAssertTrue(reply.hasSuffix("}"))
    }

    func testTokensCompareExactly() {
        XCTAssertTrue(HoloHTTP.sameToken("abc123", "abc123"))
        XCTAssertFalse(HoloHTTP.sameToken("abc123", "abc124"))
        XCTAssertFalse(HoloHTTP.sameToken("abc", "abc123"))
        XCTAssertFalse(HoloHTTP.sameToken("", ""))
        let lan = HoloLanReceiver()
        let token = lan.newToken(validFor: 60)
        XCTAssertTrue(lan.accepts(token))
        let next = lan.newToken(validFor: 60)
        XCTAssertTrue(lan.accepts(token), "the last advertised token still works for a while")
        XCTAssertTrue(lan.accepts(next))
        XCTAssertFalse(lan.accepts("guess"))
        XCTAssertFalse(lan.accepts(nil))
    }

    /// The real listener on loopback: a file and a text drop land through it, a wrong token
    /// doesn't.
    @MainActor
    func testLanReceiverLandsADropEndToEnd() async throws {
        let lan = HoloLanReceiver()
        defer { lan.stop() }
        var seen: [(kind: String, bytes: Data, text: String)] = []
        lan.handler = { fields, file, inline in
            seen.append((HJ.s(fields["kind"]), file.flatMap { try? Data(contentsOf: $0) } ?? Data(), HJ.s(inline["text"])))
            return HJ.s(fields["kind"]) == "file" ? .saved : .copied
        }
        let port: UInt16 = await withCheckedContinuation { c in lan.start { c.resume(returning: $0) } }
        let token = lan.newToken(validFor: 60)
        let good = HoloLan(url: "http://127.0.0.1:\(port)", token: token, expires: 0)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("holo-\(UUID().uuidString).txt")
        try Data("hello holo".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let sentFile = await HoloDirect.send(lan: good, fields: HoloWire.directFields(
            kind: .file, name: "a.txt", mime: "text/plain", action: .save), file: file, inline: nil)
        XCTAssertEqual(sentFile, .landed(.saved))
        let sentText = await HoloDirect.send(lan: good, fields: HoloWire.directFields(kind: .text, action: .copy),
                                             file: nil, inline: ["text": "hi there"])
        XCTAssertEqual(sentText, .landed(.copied))
        let bad = HoloLan(url: good.url, token: "guess", expires: 0)
        let refused = await HoloDirect.send(lan: bad, fields: HoloWire.directFields(kind: .text, action: .copy),
                                            file: nil, inline: ["text": "x"])
        XCTAssertEqual(refused, .unreachable, "turned away unread (401): safe to send through Jarvis")
        XCTAssertEqual(seen.count, 2, "the refused one never reached the handler")
        XCTAssertEqual(seen.first?.kind, "file")
        XCTAssertEqual(seen.first?.bytes, Data("hello holo".utf8))
        XCTAssertEqual(seen.last?.text, "hi there")
    }

    func testDirectRepliesMeanWhatTheySay() {
        XCTAssertEqual(HoloDirect.verdict(status: 200, body: Data(#"{"ok":true,"outcome":"saved_opened"}"#.utf8)),
                       .landed(.savedOpened))
        XCTAssertEqual(HoloDirect.verdict(status: 500, body: Data(#"{"ok":false,"error":"Photos refused"}"#.utf8)),
                       .refused("Photos refused"), "it acted on it: report, don't resend")
        XCTAssertEqual(HoloDirect.verdict(status: 200, body: Data(#"{"ok":false}"#.utf8)), .refused("it couldn't take it"))
        XCTAssertEqual(HoloDirect.verdict(status: 401, body: Data(#"{"ok":false,"error":"bad token"}"#.utf8)),
                       .unreachable, "turned away unread: Jarvis takes it")
        XCTAssertEqual(HoloDirect.verdict(status: 413, body: Data()), .unreachable)
    }

    func testLanAddressPrefersWiFiOverTunnels() {
        XCTAssertEqual(HoloLanAddress.pick([("lo0", "127.0.0.1"), ("utun3", "100.64.0.2"), ("en1", "10.0.0.9"),
                                            ("en0", "192.168.1.20")]), "192.168.1.20")
        XCTAssertEqual(HoloLanAddress.pick([("bridge0", "192.168.64.1"), ("en7", "10.0.0.9")]), "10.0.0.9")
        XCTAssertNil(HoloLanAddress.pick([("en0", "169.254.3.4"), ("awdl0", "10.1.1.1")]))
    }

    // MARK: moved

    func testWifiMoveNeedsANewAccessPointOrABigSignalJump() {
        XCTAssertTrue(HoloMovedWatch.wifiMoved(baselineRSSI: -50, currentRSSI: -50, bssidBefore: "aa:bb", bssidNow: "aa:cc"))
        XCTAssertFalse(HoloMovedWatch.wifiMoved(baselineRSSI: -50, currentRSSI: -50, bssidBefore: "AA:BB", bssidNow: "aa:bb"))
        XCTAssertTrue(HoloMovedWatch.wifiMoved(baselineRSSI: -45, currentRSSI: -61, bssidBefore: nil, bssidNow: nil))
        XCTAssertFalse(HoloMovedWatch.wifiMoved(baselineRSSI: -45, currentRSSI: -55, bssidBefore: nil, bssidNow: nil))
        XCTAssertFalse(HoloMovedWatch.wifiMoved(baselineRSSI: nil, currentRSSI: -80, bssidBefore: nil, bssidNow: nil))
    }

    // MARK: the shortcut

    func testHoloDropHasItsOwnDefaultShortcut() {
        XCTAssertEqual(ShortcutAction.holoDrop.defaultShortcut?.display, "⌃⌥H")
        XCTAssertNotEqual(ShortcutAction.holoDrop.defaultShortcut, ShortcutAction.openChat.defaultShortcut)
        XCTAssertTrue(ShortcutAction.shortcutsTab.contains(.holoDrop))
    }
}

/// Renders the Orbit popup and the landing card to PNGs (JC_HOLO_SNAPSHOT, default
/// /tmp/macshots) to look at the design without a live server.
final class HoloDropRenderTests: XCTestCase {
    @MainActor
    func testThePopupAndTheCardRender() throws {
        let out = ProcessInfo.processInfo.environment["JC_HOLO_SNAPSHOT"] ?? "/tmp/macshots"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        func shoot<V: View>(_ view: V, _ name: String) throws {
            let host = NSHostingView(rootView: view.padding(24).background(Color(white: 0.25)))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(out)/holo-\(name).png"))
        }
        let model = HoloOrbitModel()
        model.devices = [HoloDevice(id: "p", name: "iPhone", kind: "iphone", defaultAction: .open, distance: 0.9),
                         HoloDevice(id: "i", name: "iPad", kind: "ipad"),
                         HoloDevice(id: "w", name: "Web tab", kind: "web"),
                         HoloDevice(id: "g", name: "Glasses", kind: "glasses", online: false)]
        model.loading = false
        model.setItem(.link(URL(string: "https://www.apple.com/apple-vision-pro/")!, title: "Apple Vision Pro — Apple"))
        try shoot(HoloOrbitView(model: model).environment(\.colorScheme, .dark), "orbit")
        let empty = HoloOrbitModel()
        empty.devices = model.devices
        empty.loading = false
        empty.phase = .waiting("Sent — waiting for iPhone")
        try shoot(HoloOrbitView(model: empty).environment(\.colorScheme, .dark), "orbit-empty")
    }

    /// The arrival card in each of its shapes, at 2x, on a plain backdrop with the panel's
    /// shadow. Photos come from `<out>/src/{landscape,portrait,video}.jpg` when present (real
    /// pictures read better), else a drawn stand-in.
    @MainActor
    func testTheArrivalCardRenders() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JC_HOLO_SNAPSHOT"] ?? "/tmp/macshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func picture(_ name: String, _ size: CGSize) -> NSImage {
            if let real = NSImage(contentsOf: out.appendingPathComponent("src/\(name).jpg")) { return real }
            return NSImage(size: size, flipped: false) { r in
                NSGradient(colors: [NSColor(white: 0.75, alpha: 1), NSColor(white: 0.2, alpha: 1)])?.draw(in: r, angle: -60)
                return true
            }
        }
        func drop(_ json: [String: Any]) throws -> HoloCardModel {
            var o = json
            o["created"] = Date().timeIntervalSince1970
            return HoloCardModel(drop: try XCTUnwrap(HoloDropRecord(json: o)), fromName: "iPhone")
        }
        func shoot(_ card: HoloCardModel, _ name: String) throws {
            let size = HoloCardView.size(for: card)
            let view = HoloCardView(card: card)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                .padding(40)
                .background(Color(white: 0.36))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, name)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("card-\(name).png"))
        }

        let landscape = try drop(["id": "1", "kind": "image", "name": "IMG_9766.HEIC"])
        landscape.thumbnail = picture("landscape", CGSize(width: 800, height: 600))
        landscape.outcome = .opened
        try shoot(landscape, "photo-landscape")

        let portrait = try drop(["id": "2", "kind": "image", "name": "IMG_9771.HEIC"])
        portrait.thumbnail = picture("portrait", CGSize(width: 600, height: 800))
        portrait.outcome = .saved
        portrait.savedFile = URL(fileURLWithPath: "/tmp/IMG_9771.HEIC")
        try shoot(portrait, "photo-portrait")

        let video = try drop(["id": "3", "kind": "video", "name": "IMG_9766.MOV"])
        video.thumbnail = picture("video", CGSize(width: 960, height: 540))
        video.outcome = .opened
        try shoot(video, "video")

        let link = try drop(["id": "4", "kind": "link", "url": "https://www.apple.com/apple-vision-pro/",
                             "title": "Apple Vision Pro — Apple"])
        link.outcome = .opened
        try shoot(link, "link")

        let busy = try drop(["id": "5", "kind": "image", "name": "IMG_9766.HEIC"])
        busy.thumbnail = landscape.thumbnail
        busy.outcome = .opened
        busy.busy = .copy
        try shoot(busy, "busy")

        let text = try drop(["id": "6", "kind": "text",
                             "text": "Pick up the dry cleaning before 6, then call the plumber about the kitchen tap."])
        text.outcome = .copied
        text.copied = true
        try shoot(text, "text")

        let arriving = try drop(["id": "7", "kind": "video", "name": "IMG_9766.MOV"])
        arriving.state = .receiving
        try shoot(arriving, "receiving")

        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("Quarterly report.zip")
        try Data("PK".utf8).write(to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }
        let file = try drop(["id": "8", "kind": "file", "name": "Quarterly report.zip"])
        file.file = zip
        file.savedFile = zip
        file.outcome = .saved
        try shoot(file, "file")

        // The close button, on hover: top right on a picture, over the icon's corner on a compact card.
        landscape.hovering = true
        try shoot(landscape, "photo-hover")
        link.hovering = true
        try shoot(link, "link-hover")

        // Text asked to open: all of it, scrolling past a point. (Hosted, not ImageRenderer:
        // the renderer leaves a ScrollView out.)
        let long = try drop(["id": "10", "kind": "text", "text": Array(repeating:
            "Notes from the call: ship the Mac card redesign, then the iPhone one; check the dark desktop.",
            count: 6).joined(separator: "\n\n")])
        long.outcome = .shown
        long.expanded = true
        let size = HoloCardView.size(for: long)
        let host = NSHostingView(rootView: HoloCardView(card: long).frame(width: size.width, height: size.height)
            .padding(40).background(Color(white: 0.36)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("card-text-open.png"))
        XCTAssertLessThan(size.height, 300, "long text scrolls inside the card rather than growing it")

        let failed = try drop(["id": "9", "kind": "image", "name": "IMG_9780.HEIC"])
        failed.state = .failed("the phone went to sleep")
        try shoot(failed, "failed")
    }
}

/// The bug sweep's fixes (2026-11-14): a slow phone isn't sent the file twice, late landings
/// are shown, auto-open checks the name as written, the switch follows the `power` topic, the
/// flash keeps time, the Orbit survives a click elsewhere, temp copies are cleaned, and a new
/// paired id renames the Bluetooth beacon.
final class HoloDropSweepTests: XCTestCase {

    /// A real LAN receiver on loopback whose handler takes `delay` and answers `outcome`.
    @MainActor
    private func receiver(delay: Double, outcome: HoloOutcome) async -> (HoloLanReceiver, HoloLan) {
        let lan = HoloLanReceiver()
        lan.handler = { _, _, _ in
            try? await Task.sleep(for: .seconds(delay))
            return outcome
        }
        let port: UInt16 = await withCheckedContinuation { c in lan.start { c.resume(returning: $0) } }
        return (lan, HoloLan(url: "http://127.0.0.1:\(port)", token: lan.newToken(validFor: 120), expires: 0))
    }

    /// Jarvis itself unreachable: any fallback to the server throws.
    private let noServer = HoloDropAPI(origin: "http://127.0.0.1:1")

    @MainActor
    func testASlowReceiverIsWaitedForNotSentAgainThroughJarvis() async throws {
        let (lan, info) = await receiver(delay: 2.6, outcome: .copied)
        defer { lan.stop() }
        let phone = HoloDevice(id: "iphone-1", name: "iPhone", kind: "iphone", lan: info)
        let sent = try await HoloSender(api: noServer).send(.text("hello"), to: phone, action: .copy)
        XCTAssertEqual(sent.outcome, .copied)
        XCTAssertTrue(sent.ids.isEmpty, "never uploaded a second copy")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("holo-slow-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let sentFile = try await HoloSender(api: noServer).send(.files([file]), to: phone, action: .save)
        XCTAssertEqual(sentFile.outcome, .copied)
    }

    @MainActor
    func testARefusingReceiverIsReportedNotResentThroughJarvis() async throws {
        let (lan, info) = await receiver(delay: 0, outcome: .failed)
        defer { lan.stop() }
        let phone = HoloDevice(id: "iphone-1", name: "iPhone", kind: "iphone", lan: info)
        let sent = try await HoloSender(api: noServer).send(.text("hello"), to: phone, action: .copy)
        XCTAssertEqual(sent.outcome, .failed)
        XCTAssertTrue(sent.ids.isEmpty)
    }

    func testAnUnreachableReceiverFallsBackToJarvis() async {
        let gone = HoloDevice(id: "iphone-1", name: "iPhone", kind: "iphone",
                              lan: HoloLan(url: "http://127.0.0.1:9", token: "t", expires: 0))
        do {
            _ = try await HoloSender(api: noServer).send(.text("hello"), to: gone, action: .copy)
            XCTFail("expected the server fallback (unreachable here) to be tried")
        } catch {
            XCTAssertEqual(error as? HoloFailure, .notReachable)
        }
    }

    @MainActor
    func testEveryLandingIsShownOnceEvenAfterTheOrbitClosed() {
        let holo = HoloDrop.shared
        var toasts: [String] = []
        let before = holo.toaster
        holo.toaster = { line, _ in toasts.append(line) }
        defer { holo.toaster = before }
        let id = "sweep-\(UUID().uuidString)"
        holo.handle(frame: ["type": "holo_drop", "event": "landed",
                            "drop": ["id": id, "kind": "link", "target": "iphone-1", "outcome": "saved"]])
        XCTAssertEqual(toasts.count, 1, "a landing nobody was waiting for still shows")
        XCTAssertTrue(toasts.first?.contains("Saved") ?? false)
        holo.handle(frame: ["type": "holo_drop", "event": "landed",
                            "drop": ["id": id, "kind": "link", "target": "iphone-1", "outcome": "saved"]])
        XCTAssertEqual(toasts.count, 1, "once")
        holo.handle(frame: ["type": "holo_drop", "event": "landed", "error": "no space",
                            "drop": ["id": id + "-f", "kind": "file", "target": "iphone-1", "outcome": "failed"]])
        XCTAssertEqual(toasts.count, 2)
        XCTAssertTrue(toasts.last.map { $0.contains("Didn't land") && $0.contains("no space") } ?? false)
    }

    func testAutoOpenChecksTheNameAsWritten() {
        XCTAssertTrue(HoloArrivalPlan.isExecutable(name: "run.terminal\u{7}", mime: ""))
        XCTAssertTrue(HoloArrivalPlan.isExecutable(name: "x.terminal ", mime: ""))
        XCTAssertTrue(HoloArrivalPlan.isExecutable(name: "evil.app\u{202E}", mime: ""))
        XCTAssertFalse(HoloArrivalPlan.isExecutable(name: "photo.heic ", mime: ""))
    }

    @MainActor
    func testTheSwitchFollowsThePowerTopic() {
        XCTAssertNotNil(AppModel.topics["power"], "the server publishes `power` on every change")
        XCTAssertNil(AppModel.topics["holo_drop"])
        let before = HoloDrop.shared.powerPokes
        AppModel().handle(["type": "topic", "topic": "power", "data": [:]])
        XCTAssertEqual(HoloDrop.shared.powerPokes, before + 1)
    }

    func testFlashFramesKeepFixedDeadlines() {
        let t0 = ContinuousClock.now
        let starts = HoloBeacons.flashFrameStarts(count: 15, from: t0)
        XCTAssertEqual(starts.count, 15)
        for (i, s) in starts.enumerated() { XCTAssertEqual(s, t0.advanced(by: .milliseconds(100 * i))) }
    }

    @MainActor
    func testTheOrbitStaysOpenWhenItLosesFocus() throws {
        let orbit = HoloOrbitController(owner: HoloDrop.shared)
        orbit.show()
        defer { orbit.close() }
        let window = try XCTUnwrap(orbit.window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(orbit.visible, "clicking Finder to drag a file in mustn't close it")
    }

    func testOldHoloDropTempFilesAreSweptAndOnlyTempCopiesReleased() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("holo-sweep-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func folder(_ name: String, age: TimeInterval) throws -> URL {
            let u = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u.appendingPathComponent("f.txt"))
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
            return u
        }
        let old = try folder("HoloDrop-old", age: 30 * 3600)
        let fresh = try folder("HoloDrop-fresh", age: 60)
        let other = try folder("SomethingElse", age: 30 * 3600)
        HoloTemp.sweep(root, maxAge: 24 * 3600)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path), "only Holo Drop's own")
        let mine = fresh.appendingPathComponent("f.txt")
        let his = other.appendingPathComponent("f.txt")
        HoloTemp.release(.files([mine, his]), root: root)
        XCTAssertFalse(fm.fileExists(atPath: fresh.path), "a temp copy goes once its drop settled")
        XCTAssertTrue(fm.fileExists(atPath: his.path), "never a file of his")
    }

    @MainActor
    func testALaterHelloUpdatesTheDeviceIDAndTheBeaconName() {
        let model = AppModel()
        model.handle(["type": "hello", "device_id": "dev-a"])
        XCTAssertEqual(model.deviceId, "dev-a")
        model.handle(["type": "hello", "device_id": "dev-b"])
        XCTAssertEqual(model.deviceId, "dev-b")
        model.handle(["type": "hello"])
        XCTAssertEqual(model.deviceId, "dev-b", "a hello without one keeps the last")
        let ble = HoloBLEAdvertiser()
        ble.makeManager = { _ in nil }
        ble.start(deviceID: "a")
        XCTAssertEqual(ble.advertisedName, HoloBLEAdvertiser.localName(deviceID: "a"))
        ble.start(deviceID: "b")
        XCTAssertEqual(ble.advertisedName, HoloBLEAdvertiser.localName(deviceID: "b"))
        ble.stop()
        XCTAssertNil(ble.advertisedName)
    }
}
