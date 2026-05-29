import XCTest
@testable import JarvisWatch_Watch_App

@MainActor
final class WatchViewModelTests: XCTestCase {
    func testSuccessFlowSetsAnswer() async {
        let vm = WatchViewModel(asker: { _ in .success(AskResult(replyText: "hi")) })
        await vm.submit(text: "hello")
        XCTAssertEqual(vm.state, .answer("hi"))
    }

    func testNotConfiguredShowsiPhoneMessage() async {
        let vm = WatchViewModel(asker: { _ in .failure(.notConfigured) })
        await vm.submit(text: "hello")
        guard case .error(let m) = vm.state else { return XCTFail("expected error") }
        XCTAssertTrue(m.contains("iPhone"))
    }

    func testUnreachableShowsiPhoneMessage() async {
        let vm = WatchViewModel(asker: { _ in .failure(.unreachable) })
        await vm.submit(text: "hello")
        guard case .error(let m) = vm.state else { return XCTFail("expected error") }
        XCTAssertTrue(m.contains("iPhone"))
    }

    func testNetworkErrorShowsTryAgain() async {
        let vm = WatchViewModel(asker: { _ in .failure(.network("HTTP 500")) })
        await vm.submit(text: "hello")
        guard case .error(let m) = vm.state else { return XCTFail("expected error") }
        XCTAssertTrue(m.contains("Try again"))
    }

    func testEmptyDictationStaysIdleAndDoesNotCallAsker() async {
        var asked = false
        let vm = WatchViewModel(asker: { _ in asked = true; return .success(AskResult(replyText: "x")) })
        await vm.submit(text: "   ")
        XCTAssertEqual(vm.state, .idle)
        XCTAssertFalse(asked)
    }

    func testInFlightGuardIgnoresSubmitWhileThinking() async {
        var asked = false
        let vm = WatchViewModel(asker: { _ in asked = true; return .success(AskResult(replyText: "x")) })
        vm.state = .thinking
        await vm.submit(text: "hello")
        XCTAssertEqual(vm.state, .thinking)
        XCTAssertFalse(asked)
    }
}
