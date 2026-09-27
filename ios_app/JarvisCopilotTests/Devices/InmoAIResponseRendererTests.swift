import XCTest
@testable import JarvisCopilot

final class InmoAIResponseRendererTests: XCTestCase {
    private func content(_ payload: Data) throws -> [InmoWireField] {
        let chat = try InmoWireCodec.decode(payload)
        XCTAssertEqual(chat.map(\.number), [1, 3])
        XCTAssertEqual(chat.firstField(1)?.varint, 1)
        return try XCTUnwrap(chat.firstField(3)).nested()
    }

    func testAcknowledgementKeepsThinkingUntilServerCompletion() throws {
        var renderer = InmoAIResponseRenderer()
        let ack = try renderer.update(question: "Research this", answer: "On it.", finished: false, thinking: true)
        XCTAssertEqual(try content(ack.last!).firstField(5)?.varint, 1)
        XCTAssertEqual(try content(ack.last!).firstField(4)?.varint, 1)
        XCTAssertTrue(try renderer.update(question: "Research this", answer: "On it.", finished: false, thinking: true).isEmpty)
        let final = try renderer.update(question: "Research this", answer: "On it. Done.", finished: true, thinking: false)
        XCTAssertEqual(try final.map { try content($0).firstField(5)?.varint }, [3, 4, 5])
        XCTAssertEqual(try content(final[1]).firstField(2)?.bytes, Data(" Done.".utf8))
    }

    func testQuestionCreatesUserMessageThenAssistantPreparationExactlyOnce() throws {
        var renderer = InmoAIResponseRenderer()
        XCTAssertTrue(try renderer.update(question: "", answer: "", finished: false).isEmpty)
        let messages = try renderer.update(question: "Why?", answer: "", finished: false)
        XCTAssertEqual(messages.count, 2)
        let user = try content(messages[0])
        XCTAssertEqual(user.map(\.number), [2], "default user role and old state must be omitted")
        XCTAssertEqual(user.firstField(2)?.bytes, Data("Why?".utf8))
        let prepared = try content(messages[1])
        XCTAssertEqual(prepared.map(\.number), [1, 5])
        XCTAssertEqual(prepared.firstField(1)?.varint, 1)
        XCTAssertEqual(prepared.firstField(5)?.varint, 6)
        XCTAssertTrue(try renderer.update(question: "Why?", answer: "", finished: false).isEmpty)
    }

    func testStreamingSendsOnlyNewTextAndFlushesBeforeCompletion() throws {
        var renderer = InmoAIResponseRenderer()
        let first = try renderer.update(question: "Test", answer: "Hello", finished: false)
        XCTAssertEqual(first.count, 3)
        let firstAnswer = try content(first[2])
        XCTAssertEqual(firstAnswer.map(\.number), [1, 2, 5])
        XCTAssertEqual(firstAnswer.firstField(1)?.varint, 1)
        XCTAssertEqual(firstAnswer.firstField(2)?.bytes, Data("Hello".utf8))
        XCTAssertEqual(firstAnswer.firstField(5)?.varint, 4)
        XCTAssertTrue(try renderer.update(question: "Test", answer: "Hello", finished: false).isEmpty)
        let final = try renderer.update(question: "Test", answer: "Hello 🌍!", finished: true)
        XCTAssertEqual(final.count, 2)
        XCTAssertEqual(try content(final[0]).firstField(2)?.bytes, Data(" 🌍!".utf8))
        let end = try content(final[1])
        XCTAssertEqual(end.map(\.number), [1, 5])
        XCTAssertEqual(end.firstField(5)?.varint, 5)
        XCTAssertTrue(try renderer.update(question: "Test", answer: "Hello 🌍!", finished: true).isEmpty)
    }

    func testCompletionWithoutAnswerNeverSendsEmptyText() throws {
        var renderer = InmoAIResponseRenderer()
        let messages = try renderer.update(question: "Test", answer: "", finished: true)
        XCTAssertEqual(messages.count, 3)
        XCTAssertNil(try content(messages[2]).firstField(2))
        XCTAssertEqual(try content(messages[2]).firstField(5)?.varint, 5)
        XCTAssertTrue(try renderer.update(question: "Test", answer: "", finished: true).isEmpty)
    }

    func testReplacementRejectsWithoutAdvancingSentText() throws {
        var renderer = InmoAIResponseRenderer()
        _ = try renderer.update(question: "Test", answer: "Hello", finished: false)
        XCTAssertThrowsError(try renderer.update(question: "Test", answer: "Goodbye", finished: true))
        let next = try renderer.update(question: "Test", answer: "Hello!", finished: true)
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(try content(next[0]).firstField(2)?.bytes, Data("!".utf8))
    }

    func testNewQuestionRequiresFreshRenderer() throws {
        var renderer = InmoAIResponseRenderer()
        _ = try renderer.update(question: "First", answer: "", finished: false)
        XCTAssertThrowsError(try renderer.update(question: "Second", answer: "Reply", finished: false))
        let next = try renderer.update(question: "First", answer: "Reply", finished: false)
        XCTAssertEqual(next.count, 1)
    }
}
