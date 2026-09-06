import XCTest
@testable import JarvisCopilot

/// A markdown link in a coding transcript is model/tool output — i.e. it can be
/// whatever a file Claude just read says it is. Only web/mail schemes may reach
/// the system unattended.
final class CodingLinkPolicyTests: XCTestCase {

    func testWebAndMailLinksOpenDirectly() throws {
        for s in ["https://example.com/x?y=1",
                  "http://192.168.1.10:8080/logs",
                  "mailto:someone@example.com?subject=hi",
                  "HTTPS://EXAMPLE.COM"] {
            let url = try XCTUnwrap(URL(string: s))
            XCTAssertTrue(CodingLinkPolicy.opensDirectly(url), s)
        }
    }

    func testEverythingElseHasToBeConfirmed() throws {
        for s in ["shortcuts://run-shortcut?name=Wipe",   // routes round the skills switch
                  "App-Prefs:root=General",
                  "jarviscopilot://pair?token=abc",     // our own deep links
                  "tel:+15551234567",
                  "sms:+15551234567&body=hi",
                  "file:///etc/passwd",
                  "javascript:alert(1)",
                  "itms-apps://apps.apple.com/app/id1"] {
            let url = try XCTUnwrap(URL(string: s))
            XCTAssertFalse(CodingLinkPolicy.opensDirectly(url), s)
        }
    }

    func testASchemelessLinkIsNeverOpenedUnattended() throws {
        let url = try XCTUnwrap(URL(string: "/etc/passwd"))
        XCTAssertNil(url.scheme)
        XCTAssertFalse(CodingLinkPolicy.opensDirectly(url))
    }
}
