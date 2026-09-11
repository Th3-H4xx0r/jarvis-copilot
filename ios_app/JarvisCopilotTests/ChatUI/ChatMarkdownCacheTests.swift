import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The memo in front of the markdown renderer and the link policy the
/// transcript applies on tap.
final class ChatMarkdownCacheTests: XCTestCase {

    func testBlocksAreParsedOnceAndKeyedOnTheText() {
        let text = "# Title\n\nsome **bold** prose\n\n```swift\nlet x = 1\n```"
        let first = ChatMarkdownCache.blocks(for: text)
        XCTAssertEqual(first, MarkdownBlocks.split(text), "memoising must not change the result")
        XCTAssertEqual(ChatMarkdownCache.blocks(for: text), first)
    }

    func testInlineMarkdownIsMemoisedAndStillStylesCode() {
        let text = "call `foo()` now"
        let attributed = chatInlineMarkdown(text)
        XCTAssertEqual(String(attributed.characters), "call foo() now")
        XCTAssertTrue(attributed.runs.contains { $0.font != nil }, "inline code keeps its monospaced run")
        XCTAssertEqual(String(chatInlineMarkdown(text).characters), String(attributed.characters))
    }

    func testUnparseableInlineMarkdownStillRendersAsPlainText() {
        let half = "a **half written"
        XCTAssertEqual(String(chatInlineMarkdown(half).characters).contains("half written"), true)
    }

    func testEmptyTextIsHandled() {
        XCTAssertEqual(ChatMarkdownCache.blocks(for: ""), [])
        XCTAssertEqual(String(chatInlineMarkdown("").characters), "")
    }
}

final class ChatLinkPolicyTests: XCTestCase {

    func testWebAndMailLinksOpenWithoutAPrompt() {
        for raw in ["https://example.com/x", "http://example.com", "HTTPS://Example.com", "mailto:a@b.c"] {
            XCTAssertTrue(ChatLinkPolicy.isAllowed(URL(string: raw)!), raw)
        }
    }

    /// The whole point: a model-authored link must not be able to fire an app
    /// action on one tap.
    func testEverythingElseHasToBeConfirmed() {
        for raw in ["shortcuts://run-shortcut?name=Wipe",
                    "jarviscopilot://pair?token=x",
                    "App-Prefs:root=General",
                    "tel:+15550100",
                    "file:///etc/passwd",
                    "sms:+15550100",
                    "/etc/passwd"] {
            XCTAssertFalse(ChatLinkPolicy.isAllowed(URL(string: raw)!), raw)
        }
    }

    func testTheConfirmationLineNamesTheSchemeAndClipsTheURL() {
        let url = URL(string: "shortcuts://run-shortcut?name=" + String(repeating: "x", count: 300))!
        let line = ChatLinkPolicy.confirmation(for: url)
        XCTAssertTrue(line.contains("shortcuts"), line)
        XCTAssertTrue(line.hasSuffix("…"), "a 300-character URL must not push the buttons off screen")
        XCTAssertLessThan(line.count, 200)
    }
}
