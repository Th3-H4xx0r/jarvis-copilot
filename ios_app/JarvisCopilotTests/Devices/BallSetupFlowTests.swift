import XCTest
@testable import JarvisCopilot

/// Pairing a Jarvis Ball end to end against fakes for the ball, iOS's hotspot API and the server.
@MainActor
final class BallSetupFlowTests: XCTestCase {

    private let code = BallSetupCode(ssid: "Jarvis-64D5", passphrase: "ABCDEFGHJKMN", mac: "240ac41264d5")

    private func makeFlow(ball: FakeBall, joiner: FakeJoiner = FakeJoiner(), server: FakeServer = FakeServer()) -> BallSetupFlow {
        let clock = FakeClock()
        return BallSetupFlow(code: code, client: ball, joiner: joiner, server: server,
                             sleep: { seconds in await clock.advance(seconds) }, now: { clock.now })
    }

    func testHappyPathPairsAndConfirmsOnline() async {
        let ball = FakeBall(statuses: [.init(state: "joining_wifi", error: "", message: "Joining Home…"),
                                       .init(state: "claiming", error: "", message: "Pairing…"),
                                       .init(state: "paired", error: "", message: "Paired ✓")])
        let joiner = FakeJoiner(current: "Home")
        let server = FakeServer(onlineAfter: 1)
        let flow = makeFlow(ball: ball, joiner: joiner, server: server)

        await flow.start()
        XCTAssertEqual(flow.statuses[.connect], .done)
        XCTAssertEqual(flow.statuses[.wifi], .active)
        XCTAssertEqual(flow.selectedSSID, "Home", "the phone's own network is preselected")
        XCTAssertFalse(flow.canSubmitWifi, "a secured network needs a password")

        flow.password = "hunter22"
        await flow.submitWifi()
        XCTAssertEqual(flow.statuses[.pair], .done)
        XCTAssertEqual(flow.statuses[.done], .done)
        XCTAssertTrue(flow.finished)
        XCTAssertEqual(joiner.joined, ["Jarvis-64D5"])
        XCTAssertTrue(joiner.left.contains("Jarvis-64D5"), "the phone goes back to its own Wi-Fi")
        let sent = try? JSONSerialization.jsonObject(with: ball.setupBodies.first ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["code"] as? String, "CODE-1")
        XCTAssertEqual((sent?["wifi"] as? [String: String])?["ssid"], "Home")
    }

    func testDeclinedHotspotJoinFailsTheFirstStep() async {
        let joiner = FakeJoiner()
        joiner.joinError = HotspotJoinError.declined
        let flow = makeFlow(ball: FakeBall(), joiner: joiner)
        await flow.start()
        guard case .failed(let message) = flow.statuses[.connect] else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("Join"))
    }

    func testSilentBallAfterJoiningFails() async {
        let ball = FakeBall()
        ball.infoFails = true
        let flow = makeFlow(ball: ball)
        await flow.start()
        guard case .failed(let message) = flow.statuses[.connect] else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("didn't answer"))
    }

    func testWrongPasswordGoesBackToWifi() async {
        let ball = FakeBall(statuses: [.init(state: "failed", error: "wifi_auth", message: "Wrong Wi-Fi password")])
        let flow = makeFlow(ball: ball)
        await flow.start()
        flow.password = "wrongpass"
        await flow.submitWifi()
        XCTAssertEqual(flow.statuses[.wifi], .active)
        XCTAssertEqual(flow.statuses[.pair], .pending)
        XCTAssertEqual(flow.detail[.wifi], "Wrong Wi-Fi password")
        XCTAssertTrue(flow.focusPassword)
        XCTAssertEqual(flow.password, "")
    }

    func testRejectedCodeGetsAFreshOneOnce() async {
        let ball = FakeBall(statuses: [.init(state: "failed", error: "code_rejected", message: "rejected"),
                                       .init(state: "paired", error: "", message: "Paired ✓")])
        let server = FakeServer(onlineAfter: 0)
        let flow = makeFlow(ball: ball, server: server)
        await flow.start()
        flow.password = "hunter22"
        await flow.submitWifi()
        XCTAssertEqual(server.pairStarts, 2)
        XCTAssertEqual(ball.setupBodies.count, 2)
        let second = try? JSONSerialization.jsonObject(with: ball.setupBodies[1]) as? [String: Any]
        XCTAssertEqual(second?["code"] as? String, "CODE-2")
        XCTAssertTrue(flow.finished)
    }

    func testHotspotDropFallsBackToTheServer() async {
        let ball = FakeBall()
        ball.statusFails = true
        let server = FakeServer(onlineAfter: 2)
        let flow = makeFlow(ball: ball, server: server)
        await flow.start()
        flow.password = "hunter22"
        await flow.submitWifi()
        XCTAssertTrue(flow.finished, "the server seeing the ball online is proof enough")
        XCTAssertEqual(flow.statuses[.pair], .done)
    }

    func testBallThatNeverComesOnlineFailsHonestly() async {
        let ball = FakeBall()
        ball.statusFails = true
        let flow = makeFlow(ball: ball, server: FakeServer(onlineAfter: .max))
        await flow.start()
        flow.password = "hunter22"
        await flow.submitWifi()
        XCTAssertFalse(flow.finished)
        guard case .failed(let message) = flow.statuses[.pair] else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("didn't come online"))
    }

    func testCancelLeavesTheHotspot() async {
        let joiner = FakeJoiner()
        let flow = makeFlow(ball: FakeBall(), joiner: joiner)
        await flow.start()
        await flow.cancel()
        XCTAssertEqual(joiner.left.last, "Jarvis-64D5")
    }

    func testOpenNetworkNeedsNoPassword() async {
        let ball = FakeBall(networks: [BallNetwork(ssid: "Cafe", rssi: -60, secure: false)])
        let flow = makeFlow(ball: ball)
        await flow.start()
        XCTAssertEqual(flow.selectedSSID, "Cafe")
        XCTAssertTrue(flow.canSubmitWifi)
    }
}

// MARK: - Fakes

private final class FakeClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 1_789_300_000)
    func advance(_ seconds: Double) async { now = now.addingTimeInterval(seconds) }
}

private final class FakeBall: BallSetupTalking, @unchecked Sendable {
    var networks: [BallNetwork]
    var statuses: [BallSetupStatus]
    var infoFails = false
    var statusFails = false
    private(set) var setupBodies: [Data] = []

    init(networks: [BallNetwork] = [BallNetwork(ssid: "Home", rssi: -50, secure: true),
                                    BallNetwork(ssid: "Neighbour", rssi: -80, secure: true)],
         statuses: [BallSetupStatus] = []) {
        self.networks = networks
        self.statuses = statuses
    }

    func info() async throws -> BallInfo {
        if infoFails { throw BallSetupError.unreachable }
        return BallInfo(battery: 83, firmware: "2.5.0", touch: true)
    }

    func scan() async throws -> [BallNetwork] { networks }

    func setup(_ body: Data) async throws { setupBodies.append(body) }

    func status() async throws -> BallSetupStatus {
        if statusFails { throw BallSetupError.unreachable }
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses.first ?? .init(state: "claiming", error: "", message: "")
    }
}

private final class FakeJoiner: HotspotJoining, @unchecked Sendable {
    var current: String?
    var joinError: Error?
    private(set) var joined: [String] = []
    private(set) var left: [String] = []

    init(current: String? = nil) { self.current = current }

    func join(ssid: String, passphrase: String) async throws {
        if let joinError { throw joinError }
        if !joined.contains(ssid) { joined.append(ssid) }
    }

    func leave(ssid: String) async { left.append(ssid) }
    func currentSSID() async -> String? { current }
}

private final class FakeServer: BallServerTalking, @unchecked Sendable {
    private(set) var pairStarts = 0
    private var onlineChecks = 0
    let onlineAfter: Int

    init(onlineAfter: Int = 0) { self.onlineAfter = onlineAfter }

    func serverURL() async -> String { "https://j.example.com" }

    func pairStart(label: String) async throws -> BallPairing {
        pairStarts += 1
        return BallPairing(code: "CODE-\(pairStarts)", cfID: "id", cfSecret: "secret")
    }

    func ballOnline(name: String, since: Date) async -> Bool {
        onlineChecks += 1
        return onlineChecks > onlineAfter
    }
}
