import XCTest
@testable import JarvisCopilot

/// The pure block splitter behind the streaming markdown renderer. Ported from
/// the cases `widgets/markdown_stream.dart` has to survive mid-stream: a fence
/// that hasn't closed yet, a heading arriving one character at a time, lists
/// that nest.
final class MarkdownBlocksTests: XCTestCase {

    // MARK: Headings

    func testHeadingLevelsAndText() {
        let blocks = MarkdownBlocks.split("# Title\n## Sub\n###### Deep")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Sub"),
            .heading(level: 6, text: "Deep"),
        ])
    }

    func testHeadingClampsAtSixHashes() {
        // Seven hashes is not a heading in CommonMark — it stays prose.
        XCTAssertEqual(MarkdownBlocks.split("####### nope"), [.paragraph("####### nope")])
    }

    func testHeadingStripsClosingHashes() {
        XCTAssertEqual(MarkdownBlocks.split("## Middle ##"), [.heading(level: 2, text: "Middle")])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(MarkdownBlocks.split("#hashtag"), [.paragraph("#hashtag")])
    }

    // MARK: Paragraphs

    func testBlankLineSeparatesParagraphs() {
        let blocks = MarkdownBlocks.split("one\ntwo\n\nthree")
        XCTAssertEqual(blocks, [.paragraph("one\ntwo"), .paragraph("three")])
    }

    func testEmptyInputProducesNothing() {
        XCTAssertEqual(MarkdownBlocks.split(""), [])
        XCTAssertEqual(MarkdownBlocks.split("   \n\n  "), [])
    }

    func testInlineCodeStaysInsideTheParagraph() {
        // A single backtick run is inline styling, NOT a fence: it must not open
        // a code block or be stripped — `AttributedString(markdown:)` styles it.
        let blocks = MarkdownBlocks.split("Call `foo(bar)` then `baz`.")
        XCTAssertEqual(blocks, [.paragraph("Call `foo(bar)` then `baz`.")])
    }

    // MARK: Fenced code

    func testFencedCodeWithLanguage() {
        let blocks = MarkdownBlocks.split("before\n\n```swift\nlet x = 1\nprint(x)\n```\nafter")
        XCTAssertEqual(blocks, [
            .paragraph("before"),
            .code(language: "swift", text: "let x = 1\nprint(x)", closed: true),
            .paragraph("after"),
        ])
    }

    func testFencedCodeWithoutLanguage() {
        XCTAssertEqual(MarkdownBlocks.split("```\nplain\n```"),
                       [.code(language: "", text: "plain", closed: true)])
    }

    func testUnterminatedFenceWhileStreaming() {
        // Half a code block has arrived. It renders as code (not as prose) and
        // reports itself open so the view can keep the caret/eliding subtle.
        let blocks = MarkdownBlocks.split("Here:\n```python\nprint(\"hi\")")
        XCTAssertEqual(blocks, [
            .paragraph("Here:"),
            .code(language: "python", text: "print(\"hi\")", closed: false),
        ])
    }

    func testFenceOpenedWithNothingAfterItYet() {
        XCTAssertEqual(MarkdownBlocks.split("```json"),
                       [.code(language: "json", text: "", closed: false)])
    }

    func testCodeBlockKeepsMarkdownSyntaxVerbatim() {
        let blocks = MarkdownBlocks.split("```\n# not a heading\n- not a list\n```")
        XCTAssertEqual(blocks, [.code(language: "", text: "# not a heading\n- not a list", closed: true)])
    }

    func testCodeBlockKeepsItsOwnIndentation() {
        let blocks = MarkdownBlocks.split("```\nif x:\n    y()\n```")
        XCTAssertEqual(blocks, [.code(language: "", text: "if x:\n    y()", closed: true)])
    }

    func testTildeFence() {
        XCTAssertEqual(MarkdownBlocks.split("~~~sh\nls\n~~~"),
                       [.code(language: "sh", text: "ls", closed: true)])
    }

    // MARK: Lists

    func testBulletList() {
        let blocks = MarkdownBlocks.split("- one\n* two\n+ three")
        XCTAssertEqual(blocks, [.list([
            MarkdownListItem(marker: "•", depth: 0, text: "one", ordered: false),
            MarkdownListItem(marker: "•", depth: 0, text: "two", ordered: false),
            MarkdownListItem(marker: "•", depth: 0, text: "three", ordered: false),
        ])])
    }

    func testOrderedListKeepsAuthorNumbers() {
        let blocks = MarkdownBlocks.split("1. first\n2. second\n7) seventh")
        XCTAssertEqual(blocks, [.list([
            MarkdownListItem(marker: "1.", depth: 0, text: "first", ordered: true),
            MarkdownListItem(marker: "2.", depth: 0, text: "second", ordered: true),
            MarkdownListItem(marker: "7.", depth: 0, text: "seventh", ordered: true),
        ])])
    }

    func testNestedList() {
        let blocks = MarkdownBlocks.split("- top\n  - nested\n    1. deep\n- back")
        XCTAssertEqual(blocks, [.list([
            MarkdownListItem(marker: "•", depth: 0, text: "top", ordered: false),
            MarkdownListItem(marker: "•", depth: 1, text: "nested", ordered: false),
            MarkdownListItem(marker: "1.", depth: 2, text: "deep", ordered: true),
            MarkdownListItem(marker: "•", depth: 0, text: "back", ordered: false),
        ])])
    }

    func testBlankLineEndsTheList() {
        let blocks = MarkdownBlocks.split("- one\n\n- two")
        XCTAssertEqual(blocks, [
            .list([MarkdownListItem(marker: "•", depth: 0, text: "one", ordered: false)]),
            .list([MarkdownListItem(marker: "•", depth: 0, text: "two", ordered: false)]),
        ])
    }

    func testDashWithoutSpaceIsProseNotAList() {
        XCTAssertEqual(MarkdownBlocks.split("-3 degrees"), [.paragraph("-3 degrees")])
    }

    func testListAfterParagraphClosesIt() {
        let blocks = MarkdownBlocks.split("Steps:\n- one")
        XCTAssertEqual(blocks, [
            .paragraph("Steps:"),
            .list([MarkdownListItem(marker: "•", depth: 0, text: "one", ordered: false)]),
        ])
    }

    // MARK: Quotes, rules, images

    func testBlockquoteLinesJoin() {
        XCTAssertEqual(MarkdownBlocks.split("> one\n> two"), [.quote("one\ntwo")])
    }

    func testHorizontalRule() {
        XCTAssertEqual(MarkdownBlocks.split("a\n\n---\n\nb"),
                       [.paragraph("a"), .rule, .paragraph("b")])
    }

    func testStandaloneImageBecomesAnImageBlock() {
        let blocks = MarkdownBlocks.split("![a cat](data:image/png;base64,AAAA)")
        XCTAssertEqual(blocks, [.image(alt: "a cat", source: "data:image/png;base64,AAAA")])
    }

    func testInlineImageInsideProseStaysProse() {
        // Only a line that is *just* an image becomes an image block; anything
        // else keeps flowing as text so the sentence isn't torn apart.
        XCTAssertEqual(MarkdownBlocks.split("see ![a](b.png) here"),
                       [.paragraph("see ![a](b.png) here")])
    }

    // MARK: Streaming stability

    func testPrefixesOfAReplyNeverCrashAndAlwaysEndSensibly() {
        let full = "# Title\n\nSome **text** with `code`.\n\n- a\n- b\n\n```swift\nlet x = 1\n```\n\n> quote\n"
        for length in 0...full.count {
            let prefix = String(full.prefix(length))
            let blocks = MarkdownBlocks.split(prefix)
            // Nothing is ever dropped silently: a non-blank prefix always renders.
            if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                XCTAssertFalse(blocks.isEmpty, "no blocks for prefix of length \(length)")
            }
        }
    }

    // MARK: Tables

    func testPipeTableBecomesTableBlock() {
        let md = """
        Intro line.

        | | Even Realities G1 | Vuzix Z100 |
        |---|:---:|--:|
        | Price | $599 | $500 |
        | Weight | 44g | 36g |
        After.
        """
        let blocks = MarkdownBlocks.split(md)
        XCTAssertEqual(blocks.count, 3)
        guard case .table(let table) = blocks[1] else { return XCTFail("expected table, got \(blocks[1])") }
        XCTAssertEqual(table.header, ["", "Even Realities G1", "Vuzix Z100"])
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table.rows, [["Price", "$599", "$500"], ["Weight", "44g", "36g"]])
        XCTAssertEqual(blocks[2], .paragraph("After."))
    }

    func testHeaderWithoutDelimiterStaysProse() {
        // Mid-stream: the delimiter row hasn't arrived yet.
        XCTAssertEqual(MarkdownBlocks.split("| a | b |"), [.paragraph("| a | b |")])
    }

    func testShortRowIsPaddedAndEscapedPipeKept() {
        let md = "| a | b |\n|---|---|\n| x \\| y |"
        guard case .table(let table)? = MarkdownBlocks.split(md).first else { return XCTFail() }
        XCTAssertEqual(table.rows, [["x | y", ""]])
    }
}
