import CoreGraphics
import ImageIO
import XCTest
@testable import JarvisCopilot

final class HoloDropCoreTests: XCTestCase {
    private func device(_ id: String, kind: String = "mac", bearing: Double? = nil, action: String = "open") -> HoloDevice {
        var o: [String: Any] = ["id": id, "name": id, "kind": kind, "online": true, "default_action": action,
                                "accepts": ["link", "text", "image", "video", "file"]]
        if let bearing { o["bearing"] = ["deg": bearing, "confidence": 0.9] }
        return HoloDevice(json: o)!
    }

    func testBubblesSitAtRealBearingsRelativeToHeading() {
        let size = CGSize(width: 300, height: 600)
        let p = HoloOrbitLayout.positions(devices: [device("mac", bearing: 90)], heading: 90, size: size)
        let center = CGPoint(x: 150, y: 288)
        XCTAssertEqual(p["mac"]!.x, center.x, accuracy: 0.5)       // facing it: straight up
        XCTAssertLessThan(p["mac"]!.y, center.y)
        let turned = HoloOrbitLayout.positions(devices: [device("mac", bearing: 90)], heading: 0, size: size)
        XCTAssertGreaterThan(turned["mac"]!.x, center.x + 50)     // it's to the right now
    }

    func testDevicesWithoutBearingShareTheRing() {
        let p = HoloOrbitLayout.positions(devices: [device("a"), device("b"), device("c")], heading: nil,
                                          size: CGSize(width: 300, height: 600))
        XCTAssertEqual(Set(p.keys), ["a", "b", "c"])
        XCTAssertEqual(Set(p.values.map { "\(Int($0.x)),\(Int($0.y))" }).count, 3)
    }

    func testFlingPicksTheBubbleItPointsAt() {
        let origin = CGPoint(x: 150, y: 300)
        let positions = ["up": CGPoint(x: 150, y: 100), "right": CGPoint(x: 350, y: 300)]
        XCTAssertEqual(HoloOrbitLayout.target(forVelocity: CGVector(dx: 0, dy: -900), from: origin, positions: positions), "up")
        XCTAssertEqual(HoloOrbitLayout.target(forVelocity: CGVector(dx: 900, dy: 40), from: origin, positions: positions), "right")
        XCTAssertNil(HoloOrbitLayout.target(forVelocity: CGVector(dx: -900, dy: 900), from: origin, positions: positions))
        XCTAssertNil(HoloOrbitLayout.target(forVelocity: CGVector(dx: 0, dy: -100), from: origin, positions: positions))
    }

    @MainActor
    func testActionDefaultsAndOverride() {
        let model = HoloOrbitModel(item: .text("hi"), client: HoloDropClient(baseURL: URL(string: "https://x")!, headers: [:]))
        let mac = device("mac", action: "open"), phone = device("phone", kind: "iphone", action: "save")
        XCTAssertEqual(model.action(for: mac), .open)
        XCTAssertEqual(model.action(for: phone), .save)
        model.override = .copy
        XCTAssertEqual(model.action(for: mac), .copy)
    }

    func testAimCombinesTiltAndClamps() {
        let spot = HoloScreenMapView.combined(HoloPosition(x: 0.9, y: 0.1), tilt: CGSize(width: 0.3, height: -0.3))
        XCTAssertEqual(spot, HoloPosition(x: 1, y: 0))
    }

    func testDropMetaForEachKind() {
        let client = HoloDropClient(baseURL: URL(string: "https://x")!, headers: [:])
        let mac = device("mac")
        let link = client.meta(.link(URL(string: "https://a.b")!, title: "A"), device: mac, action: .open,
                               position: HoloPosition(x: 0.2, y: 0.3))
        XCTAssertEqual(link["kind"] as? String, "link")
        XCTAssertEqual((link["position"] as? [String: Double])?["x"], 0.2)
        let text = client.meta(.text("hi"), device: mac, action: .copy, position: nil)
        XCTAssertEqual(text["text"] as? String, "hi")
        XCTAssertEqual(text["action"] as? String, "copy")
    }

    func testDeviceDecodesBearingAndLan() {
        let d = HoloDevice(json: ["id": "m", "kind": "mac", "lan": ["url": "http://10.0.0.2:5000", "token": "t"],
                                  "bearing": ["deg": 45, "confidence": 0.7], "distance_m": 2.5])!
        XCTAssertEqual(d.lanURL?.absoluteString, "http://10.0.0.2:5000")
        XCTAssertEqual(d.bearingDeg, 45)
        XCTAssertEqual(d.distance, 2.5)
    }
}

/// The Orbit opens at once on the devices it saw last time, and refreshes them behind.
@MainActor
final class HoloOrbitQuickOpenTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "holo-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func row(_ id: String, online: Bool = true) -> [String: Any] {
        ["id": id, "kind": "mac", "name": id.capitalized, "online": online, "accepts": ["link", "text", "image"],
         "lan": ["url": "http://10.0.0.5:8765", "token": "secret"]]
    }

    private func model(_ cache: UserDefaults) -> HoloOrbitModel {
        HoloOrbitModel(item: .text("hi"), client: HoloDropClient(baseURL: URL(string: "https://x")!, headers: [:]),
                       deviceCache: cache)
    }

    func testTheCacheKeepsDevicesButNotTheirLanTokens() {
        let cache = defaults()
        HoloDeviceCache.save([row("studio")], to: cache)
        let devices = HoloDeviceCache.load(from: cache)
        XCTAssertEqual(devices.map(\.id), ["studio"])
        XCTAssertEqual(devices.first?.name, "Studio")
        XCTAssertNil(devices.first?.lanToken)
        XCTAssertNil(devices.first?.lanURL)
    }

    func testOpensOnCachedDevicesBeforeTheServerAnswers() async {
        let cache = defaults()
        HoloDeviceCache.save([row("studio")], to: cache)
        let m = model(cache)
        var phaseWhileFetching: HoloOrbitModel.Phase?
        m.fetchDevices = { [unowned m] in
            phaseWhileFetching = m.phase
            return [self.row("studio"), self.row("kitchen")]
        }
        await m.load()
        XCTAssertEqual(phaseWhileFetching, .choosing)
        XCTAssertEqual(m.phase, .choosing)
        XCTAssertEqual(m.devices.map(\.id), ["studio", "kitchen"])
        XCTAssertEqual(HoloDeviceCache.load(from: cache).map(\.id), ["studio", "kitchen"])
    }

    func testKeepsCachedDevicesWhenTheServerIsUnreachable() async {
        let cache = defaults()
        HoloDeviceCache.save([row("studio")], to: cache)
        let m = model(cache)
        m.fetchDevices = { throw URLError(.notConnectedToInternet) }
        await m.load()
        XCTAssertEqual(m.phase, .choosing)
        XCTAssertEqual(m.devices.map(\.id), ["studio"])
    }

    func testWithNoCacheAnUnreachableServerStillFails() async {
        let m = model(defaults())
        m.fetchDevices = { throw URLError(.notConnectedToInternet) }
        await m.load()
        guard case .done(.failed) = m.phase else { return XCTFail("phase \(m.phase)") }
    }
}

/// Where devices are: kept until he sets them again, taught by throws, set by pointing.
final class HoloDeviceSpotTests: XCTestCase {
    private func device(_ id: String, kind: String = "mac") -> HoloDevice {
        HoloDevice(json: ["id": id, "kind": kind, "name": id, "online": true, "accepts": ["link", "text", "image"]])!
    }

    func testAForwardThrowTeachesWhereTheDeviceIs() {
        let forward = HoloFlick(screen: CGVector(dx: 0, dy: -1), forward: true, strength: 2)
        XCTAssertEqual(HoloFling.learned(forward, heading: 370, device: device("mac")), 10)
        XCTAssertNil(HoloFling.learned(forward, heading: nil, device: device("mac")))
    }

    func testASidewaysFlickOrAWebTabTeachesNothing() {
        let sideways = HoloFlick(screen: CGVector(dx: 1, dy: 0), forward: false, strength: 2)
        XCTAssertNil(HoloFling.learned(sideways, heading: 90, device: device("mac")))
        let forward = HoloFlick(screen: CGVector(dx: 0, dy: -1), forward: true, strength: 2)
        XCTAssertNil(HoloFling.learned(forward, heading: 90, device: device("web", kind: "web")))
    }

    func testPointingAtADeviceSavesWhereThePhonePoints() {
        let r = HoloSensing.pointReading(heading: -20, distance: 2)
        XCTAssertEqual(r?.deg, 340)
        XCTAssertEqual(r?.source, "set")
        XCTAssertEqual(r?.distance, 2)
        XCTAssertNil(HoloSensing.pointReading(heading: nil, distance: nil))
    }
}

/// The Pod and glasses get a small JPEG, not the whole original.
final class HoloTextDeviceItemTests: XCTestCase {
    private func png(_ w: Int, _ h: Int) throws -> URL {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testAPhotoBecomesASmallJpeg() async throws {
        let item = HoloItem.file(try png(3000, 2000), name: "IMG_1.PNG", mime: "image/png", kind: "image")
        let small = await HoloDropClient.forTextDevice(item)
        guard case .file(let url, let name, let mime, let kind) = small else { return XCTFail("not a file") }
        XCTAssertEqual(name, "IMG_1.PNG")
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertEqual(kind, "image")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(max(props[kCGImagePropertyPixelWidth] as? Int ?? .max,
                                     props[kCGImagePropertyPixelHeight] as? Int ?? .max), 480)
    }

    func testLinksAndTextGoAsTheyAre() async {
        let link = HoloItem.link(URL(string: "https://a.b")!, title: "A")
        let same = await HoloDropClient.forTextDevice(link)
        XCTAssertEqual(same, link)
    }

    func testOnlyThePodAndGlassesAreTextOnly() {
        func d(_ kind: String) -> HoloDevice { HoloDevice(json: ["id": kind, "kind": kind])! }
        XCTAssertTrue(d("pod").showsTextOnly)
        XCTAssertTrue(d("glasses").showsTextOnly)
        XCTAssertFalse(d("mac").showsTextOnly)
        XCTAssertFalse(d("iphone").showsTextOnly)
    }
}

