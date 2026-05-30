import XCTest
@testable import JarvisWatch_Watch_App

@MainActor
final class WatchViewModelTests: XCTestCase {
    func testSuccessShowsAnswerAndSpeaksClip() async {
        var spoken: AskResult?
        let vm = WatchViewModel(
            asker: { _ in .success(AskResult(replyText: "hi", audioBase64: "QUJD")) },
            speak: { spoken = $0 })
        await vm.submit(text: "hello")
        XCTAssertEqual(vm.state, .answer("hi"))
        XCTAssertEqual(spoken?.replyText, "hi")
        XCTAssertEqual(spoken?.audioBase64, "QUJD")
    }

    func testSuccessWithNoClipStillSpeaks() async {
        var spoken: AskResult?
        let vm = WatchViewModel(
            asker: { _ in .success(AskResult(replyText: "hi", audioBase64: "")) },
            speak: { spoken = $0 })
        await vm.submit(text: "hello")
        XCTAssertEqual(spoken?.replyText, "hi")          // built-in voice fallback path
        XCTAssertEqual(spoken?.audioBase64, "")
    }

    func testNotConfiguredShowsiPhoneMessage() async {
        let vm = WatchViewModel(asker: { _ in .failure(.notConfigured) }, speak: { _ in })
        await vm.submit(text: "hello")
        guard case .error(let m) = vm.state else { return XCTFail("expected error") }
        XCTAssertTrue(m.contains("iPhone"))
    }

    func testUnreachableShowsiPhoneMessage() async {
        let vm = WatchViewModel(asker: { _ in .failure(.unreachable) }, speak: { _ in })
        await vm.submit(text: "hello")
        guard case .error(let m) = vm.state else { return XCTFail("expected error") }
        XCTAssertTrue(m.contains("iPhone"))
    }

    func testNetworkErrorShowsTryAgain() async {
        let vm = WatchViewModel(asker: { _ in .failure(.network("HTTP 500")) }, speak: { _ in })
        await vm.submit(text: "hello")
        guard case .error(let m) = vm.state else { return XCTFail("expected error") }
        XCTAssertTrue(m.contains("Try again"))
    }

    func testEmptyDictationStaysIdleAndDoesNotAsk() async {
        var asked = false
        let vm = WatchViewModel(
            asker: { _ in asked = true; return .success(AskResult(replyText: "x", audioBase64: "")) },
            speak: { _ in })
        await vm.submit(text: "   ")
        XCTAssertEqual(vm.state, .idle)
        XCTAssertFalse(asked)
    }

    func testInFlightGuardIgnoresSubmitWhileThinking() async {
        var asked = false
        let vm = WatchViewModel(
            asker: { _ in asked = true; return .success(AskResult(replyText: "x", audioBase64: "")) },
            speak: { _ in })
        vm.state = .thinking
        await vm.submit(text: "hello")
        XCTAssertEqual(vm.state, .thinking)
        XCTAssertFalse(asked)
    }
}
