import XCTest
@testable import JarvisCopilot

/// Case-for-case port of `mobile_client/test/voice/device_icon_test.dart`.
final class DeviceIconTests: XCTestCase {

    // MARK: - Real /api/devices records

    func testBrowserSessionOnAMacBookIsLaptopByName() {
        XCTAssertEqual(deviceIconKind([
            "kind": "browser",
            "name": "Pranav's Macbook WebUI Remote",
            "user_agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) Chrome/124",
        ]), "laptop")
    }

    func testNativeDesktopAgentOnAMacBookIsLaptop() {
        XCTAssertEqual(
            deviceIconKind(["kind": "desktop", "name": "Pranavs-MacBook-Pro.local"]),
            "laptop")
    }

    func testMobileIosIsPhone() {
        XCTAssertEqual(deviceIconKind(["kind": "mobile-ios", "name": "iPhone"]), "phone")
    }

    func testMobileAndroidIsPhone() {
        XCTAssertEqual(deviceIconKind(["kind": "mobile-android", "name": "Pixel 9"]), "phone")
    }

    // MARK: - Derivation from user_agent

    func testBrowserOnWindowsIsDesktop() {
        XCTAssertEqual(deviceIconKind([
            "kind": "browser",
            "name": "Chrome",
            "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64) Chrome/124",
        ]), "desktop")
    }

    func testGenericBrowserWithNoHintsIsWeb() {
        XCTAssertEqual(
            deviceIconKind(["kind": "browser", "name": "device", "user_agent": ""]),
            "web")
    }

    func testIMacDesktopKindIsDesktopNotLaptop() {
        XCTAssertEqual(deviceIconKind(["kind": "desktop", "name": "iMac"]), "desktop")
    }

    func testMacintoshUaWithNoMacbookIsLaptop() {
        XCTAssertEqual(
            deviceIconKind(["kind": "browser", "name": "Safari", "user_agent": "Macintosh"]),
            "laptop")
    }

    // MARK: - Fallbacks

    func testWatchInTheNameIsWatch() {
        XCTAssertEqual(deviceIconKind(["name": "My Apple Watch"]), "watch")
    }

    func testIPadIsTablet() {
        XCTAssertEqual(deviceIconKind(["kind": "mobile-ios", "name": "iPad Pro"]), "tablet")
    }

    func testUnknownRecordIsDesktopDefault() {
        XCTAssertEqual(deviceIconKind(["name": "", "user_agent": ""]), "desktop")
    }
}
