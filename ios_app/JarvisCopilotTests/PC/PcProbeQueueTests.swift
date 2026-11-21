import XCTest
@testable import JarvisCopilot

/// Sliding fast must not queue dozens of probes (they arrived ~5 s late): only the newest waits.
@MainActor
final class PcProbeQueueTests: XCTestCase {
    func testOnlyTheLatestProbeWaitsBehindTheOneInFlight() async {
        var sent: [Int] = []
        var release: CheckedContinuation<Void, Never>?
        let q = PcProbeQueue { args in
            sent.append(args["led"] as? Int ?? -1)
            if sent.count == 1 { await withCheckedContinuation { release = $0 } }
            return nil
        }
        q.submit(["led": 0])
        try? await Task.sleep(for: .milliseconds(20))
        for k in 1...5 { q.submit(["led": k]) }      // the finger keeps sliding while the first is out
        release?.resume()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sent, [0, 5])
    }
}
