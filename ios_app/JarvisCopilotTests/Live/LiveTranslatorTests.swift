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
        var skipped: [(Int, LiveTranslator.Skipped)] = []
        /// Only the ones worth asking the server about.
        var gaveUp: [Int] { skipped.filter { $0.1 == .cannot }.map(\.0) }
        /// Answered here: already in the target language, ask nobody.
        var settled: [Int] { skipped.filter { $0.1 == .alreadyInTarget }.map(\.0) }
    }

    private func makeTranslator() -> (LiveTranslator, Box) {
        let translator = LiveTranslator()
        let box = Box()
        translator.target = "en"
        translator.onTranslated = { seq, text in box.done.append((seq, text)) }
        translator.onSkipped = { seq, why in box.skipped.append((seq, why)) }
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
        XCTAssertEqual(box.settled, [1], "answered, not deferred to the server")
        XCTAssertTrue(box.gaveUp.isEmpty)
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

        XCTAssertEqual(box.settled, [3])
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

        box.skipped.removeAll()
        translator.request(seq: 3, text: "vale", source: "es")
        XCTAssertEqual(box.gaveUp, [3], "and a later one is not even attempted")
        XCTAssertNil(translator.configuration)
    }

    func testAnotherPairStillWorksAfterOneFails() async {
        let (translator, box) = makeTranslator()
        translator.request(seq: 1, text: "hola", source: "es")
        await translator.run(FakeRunner(failure: Boom()))
        box.skipped.removeAll()

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
        XCTAssertEqual(box.settled, [7],
                       "identical output means it was already English — the "
                       + "server must not be asked to translate it again")
        XCTAssertTrue(box.gaveUp.isEmpty)
    }

    func testEmptyOutputIsNotATranslation() async {
        let (translator, box) = makeTranslator()
        translator.request(seq: 8, text: "hola", source: "es")

        await translator.run(FakeRunner(answers: ["hola": "   "]))

        XCTAssertEqual(box.settled, [8])
    }

    func testResetForgetsWhatFailed() async {
        // A pack installed later, or a new recording, deserves a fresh try.
        let (translator, box) = makeTranslator()
        translator.request(seq: 1, text: "hola", source: "es")
        await translator.run(FakeRunner(failure: Boom()))
        translator.reset()
        box.skipped.removeAll()

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

    // MARK: - Sessions that need no view (iOS 26)

    /// Hands out one runner per installed source language, and nil for the rest.
    private final class FakeDirect: DirectTranslationSessions {
        var installed: [String: TranslationRunner] = [:]
        private(set) var asked: [String] = []
        func runner(source: String, target: String) async -> TranslationRunner? {
            asked.append(source)
            return installed[source]
        }
    }

    /// Counts what it was asked, so a warm-up can be seen to have happened.
    private final class CountingRunner: TranslationRunner {
        private(set) var seen: [String] = []
        func translate(_ text: String) async throws -> String {
            seen.append(text)
            return "translated: \(text)"
        }
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// The line is translated the moment it is asked for, with no view in the
    /// picture — which is what lets a recording with the screen closed get its
    /// meaning from the phone instead of a server round trip.
    func testAnInstalledPairIsTranslatedWithoutAView() async {
        let (translator, box) = makeTranslator()
        let direct = FakeDirect()
        direct.installed["es"] = FakeRunner(answers: ["hola": "hello"])
        translator.direct = direct

        translator.request(seq: 1, text: "hola", source: "es")
        await settle()

        XCTAssertEqual(box.done.map(\.1), ["hello"])
        XCTAssertNil(translator.configuration, "no view session was needed")
    }

    /// A pair whose pack is not on the phone goes to the view path, the only one
    /// that can ask the user to download it.
    func testAPairThatIsNotInstalledGoesToTheViewPath() async {
        let (translator, box) = makeTranslator()
        translator.direct = FakeDirect()

        translator.request(seq: 2, text: "bonjour", source: "fr")
        await settle()

        XCTAssertEqual(translator.configuration?.sourceCode, "fr")
        await translator.run(FakeRunner(answers: ["bonjour": "hello"]))
        XCTAssertEqual(box.done.map(\.1), ["hello"])
    }

    /// Loading the model is the point of a warm-up; nothing about it reaches the
    /// transcript, and it happens once per language.
    func testAWarmUpLoadsTheModelAndReportsNothing() async {
        let (translator, box) = makeTranslator()
        let direct = FakeDirect()
        let runner = CountingRunner()
        direct.installed["es"] = runner
        translator.direct = direct

        translator.warmUp(sources: ["es-ES", "en-US"])
        await settle()
        translator.warmUp(sources: ["es-ES"])
        await settle()

        XCTAssertEqual(runner.seen.count, 1, "once, and not for the target language")
        XCTAssertTrue(box.done.isEmpty)
        XCTAssertTrue(box.skipped.isEmpty)
    }

    /// A warm-up for a pack that is not installed is dropped rather than left to
    /// put a view session up for nothing.
    func testAWarmUpForAMissingPackIsDropped() async {
        let (translator, box) = makeTranslator()
        translator.direct = FakeDirect()

        translator.warmUp(sources: ["fr"])
        await settle()

        XCTAssertNil(translator.configuration)
        XCTAssertTrue(box.skipped.isEmpty)
    }

    func testNoTargetLanguageMeansNoTranslation() {
        // Without this the comparison is "en" != "", which is true, so every
        // line including English went off to be translated — into whatever the
        // device felt like. That is how English got an English translation.
        let (translator, box) = makeTranslator()
        translator.target = ""

        translator.request(seq: 9, text: "Hola", source: "es")

        XCTAssertNil(translator.configuration)
        XCTAssertEqual(box.gaveUp, [9], "the server still gets a chance")
    }
}
