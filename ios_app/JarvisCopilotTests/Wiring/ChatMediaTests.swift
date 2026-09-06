import XCTest
@testable import JarvisCopilot

/// The `MEDIA:<ref>` pre-pass `widgets/markdown_stream.dart` runs before
/// rendering, and the cookie-gated byte cache behind a chat image.
@MainActor
final class ChatMediaTests: XCTestCase {

    private let base = "https://jarvis.test"

    // MARK: rewrite

    func testTextWithoutMediaIsUntouched() {
        let text = "Here is a **bold** claim about media queries."
        XCTAssertEqual(ChatMedia.rewrite(text, base: base), text)
    }

    func testAnHttpRefBecomesAMarkdownImage() {
        let out = ChatMedia.rewrite("Done: MEDIA:https://cdn.test/a.png", base: base)
        XCTAssertEqual(out, "Done: ![image](https://cdn.test/a.png)")
    }

    /// Extensionless CDN paths still resolve, matching the web UI.
    func testAnExtensionlessHttpRefIsStillAnImage() {
        let out = ChatMedia.rewrite("MEDIA:https://cdn.test/render/9f2c", base: base)
        XCTAssertEqual(out, "![image](https://cdn.test/render/9f2c)")
    }

    func testALocalImagePathGoesThroughTheCookieGatedMediaEndpoint() {
        let out = ChatMedia.rewrite("MEDIA:/tmp/a&b.png", base: base)
        XCTAssertEqual(out, "![image](https://jarvis.test/api/media?path=%2Ftmp%2Fa%26b.png)",
                       "the ref is a query VALUE; an unescaped & would truncate it")
    }

    /// The ref stops at whitespace, so a path with a space is not a ref at all —
    /// same as the Flutter regex, and better than half-swallowing the sentence.
    func testARefWithASpaceIsNotRewritten() {
        XCTAssertEqual(ChatMedia.rewrite("MEDIA:/tmp/out 1.png", base: base), "/tmp/out 1.png")
    }

    func testAQueryStringDoesNotHideTheExtension() {
        let out = ChatMedia.rewrite("MEDIA:/tmp/a.jpg?w=512", base: base)
        XCTAssertTrue(out.hasPrefix("![image](https://jarvis.test/api/media?path="), out)
        XCTAssertTrue(out.contains("a.jpg%3Fw%3D512"), out)
    }

    /// A PDF rendered as a broken-image chip would be a lie — leave it as text.
    func testANonImageLocalRefIsLeftAsAPlainReference() {
        XCTAssertEqual(ChatMedia.rewrite("See MEDIA:/tmp/report.pdf now", base: base),
                       "See /tmp/report.pdf now")
    }

    /// "Stop at whitespace, `)` or `]`" — the ref must not swallow the markdown
    /// around it.
    func testTheRefStopsAtMarkdownPunctuation() {
        let out = ChatMedia.rewrite("(MEDIA:https://cdn.test/a.png) and more", base: base)
        XCTAssertEqual(out, "(![image](https://cdn.test/a.png)) and more")
    }

    func testSeveralRefsInOneReplyAreAllRewritten() {
        let out = ChatMedia.rewrite("MEDIA:https://a.test/1.png\nMEDIA:https://a.test/2.png",
                                    base: base)
        XCTAssertEqual(out, "![image](https://a.test/1.png)\n![image](https://a.test/2.png)")
    }

    func testABareMediaWordIsNotARef() {
        XCTAssertEqual(ChatMedia.rewrite("MEDIA: nothing here", base: base),
                       "MEDIA: nothing here")
    }

    /// Unpaired: the base is empty, which still leaves a root-relative URL the
    /// cache resolves through `JarvisAPI`.
    func testAnEmptyBaseLeavesARootRelativeURL() {
        XCTAssertEqual(ChatMedia.rewrite("MEDIA:/tmp/a.png", base: ""),
                       "![image](/api/media?path=%2Ftmp%2Fa.png)")
    }

    /// The rewritten image has to survive the block splitter as an image block,
    /// or the whole pre-pass buys nothing.
    func testARewrittenRefRendersAsAnImageBlock() {
        let blocks = MarkdownBlocks.split(
            ChatMedia.rewrite("MEDIA:https://cdn.test/a.png", base: base))
        guard case .image(_, let source)? = blocks.first else {
            return XCTFail("expected an image block, got \(blocks)")
        }
        XCTAssertEqual(source, "https://cdn.test/a.png")
    }

    // MARK: cache

    func testBytesAreFetchedThroughTheAPISoTheCookieGoesWithThem() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(text: "png-bytes", contentType: "image/png")
        let cache = ChatImageCache(api: api)

        let data = await cache.bytes("https://jarvis.test/api/media?path=/tmp/a.png")

        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "png-bytes")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Cookie"),
                       "hermes_session=abc", "/api/media is cookie-gated")
    }

    /// Scrolling a long thread must not refetch every image it passes.
    func testASecondReadIsServedFromTheCache() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(text: "bytes", contentType: "image/png")
        let cache = ChatImageCache(api: api)

        _ = await cache.bytes("https://jarvis.test/a.png")
        let again = await cache.bytes("https://jarvis.test/a.png")

        XCTAssertEqual(again.map { String(decoding: $0, as: UTF8.self) }, "bytes")
        XCTAssertEqual(transport.requests.count, 1, "one fetch per URL per launch")
    }

    func testAFailedFetchIsNilAndNotCached() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "nope"], status: 404)
        let cache = ChatImageCache(api: api)

        let data = await cache.bytes("https://jarvis.test/missing.png")
        XCTAssertNil(data, "the caller shows the broken-image chip")
        XCTAssertNil(cache.cached("https://jarvis.test/missing.png"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// A root-relative source goes through the paired base rather than being
    /// treated as an absolute URL (which would fail to parse a host).
    func testARelativeSourceIsResolvedAgainstThePairedBase() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(text: "x", contentType: "image/png")
        let cache = ChatImageCache(api: api)

        _ = await cache.bytes("/api/media?path=/tmp/a.png")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/media")
        XCTAssertEqual(transport.lastRequest?.url?.query, "path=/tmp/a.png",
                       "the query must survive: JarvisAPI.get would escape the ? into the path")
    }
}
