import XCTest
@testable import Jarvis

/// Apple Mail through AppleScript: the inbox listing parses, strings are
/// escaped before they go into a script, and compose builds the right script.
final class MailTests: XCTestCase {

    func testEscapingKeepsQuotesAndBackslashesInside() {
        XCTAssertEqual(MailScript.quote(#"He said "hi" \ bye"#), #""He said \"hi\" \\ bye""#)
        XCTAssertEqual(MailScript.quote("line1\nline2"), "\"line1\" & linefeed & \"line2\"")
    }

    func testInboxListingParses() {
        let rs = "\u{1E}", us = "\u{1F}"
        let raw = "3" + rs
            + ["101", "false", "Ada <ada@example.com>", "Invoice", "2026-10-14T09:30:00"].joined(separator: us) + rs
            + ["102", "true", "bob@example.com", "Lunch?", "2026-10-13T12:00:00"].joined(separator: us) + rs
            + "garbage" + rs
        let inbox = MailInbox.parse(raw)
        XCTAssertEqual(inbox.unread, 3)
        XCTAssertEqual(inbox.messages.map(\.id), [101, 102])
        XCTAssertEqual(inbox.messages[0].isRead, false)
        XCTAssertEqual(inbox.messages[0].senderName, "Ada")
        XCTAssertEqual(inbox.messages[1].senderName, "bob@example.com")
        XCTAssertEqual(inbox.messages[0].subject, "Invoice")
        XCTAssertNotNil(inbox.messages[0].received)
        XCTAssertEqual(MailInbox.parse("").messages, [])
    }

    func testMessageActionsTargetOneMessageById() {
        XCTAssertEqual(MailScript.markRead(101),
                       "tell application \"Mail\" to set read status of (first message of inbox whose id is 101) to true")
        XCTAssertTrue(MailScript.reply(7).contains("reply (first message of inbox whose id is 7) with opening window"))
    }

    func testComposeScriptAddsEveryRecipientAndSendsOnlyWhenAsked() {
        let s = MailScript.compose(to: ["a@x.com", "b@y.com"], subject: "Hi \"you\"", body: "Body", send: false)
        XCTAssertTrue(s.contains("subject:\"Hi \\\"you\\\"\""))
        XCTAssertTrue(s.contains("address:\"a@x.com\"") && s.contains("address:\"b@y.com\""))
        XCTAssertFalse(s.contains("send m"))
        XCTAssertTrue(MailScript.compose(to: ["a@x.com"], subject: "s", body: "b", send: true).contains("send m"))
    }

    func testRecipientsSplitOnCommasAndSpaces() {
        XCTAssertEqual(MailScript.recipients(" a@x.com, b@y.com;c@z.com "), ["a@x.com", "b@y.com", "c@z.com"])
        XCTAssertEqual(MailScript.recipients(""), [])
    }
}
