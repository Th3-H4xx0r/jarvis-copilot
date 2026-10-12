import XCTest
@testable import JarvisCopilot

/// Settings → Keep prompts cached on the phone: the same `/api/cache/config`
/// the web's block edits.
final class PromptCacheSettingsTests: XCTestCase {
    func testParsesTheServerAndDefaultsToLong() {
        XCTAssertEqual(PromptCacheRetention.from(["config": ["retention": "standard"]]), .standard)
        XCTAssertEqual(PromptCacheRetention.from(["config": ["retention": "long"]]), .long)
        XCTAssertEqual(PromptCacheRetention.from([:]), .long)
        XCTAssertEqual(PromptCacheRetention.from(["config": ["retention": "forever"]]), .long)
    }

    func testTheSaveBodyCarriesTheServersKey() {
        XCTAssertEqual(PromptCacheAPI.body(for: .standard)["retention"] as? String, "standard")
        XCTAssertEqual(PromptCacheAPI.body(for: .long)["retention"] as? String, "long")
    }
}
