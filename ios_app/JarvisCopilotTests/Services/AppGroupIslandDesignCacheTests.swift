import Foundation
import XCTest
@testable import JarvisCopilot

/// The App Group design cache: the app writes `island/design-<id>.json`, the
/// widget extension (a separate process) reads it. Exercised against a temp
/// directory standing in for the App Group container.
final class AppGroupIslandDesignCacheTests: XCTestCase {

    private var container: URL!

    override func setUpWithError() throws {
        container = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("island-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func makeCache(images: RecordingImagePrefetcher? = nil) -> AppGroupIslandDesignCache {
        AppGroupIslandDesignCache(container: container, images: images)
    }

    func testADesignRoundTripsThroughTheContainer() async {
        let cache = makeCache()
        let json = #"{"id":"flight","root":{"type":"text","value":"BA 117"}}"#
        await cache.cacheDesigns([["id": "flight", "version": 3, "json": json]])

        XCTAssertEqual(cache.cachedJSON(id: "flight"), json)
        let file = container.appendingPathComponent("island/design-flight.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the widget reads this exact path from its own process")
    }

    func testTheFileNameMatchesWhatTheWidgetLooksFor() {
        XCTAssertEqual(JarvisShared.designFileName("flight"), "design-flight.json")
    }

    func testACraftedIdCannotEscapeTheIslandDirectory() async {
        let cache = makeCache()
        await cache.cacheDesigns([["id": "../../evil", "version": 1, "json": "{}"]])

        let escaped = container.deletingLastPathComponent()
            .appendingPathComponent("design-evil.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: container.appendingPathComponent("island").path)
        XCTAssertEqual(contents?.count, 1)
        XCTAssertFalse(contents?.first?.contains("/") ?? true)
    }

    func testARewriteReplacesTheStoredTree() async {
        let cache = makeCache()
        await cache.cacheDesigns([["id": "d", "version": 1, "json": #"{"v":1}"#]])
        await cache.cacheDesigns([["id": "d", "version": 2, "json": #"{"v":2}"#]])
        XCTAssertEqual(cache.cachedJSON(id: "d"), #"{"v":2}"#)
    }

    func testClearRemovesEveryCachedDesign() async {
        let cache = makeCache()
        await cache.cacheDesigns([["id": "a", "version": 1, "json": "{}"],
                                  ["id": "b", "version": 1, "json": "{}"]])
        await cache.clearCache()
        XCTAssertNil(cache.cachedJSON(id: "a"))
        XCTAssertNil(cache.cachedJSON(id: "b"))
    }

    func testMalformedPayloadsAreSkippedNotFatal() async {
        let cache = makeCache()
        await cache.cacheDesigns([
            ["version": 1, "json": "{}"],            // no id
            ["id": "", "json": "{}"],                // empty id
            ["id": "good", "json": #"{"ok":true}"#],
        ])
        XCTAssertEqual(cache.cachedJSON(id: "good"), #"{"ok":true}"#)
    }

    func testNoAppGroupContainerIsASilentNoOp() async {
        // A build without the entitlement gets nil from `containerURL`. That must
        // degrade to "no custom designs", never a crash.
        let cache = AppGroupIslandDesignCache(container: nil, images: nil)
        await cache.cacheDesigns([["id": "x", "json": "{}"]])
        await cache.clearCache()
        XCTAssertNil(cache.cachedJSON(id: "x"))
    }

    func testRemoteImagesInADesignArePrefetchedForTheWidget() async {
        let images = RecordingImagePrefetcher()
        let cache = makeCache(images: images)
        let json = #"{"root":{"type":"image","source":"https://cdn.example.com/ba.png"}}"#
        await cache.cacheDesigns([["id": "flight", "json": json]])
        XCTAssertEqual(images.urls, ["https://cdn.example.com/ba.png"],
                       "the widget cannot fetch at render time")
    }

    /// A design tree only yields an image node's `source`. Harvesting every
    /// http(s) string in the document turned any URL a payload happened to
    /// mention — a link in a label, a webhook in a condition — into a request
    /// from the phone.
    func testDesignHarvestingTakesOnlyImageSourceProps() {
        let json = """
        {"root":{"type":"vstack","children":[
          {"type":"image","source":"https://cdn/1.png"},
          {"type":"text","value":"https://tracker/beacon.gif"},
          {"type":"image","source":"http://cdn/plain.png"}
        ]},"webhook":"https://evil/exfil"}
        """
        XCTAssertEqual(IslandImageCache.urls(inDesign: json), ["https://cdn/1.png"],
                       "only `source`, and only https")
        XCTAssertTrue(IslandImageCache.urls(inDesign: "").isEmpty)
        XCTAssertTrue(IslandImageCache.urls(inDesign: "not json").isEmpty)
    }

    func testDesignHarvestingWalksNestedSourcesAndArrays() {
        let json = #"{"a":{"b":{"source":"https://x/1.png"}},"c":{"source":["https://x/2.png"]}}"#
        XCTAssertEqual(Set(IslandImageCache.urls(inDesign: json)),
                       ["https://x/1.png", "https://x/2.png"])
    }

    /// The pushed data payload is `sourceKey: value` — a design binds an image's
    /// `source` to one of these keys BY NAME, so the key carries no type
    /// information and the https rule is what bounds it.
    func testDataHarvestingTakesEveryHTTPSValueButStillRefusesPlaintext() {
        let json = #"{"photo.url":"https://cdn/1.png","legacy":"http://cdn/2.png","x":"nope"}"#
        XCTAssertEqual(IslandImageCache.urls(inData: json), ["https://cdn/1.png"])
    }

    func testOnlyHTTPSURLsWithAHostAreFetchable() {
        XCTAssertTrue(IslandImageCache.isFetchable("https://cdn.example.com/a.png"))
        XCTAssertFalse(IslandImageCache.isFetchable("http://cdn.example.com/a.png"))
        XCTAssertFalse(IslandImageCache.isFetchable("https://"))
        XCTAssertFalse(IslandImageCache.isFetchable("file:///etc/passwd"))
        XCTAssertFalse(IslandImageCache.isFetchable("not a url"))
    }

    func testImageFileNamesAreAStableContentHash() {
        let first = IslandImageCache.fileName(for: "https://x/1.png")
        XCTAssertEqual(first, IslandImageCache.fileName(for: "https://x/1.png"))
        XCTAssertNotEqual(first, IslandImageCache.fileName(for: "https://x/2.png"))
        XCTAssertEqual(first.count, 64, "sha256 hex — the widget derives the same name")
    }

    func testTheSyncOnlyRePushesChangedDesigns() async {
        let recording = RecordingIslandCache()
        let sync = IslandSync(cache: recording)
        let design = IslandDesign(json: ["id": "d", "version": 1, "root": ["type": "text"]])

        await sync.sync([design])
        XCTAssertEqual(recording.cached.count, 1)
        await sync.sync([design])
        XCTAssertEqual(recording.cached.count, 1, "a steady catalog produces no writes")
    }
}
