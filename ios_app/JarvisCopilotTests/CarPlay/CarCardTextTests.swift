import XCTest
@testable import JarvisCopilot

/// What the CarPlay card (the Live Activity's small layout) and the Talk widget say:
/// his words while he talks, then Jarvis's reply.
final class CarCardTextTests: XCTestCase {

    func testListeningAndThinkingShowHisWords() {
        XCTAssertEqual(CarCardText.line(state: "listening", transcript: "how hot is it", activity: ""),
                       "how hot is it")
        XCTAssertEqual(CarCardText.line(state: "thinking", transcript: "how hot is it",
                                        activity: "Searching the web…"),
                       "how hot is it")
    }

    func testSpeakingShowsTheReply() {
        XCTAssertEqual(CarCardText.line(state: "speaking", transcript: "how hot is it",
                                        activity: "It's 72 degrees."),
                       "It's 72 degrees.")
    }

    func testIdleShowsAHeldReply() {
        XCTAssertEqual(CarCardText.line(state: "idle", transcript: "how hot is it",
                                        activity: "It's 72 degrees."),
                       "It's 72 degrees.")
        XCTAssertEqual(CarCardText.line(state: "idle", transcript: "", activity: ""), "")
    }

    func testErrorShowsTheMessage() {
        XCTAssertEqual(CarCardText.line(state: "error", transcript: "hi",
                                        activity: "Allow the microphone on your iPhone"),
                       "Allow the microphone on your iPhone")
    }

    func testTitles() {
        XCTAssertEqual(CarCardText.title(state: "listening"), "Listening…")
        XCTAssertEqual(CarCardText.title(state: "thinking"), "Thinking…")
        XCTAssertEqual(CarCardText.title(state: "speaking"), "Speaking")
        XCTAssertEqual(CarCardText.title(state: "error"), "Error")
        XCTAssertEqual(CarCardText.title(state: "idle"), "Talk to Jarvis")
    }

    func testLongLinesAreCapped() {
        let long = String(repeating: "word ", count: 60)
        XCTAssertLessThanOrEqual(CarCardText.line(state: "speaking", transcript: "", activity: long).count,
                                 CarCardText.lineLimit + 1)
    }
}
