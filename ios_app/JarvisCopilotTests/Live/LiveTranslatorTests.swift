import XCTest
@testable import JarvisCopilot

/// Translating on the phone: the queueing, the grouping by language pair, and
/// above all what happens when it cannot.
///
/// The rules here matter more than the translating, because the server is the
/// fallback for every one of them — anything this drops without saying so is a
/// line that silently never gets its meaning.
@MainActor
final class LiveTranslatorTests: XCTestCase {

    /// A session that returns canned text, so none of this needs a device, a
    /// language pack, or a SwiftUI view.
    private struct FakeRunner: TranslationRunner {
        var answers: [String: String] = [:]
        var failure: Error?

        func translate(_ text: String) async throws -> String {
            if let failure { throw failure }
            return answers[text] ?? "translated: \(text)"
        }
    }

    private struct Boom: Error {}

    final class Box {
        var done: [(Int, String)] = []
        var gaveUp: [Int] = []
    }

    private func makeTranslator() -> (LiveTranslator, Box) {
        let translator = LiveTranslator()
        let box = Box()
        translator.target = "en"
        translator.onTranslated = { seq, text in box.done.append((seq, text)) }
        translator.onUnavailable = { seq in box.gaveUp.append(seq) }
        return (translator, box)
    }

    // MARK: - What it takes on

    func testAForeignUtteranceIsTranslated() async {
        let (translator, box) = makeTranslator()
        translator.request(seq: 4, text: "¿cómo estás?", source: "es")

        await translator.run(FakeRunner(answers: ["¿cómo estás?": "How are you?"]))

        XCTAssertEqual(box.done.map(\.0), [4])
        XCTAssertEqual(box.done.first?.1, "How are you?")
        XCTAssertTrue(box.gaveUp.isEmpty)
    }

    func testTextAlreadyInTheTargetLanguageIsNotSentAnywhere() {
        // The complaint in its own right: English was being "translated" into
        // English. The phone must not even queue it.
        let (translator, box) = makeTranslator()

        translator.request(seq: 1, text: "Hello, are you there?", source: "en-US")

        XCTAssertNil(translator.configuration, "nothing to do")
        XCTAssertEqual(box.gaveUp, [1])
    }

    func testAnUnlabelledUtteranceIsLeftToTheServer() {
        // No language means no pair, and guessing one is how you translate
        // English into English.
        let (translator, box) = makeTranslator()

        translator.request(seq: 2, text: "something", source: "")

        XCTAssertNil(translator.configuration)
        XCTAssertEqual(box.gaveUp, [2])
    }

    func testARegionalVariantOfTheTargetIsStillTheTarget() {
        let (translator, box) = makeTranslator()

        translator.request(seq: 3, text: "Hello", source: "en-GB")

        XCTAssertEqual(box.gaveUp, [3])
    }

    func testTheSameUtteranceIsNotQueuedTwice() {
        let (translator, _) = makeTranslator()

        translator.request(seq: 5, text: "hola", source: "es")
        translator.request(seq: 5, text: "hola", source: "es")

        XCTAssertEqual(translator.configuration,
                       TranslationConfig(sourceCode: "es", targetCode: "en"))
    }

    // MARK: - Grouping by pair

    func testWorkIsGroupedByLanguagePair() async {
        // A session belongs to one pair, so two languages cannot be drained by
        // one session — the second has to wait for its own.
        let (translator, box) = makeTranslator()
        translator.request(seq: 1, text: "hola", source: "es")
        translator.request(seq: 2, text: "bonjour", source: "fr")
        translator.request(seq: 3, text: "adiós", source: "es")

        await translator.run(FakeRunner())

        XCTAssertEqual(box.done.map(\.0), [1, 3], "both Spanish lines, not the French")
        XCTAssertEqual(translator.configuration?.sourceCode, "fr",
                       "and it now asks for a French session")
    }

    // MARK: - When it cannot

    func testAPairItCannotDoIsHandedBackOnceAndNeverRetried() async {
        // The usual cause is a language pack that will not install. Retrying
        // per utterance would ask the user forever, so the whole pair is
        // written off and the server takes it.
        let (translator, box) = makeTranslator()
        translator.request(seq: 1, text: "hola", source: "es")
        translator.request(seq: 2, text: "adiós", source: "es")

        await translator.run(FakeRunner(failure: Boom()))

        XCTAssertEqual(box.gaveUp.sorted(), [1, 2], "both go to the server")
        XCTAssertTrue(box.done.isEmpty)

        box.gaveUp.removeAll()
        translator.request(seq: 3, text: "vale", source: "es")
        XCTAssertEqual(box.gaveUp, [3], "and a later one is not even attempted")
        XCTAssertNil(translator.configuration)
    }

    func testAnotherPairStillWorksAfterOneFails() async {
        let (translator, box) = makeTranslator()
        translator.request(seq: 1, text: "hola", source: "es")
        await translator.run(FakeRunner(failure: Boom()))
        box.gaveUp.removeAll()

        translator.request(seq: 2, text: "bonjour", source: "fr")
        await translator.run(FakeRunner(answers: ["bonjour": "hello"]))

        XCTAssertEqual(box.done.map(\.0), [2])
    }

    func testOutputIdenticalToTheInputIsNotATranslation() async {
        // Apple returns the text unchanged when it had nothing to do, which
        // usually means the line was already in the target language. Showing
        // that as a translation is the English-under-English bug again.
        let (translator, box) = makeTranslator()
        translator.request(seq: 7, text: "OK", source: "es")

        await translator.run(FakeRunner(answers: ["OK": "OK"]))

        XCTAssertTrue(box.done.isEmpty)
        XCTAssertEqual(box.gaveUp, [7])
    }

    func testEmptyOutputIsNotATranslation() async {
        let (translator, box) = makeTranslator()
        translator.request(seq: 8, text: "hola", source: "es")

        await translator.run(FakeRunner(answers: ["hola": "   "]))

        XCTAssertEqual(box.gaveUp, [8])
    }

    func testResetForgetsWhatFailed() async {
        // A pack installed later, or a new recording, deserves a fresh try.
        let (translator, box) = makeTranslator()
        translator.request(seq: 1, text: "hola", source: "es")
        await translator.run(FakeRunner(failure: Boom()))
        translator.reset()
        box.gaveUp.removeAll()

        translator.request(seq: 2, text: "hola", source: "es")

        XCTAssertEqual(translator.configuration,
                       TranslationConfig(sourceCode: "es", targetCode: "en"))
        XCTAssertTrue(box.gaveUp.isEmpty)
    }

    func testTagsAreComparedOnTheirPrimarySubtag() {
        XCTAssertEqual(LiveTranslator.primarySubtag("es-419"), "es")
        XCTAssertEqual(LiveTranslator.primarySubtag("EN_US"), "en")
        XCTAssertEqual(LiveTranslator.primarySubtag("  zh-Hans-CN "), "zh")
        XCTAssertEqual(LiveTranslator.primarySubtag(""), "")
    }
}
