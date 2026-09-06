import XCTest
@testable import JarvisCopilot

/// The Flutter app rendered PTY output with xterm; we only have a line buffer,
/// so these lock down the VT100 subset it must get right.
final class TerminalBufferTests: XCTestCase {

    private func buf(rows: Int = 24, cols: Int = 80, maxLines: Int = 2000) -> TerminalBuffer {
        TerminalBuffer(rows: rows, cols: cols, maxLines: maxLines)
    }

    // MARK: plain text / newlines

    func testPlainTextAccumulatesOnOneLine() {
        var b = buf()
        b.write("hel")
        b.write("lo")
        XCTAssertEqual(b.text, "hello")
        XCTAssertEqual(b.lines, ["hello"])
    }

    func testLineFeedStartsANewLine() {
        var b = buf()
        b.write("a\nb")
        XCTAssertEqual(b.lines, ["a", "b"])
    }

    func testCRLFDoesNotProduceABlankLine() {
        var b = buf()
        b.write("a\r\nb\r\n")
        XCTAssertEqual(b.lines, ["a", "b", ""])
        XCTAssertEqual(b.text, "a\nb\n")
    }

    // MARK: carriage return (progress bars redraw with it)

    func testCarriageReturnOverwritesFromColumnZero() {
        var b = buf()
        b.write("12345\rab")
        XCTAssertEqual(b.lines, ["ab345"])
    }

    // MARK: backspace

    func testBackspaceMovesBackAndOverwrites() {
        var b = buf()
        b.write("abc\u{8}d")
        XCTAssertEqual(b.lines, ["abd"])
    }

    func testBackspaceSpaceBackspaceErasesTheLastCharacter() {
        var b = buf()
        b.write("abc\u{8} \u{8}")
        XCTAssertEqual(b.lines, ["ab"])  // trailing blank cells are trimmed
    }

    func testBackspaceAtColumnZeroIsIgnored() {
        var b = buf()
        b.write("\u{8}\u{8}x")
        XCTAssertEqual(b.lines, ["x"])
    }

    // MARK: escape stripping

    func testSGRColourSequencesAreStripped() {
        var b = buf()
        b.write("\u{1b}[90m[detached — reopen]\u{1b}[0m")
        XCTAssertEqual(b.lines, ["[detached — reopen]"])
    }

    func testCursorPositioningCSIIsStripped() {
        var b = buf()
        b.write("a\u{1b}[2;5Hb\u{1b}[?25lc")
        XCTAssertEqual(b.lines, ["abc"])
    }

    func testOSCTitleTerminatedByBELIsStripped() {
        var b = buf()
        b.write("\u{1b}]0;pranav@mac: ~/code\u{7}prompt$ ")
        XCTAssertEqual(b.lines, ["prompt$"])
    }

    func testOSCTitleTerminatedByStringTerminatorIsStripped() {
        var b = buf()
        b.write("\u{1b}]0;title\u{1b}\\after")
        XCTAssertEqual(b.lines, ["after"])
    }

    func testTwoCharacterAndCharsetEscapesAreStripped() {
        var b = buf()
        b.write("\u{1b}(Bx\u{1b}=y\u{1b}>z")
        XCTAssertEqual(b.lines, ["xyz"])
    }

    func testEscapeSplitAcrossTwoWritesIsStillStripped() {
        var b = buf()
        b.write("a\u{1b}[3")
        b.write("1mb")
        XCTAssertEqual(b.lines, ["ab"])
    }

    // MARK: the two erase ops that matter for readability

    func testEraseInLineTruncatesAtTheCursor() {
        var b = buf()
        b.write("abcdef\r12\u{1b}[K")
        XCTAssertEqual(b.lines, ["12"])
    }

    func testEraseInLineToStartBlanksThroughTheCursor() {
        var b = buf()
        // ESC[3C walks the cursor to column 3; ESC[1K blanks 0…3 *inclusive*
        // (xterm's "erase to left" includes the cursor cell).
        b.write("abcdef\r\u{1b}[3C\u{1b}[1K")
        XCTAssertEqual(b.lines, ["    ef"])
    }

    func testEraseDisplayClearsTheBuffer() {
        var b = buf()
        b.write("old\nlines\n\u{1b}[2Jfresh")
        XCTAssertEqual(b.lines, ["fresh"])
    }

    // MARK: tabs

    func testTabAdvancesToTheNextEightColumnStop() {
        var b = buf()
        b.write("ab\tc")
        XCTAssertEqual(b.lines, ["ab      c"])
    }

    // MARK: wrapping + resize

    func testWrapIsDeferredSoAFullWidthLinePlusNewlineStaysOneLine() {
        var b = buf(cols: 4)
        b.write("abcd\r\n")
        XCTAssertEqual(b.lines, ["abcd", ""])
    }

    func testWritingPastTheRightMarginWraps() {
        var b = buf(cols: 4)
        b.write("abcde")
        XCTAssertEqual(b.lines, ["abcd", "e"])
    }

    func testResizeChangesTheWrapWidth() {
        var b = buf(cols: 4)
        b.resize(rows: 10, cols: 6)
        XCTAssertEqual(b.cols, 6)
        XCTAssertEqual(b.rows, 10)
        b.write("abcdef")
        XCTAssertEqual(b.lines, ["abcdef"])
        b.write("g")
        XCTAssertEqual(b.lines, ["abcdef", "g"])
    }

    func testResizeIgnoresNonsenseDimensions() {
        var b = buf(cols: 80, maxLines: 10)
        b.resize(rows: 0, cols: -3)
        XCTAssertEqual(b.cols, 80)
        XCTAssertEqual(b.rows, 24)
    }

    // MARK: scrollback cap + clear

    func testScrollbackIsCappedAtMaxLines() {
        var b = buf(maxLines: 3)
        b.write("1\n2\n3\n4\n5")
        XCTAssertEqual(b.lines, ["3", "4", "5"])
    }

    func testClearEmptiesTheBuffer() {
        var b = buf()
        b.write("stuff\nmore")
        b.clear()
        XCTAssertEqual(b.lines, [""])
        XCTAssertEqual(b.text, "")
    }

    // MARK: rendered-line cache + stable ids

    func testTheRenderedLineIsRefreshedAfterEveryWrite() {
        var b = buf()
        b.write("abc")
        XCTAssertEqual(b.displayLines.map(\.text), ["abc"])
        // Reading `lines`/`displayLines` must not freeze the cache: the next
        // write has to show through it.
        b.write("de")
        XCTAssertEqual(b.displayLines.map(\.text), ["abcde"])
        b.write("\rxy")
        XCTAssertEqual(b.displayLines.map(\.text), ["xycde"])
        XCTAssertEqual(b.lines, b.displayLines.map(\.text), "both views agree")
    }

    func testDisplayLineIdsAreStableAndMonotonic() {
        var b = buf()
        b.write("one\ntwo")
        XCTAssertEqual(b.displayLines.map(\.id), [0, 1])
        // Appending to the live line keeps every id, including its own.
        b.write("!")
        XCTAssertEqual(b.displayLines.map(\.id), [0, 1])
        XCTAssertEqual(b.displayLines.map(\.text), ["one", "two!"])
        b.write("\nthree")
        XCTAssertEqual(b.displayLines.map(\.id), [0, 1, 2])
    }

    func testLineIdsSurviveScrollbackEvictionAndAreNeverReused() {
        var b = buf(maxLines: 3)
        b.write("1\n2\n3\n4\n5")
        XCTAssertEqual(b.lines, ["3", "4", "5"])
        // The surviving rows keep the ids they were born with — an offset key
        // would have renamed all three.
        XCTAssertEqual(b.displayLines.map(\.id), [2, 3, 4])
        b.write("\n6")
        XCTAssertEqual(b.displayLines.map(\.id), [3, 4, 5])

        // A full repaint (ESC[2J) also hands out a fresh id rather than
        // resurrecting one still on screen.
        let seen = Set(b.displayLines.map(\.id))
        b.write("\u{1b}[2Jfresh")
        XCTAssertEqual(b.lines, ["fresh"])
        XCTAssertTrue(seen.isDisjoint(with: b.displayLines.map(\.id)))
    }

    func testClearResetsToASingleEmptyLine() {
        var b = buf()
        b.write("stuff\nmore")
        XCTAssertFalse(b.isEmpty)
        b.clear()
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.displayLines.count, 1)
        XCTAssertEqual(b.displayLines[0].text, "")
    }

    // MARK: other control bytes

    func testBellAndDeleteAreIgnored() {
        var b = buf()
        b.write("a\u{7}b\u{7f}c")
        XCTAssertEqual(b.lines, ["abc"])
    }
}
