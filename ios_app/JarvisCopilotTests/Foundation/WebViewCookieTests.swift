import WebKit
import XCTest
@testable import JarvisCopilot

/// The webview boots authenticated only if the `hermes_session` cookie makes it
/// into WKWebView's cookie store. `apiAuthHeaders()` hands it to us as a single
/// `Cookie:` header, so parsing that header is the whole seam.
final class WebViewCookieTests: XCTestCase {

    func testParsesASingleCookie() {
        XCTAssertEqual(WebViewCookies.parse(header: "hermes_session=abc.def"),
                       [WebCookie(name: "hermes_session", value: "abc.def")])
    }

    func testParsesSeveralCookies() {
        XCTAssertEqual(WebViewCookies.parse(header: "hermes_session=abc; CF_Authorization=zzz"),
                       [WebCookie(name: "hermes_session", value: "abc"),
                        WebCookie(name: "CF_Authorization", value: "zzz")])
    }

    /// Session tokens are base64 and routinely end in `=` padding — splitting on
    /// every `=` instead of the first would truncate them.
    func testKeepsEqualsSignsInsideTheValue() {
        XCTAssertEqual(WebViewCookies.parse(header: "hermes_session=YWJj=="),
                       [WebCookie(name: "hermes_session", value: "YWJj==")])
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(WebViewCookies.parse(header: "  hermes_session = abc ; b=2 "),
                       [WebCookie(name: "hermes_session", value: "abc"),
                        WebCookie(name: "b", value: "2")])
    }

    func testDropsMalformedPairs() {
        XCTAssertEqual(WebViewCookies.parse(header: ""), [])
        XCTAssertEqual(WebViewCookies.parse(header: "   "), [])
        XCTAssertEqual(WebViewCookies.parse(header: "=orphan"), [])
        XCTAssertEqual(WebViewCookies.parse(header: "novalue"), [])
        XCTAssertEqual(WebViewCookies.parse(header: "; ; hermes_session=abc ;"),
                       [WebCookie(name: "hermes_session", value: "abc")])
    }

    func testEmptyValuesAreKeptBecauseTheyClearACookie() {
        XCTAssertEqual(WebViewCookies.parse(header: "hermes_session="),
                       [WebCookie(name: "hermes_session", value: "")])
    }

    // MARK: Splitting the auth headers

    func testPullsCookiesOutOfTheAuthHeaders() {
        let headers = ["Cookie": "hermes_session=abc",
                       "CF-Access-Client-Id": "xxxx.access",
                       "CF-Access-Client-Secret": "s3cret"]
        XCTAssertEqual(WebViewCookies.cookies(in: headers),
                       [WebCookie(name: "hermes_session", value: "abc")])
    }

    /// The CF service token has to ride on the top-level request as headers —
    /// Cloudflare then sets its own CF_Authorization cookie for subresources.
    func testKeepsTheCloudflareHeadersAndDropsTheCookieHeader() {
        let headers = ["Cookie": "hermes_session=abc",
                       "CF-Access-Client-Id": "xxxx.access",
                       "CF-Access-Client-Secret": "s3cret"]
        XCTAssertEqual(WebViewCookies.requestHeaders(in: headers),
                       ["CF-Access-Client-Id": "xxxx.access",
                        "CF-Access-Client-Secret": "s3cret"])
    }

    func testUnpairedDeviceYieldsNothing() {
        XCTAssertEqual(WebViewCookies.cookies(in: [:]), [])
        XCTAssertEqual(WebViewCookies.requestHeaders(in: [:]), [:])
    }

    // MARK: - Clearing on unpair (security M1 / swift-correctness H15)

    /// The webviews use a `.nonPersistent()` store now, but earlier builds wrote
    /// `hermes_session` into the shared on-disk one and Cloudflare's
    /// `CF_Authorization` can still land there via a redirect. Unpair has to
    /// clear ALL of it, not just cookies.
    func testEverythingWebKitCanHoldIsInTheClearSet() {
        let types = WebViewCookies.allDataTypes
        XCTAssertTrue(types.contains(WKWebsiteDataTypeCookies))
        XCTAssertTrue(types.contains(WKWebsiteDataTypeLocalStorage))
        XCTAssertTrue(types.contains(WKWebsiteDataTypeSessionStorage))
        XCTAssertTrue(types.contains(WKWebsiteDataTypeDiskCache))
        XCTAssertEqual(types, WKWebsiteDataStore.allWebsiteDataTypes())
    }

    /// `SettingsStore.unpair()` reaches WebKit through this. Asserted for real in
    /// `SettingsStoreTests.testUnpairClearsTheWebviewsWebsiteData` against a
    /// double; here we only prove the production path is callable and does not
    /// throw on a device with nothing stored.
    @MainActor
    func testClearingAnEmptyStoreIsHarmless() {
        WebViewCookies.clearAll()
    }
}
