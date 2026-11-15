import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import JarvisCopilot

/// Back Tap on a photo: find that photo's original from the screenshot.
final class HoloScreenPhotoTests: XCTestCase {
    /// A "photo": a diagonal gradient with a few blocks, deterministic per seed.
    private func photo(_ w: Int, _ h: Int, seed: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                let v = CGFloat((x * (seed % 5 + 1) + y * (seed % 3 + 2)) % 255) / 255
                ctx.setFillColor(red: v, green: CGFloat((seed * 37 + x) % 255) / 255, blue: 1 - v, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return ctx.makeImage()!
    }

    /// Photos' viewer: black screen, the photo letterboxed in the middle, sparse UI at top and bottom.
    private func screenshot(of p: CGImage, screen: CGSize = CGSize(width: 390, height: 844)) -> (CGImage, CGRect) {
        let ctx = CGContext(data: nil, width: Int(screen.width), height: Int(screen.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: screen))
        let h = screen.width * CGFloat(p.height) / CGFloat(p.width)
        let rect = CGRect(x: 0, y: (screen.height - h) / 2, width: screen.width, height: h)
        ctx.draw(p, in: rect)
        ctx.setFillColor(gray: 1, alpha: 1)
        for x in stride(from: 20, to: 370, by: 70) {                 // toolbar icons
            ctx.fill(CGRect(x: CGFloat(x), y: 40, width: 22, height: 22))
            ctx.fill(CGRect(x: CGFloat(x), y: screen.height - 70, width: 22, height: 22))
        }
        // CGContext's origin is bottom-left; the region is reported top-left like UIKit.
        return (ctx.makeImage()!, CGRect(x: rect.minX, y: screen.height - rect.maxY, width: rect.width, height: rect.height))
    }

    func testFindsTheLetterboxedPhotoInTheScreenshot() {
        let (shot, truth) = screenshot(of: photo(400, 300, seed: 7))
        let found = HoloScreenPhoto.photoRegion(in: shot)
        XCTAssertNotNil(found)
        let px = CGRect(x: found!.minX * 390, y: found!.minY * 844, width: found!.width * 390, height: found!.height * 844)
        XCTAssertEqual(px.minY, truth.minY, accuracy: 20)
        XCTAssertEqual(px.height, truth.height, accuracy: 30)
    }

    func testTheCroppedPhotoMatchesItsOriginalAndNotAnother() {
        let original = photo(400, 300, seed: 7), other = photo(400, 300, seed: 11)
        let (shot, _) = screenshot(of: original)
        let region = HoloScreenPhoto.photoRegion(in: shot)!
        let h = HoloScreenPhoto.dHash(shot, region: region)
        let same = HoloScreenPhoto.hamming(h, HoloScreenPhoto.dHash(original))
        let diff = HoloScreenPhoto.hamming(h, HoloScreenPhoto.dHash(other))
        XCTAssertLessThanOrEqual(same, 8)
        XCTAssertGreaterThan(diff, same + 8)
    }

    func testOnlyAConfidentUniqueMatchCounts() {
        XCTAssertEqual(HoloScreenPhoto.pick([("a", 3), ("b", 20), ("c", 25)]), "a")
        XCTAssertNil(HoloScreenPhoto.pick([("a", 3), ("b", 5)]), "two near-identical candidates: not sure which")
        XCTAssertNil(HoloScreenPhoto.pick([("a", 18), ("b", 30)]), "nothing close")
    }

    // MARK: the page's inbox

    func testInboxListsThisPhonesRecentDropsWithStatus() {
        let now = Date(timeIntervalSince1970: 100_000)
        let drops: [[String: Any]] = [
            ["id": "a", "kind": "link", "url": "https://a.b", "target": "me", "state": "delivered", "created": 99_000],
            ["id": "b", "kind": "text", "text": "hi", "target": "me", "state": "landed", "outcome": "copied", "created": 98_000],
            ["id": "c", "kind": "text", "text": "x", "target": "mac", "state": "delivered", "created": 99_500],     // not mine
            ["id": "d", "kind": "text", "text": "old", "target": "me", "state": "landed", "created": 1_000],         // > 24 h
            ["id": "e", "kind": "text", "text": "gone", "target": "me", "state": "delivered", "created": 99_900],
        ]
        let entries = HoloInbox.entries(from: drops, me: "me", dismissed: ["e"], now: now)
        XCTAssertEqual(entries.map(\.id), ["a", "b"])
        XCTAssertEqual(HoloInbox.status(entries[0]), "Waiting")
        XCTAssertEqual(HoloInbox.status(entries[1]), "Copied")
    }

    // MARK: the photo itself, from "Get What's On Screen"

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("onscreen-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testAPhotoOnScreenIsSentAsItself() throws {
        let bytes = Data([0x00, 0x01, 0x02, 0x03])
        let item = try XCTUnwrap(HoloScreenPhoto.onScreenItem(data: bytes, filename: "IMG_4021.HEIC", type: .heic, in: tempDir()))
        guard case .file(let url, let name, let mime, let kind) = item else { return XCTFail("not a file: \(item)") }
        XCTAssertEqual(name, "IMG_4021.HEIC")
        XCTAssertEqual(kind, "image")
        XCTAssertEqual(mime, "image/heic")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testAVideoOnScreenIsSentAsAVideo() throws {
        let item = try XCTUnwrap(HoloScreenPhoto.onScreenItem(data: Data([1]), filename: "IMG_0007.MOV", type: nil, in: tempDir()))
        XCTAssertEqual(item.kind, "video")
    }

    func testAVideoFileIsCopiedNotLoaded() throws {
        let src = tempDir().appendingPathComponent("clip.mov")
        try Data([9, 9, 9]).write(to: src)
        let item = try XCTUnwrap(HoloScreenPhoto.onScreenItem(file: src, filename: "IMG_0008.MOV", type: .quickTimeMovie, in: tempDir()))
        guard case .file(let url, _, _, let kind) = item else { return XCTFail("not a file") }
        XCTAssertEqual(kind, "video")
        XCTAssertEqual(try Data(contentsOf: url), Data([9, 9, 9]))
    }

    func testAnUnnamedPhotoGetsAName() throws {
        let item = try XCTUnwrap(HoloScreenPhoto.onScreenItem(data: Data([1]), filename: "", type: .jpeg, in: tempDir()))
        XCTAssertEqual(item.caption, "Photo.jpeg")
    }

    /// Safari, Maps and the rest hand over pages and places: those go the screenshot way.
    func testOtherOnScreenContentIsIgnored() {
        XCTAssertNil(HoloScreenPhoto.onScreenItem(data: Data("<html>".utf8), filename: "Page.html", type: .html, in: tempDir()))
        XCTAssertNil(HoloScreenPhoto.onScreenItem(data: Data("https://a.b".utf8), filename: "a.b", type: .url, in: tempDir()))
        XCTAssertNil(HoloScreenPhoto.onScreenItem(data: Data(), filename: "IMG_1.JPG", type: .jpeg, in: tempDir()))
    }
}
