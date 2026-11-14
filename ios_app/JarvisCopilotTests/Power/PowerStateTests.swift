import XCTest
@testable import JarvisCopilot

@MainActor
final class PowerStateTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "power-tests-\(UUID().uuidString)")
    }

    private func row(_ id: String, enabled: Bool) -> [String: Any] {
        ["id": id, "name": id.capitalized, "icon": "bolt.fill", "enabled": enabled,
         "settings_schema": [["key": "token", "label": "Token", "kind": "secret"]],
         "settings": ["token": ["set": true]]]
    }

    func testUnknownAndFetchFailureMeanOn() async {
        struct Down: Error {}
        let state = PowerState(fetch: { throw Down() }, send: { _, _ in [:] }, defaults: defaults)
        await state.refresh()
        XCTAssertTrue(state.isOn("dashcam"))
        XCTAssertTrue(PowerShared.isOn("dashcam", defaults: defaults))
        XCTAssertNotNil(state.errorMessage)
    }

    func testOffIDsReachAppGroupAndListeners() async {
        let list = [row("dashcam", enabled: false), row("kanban", enabled: true)]
        let state = PowerState(fetch: { ["integrations": list] }, send: { _, _ in [:] }, defaults: defaults)
        var heard: [Set<String>] = []
        state.observe { heard.append($0) }
        await state.refresh()
        XCTAssertFalse(state.isOn("dashcam"))
        XCTAssertTrue(state.isOn("kanban"))
        XCTAssertFalse(PowerShared.isOn("dashcam", defaults: defaults))
        XCTAssertEqual(heard, [[], ["dashcam"]])
        // A failed fetch afterwards keeps what we knew.
        struct Down: Error {}
        let later = PowerState(fetch: { throw Down() }, send: { _, _ in [:] }, defaults: defaults)
        await later.refresh()
        XCTAssertFalse(later.isOn("dashcam"))
    }

    func testRowsPersistAcrossLaunch() async {
        let state = PowerState(fetch: { ["integrations": [self.row("vault", enabled: true)]] },
                               send: { _, _ in [:] }, defaults: defaults)
        await state.refresh()
        let relaunched = PowerState(fetch: { [:] }, send: { _, _ in [:] }, defaults: defaults)
        XCTAssertEqual(relaunched.rows.map(\.id), ["vault"])
        XCTAssertEqual(relaunched.rows.first?.settings["token"], .secretSet(true))
    }

    func testPendingTriggersApprovalCard() async {
        var shown = 0
        let state = PowerState(fetch: { ["integrations": [self.row("car", enabled: true)]] },
                               send: { _, _ in ["ok": false, "pending": ["id": "a1"]] },
                               defaults: defaults, showApprovals: { shown += 1 })
        let result = await state.set("car", enabled: false)
        XCTAssertEqual(result, .pending)
        XCTAssertEqual(shown, 1)
        XCTAssertTrue(state.pending.contains("car"))
        XCTAssertTrue(state.isOn("car"))
    }

    func testRefusalComesBackAsFailure() async {
        let state = PowerState(fetch: { [:] },
                               send: { _, _ in ["ok": false, "error": "Disarm the alarm first"] },
                               defaults: defaults)
        let result = await state.set("door-alarm", enabled: false)
        XCTAssertEqual(result, .failed("Disarm the alarm first"))
    }
}

@MainActor
final class PowerPendingTests: XCTestCase {
    func testServerPendingClearsAfterDeny() {
        let defaults = UserDefaults(suiteName: "power-pending-\(UUID().uuidString)")!
        let state = PowerState(fetch: { [:] }, send: { _, _ in [:] }, defaults: defaults)
        state.apply(list: [["id": "car", "name": "Car", "enabled": true, "pending": true]])
        XCTAssertTrue(state.pending.contains("car"))
        state.apply(list: [["id": "car", "name": "Car", "enabled": true, "pending": false]])
        XCTAssertFalse(state.pending.contains("car"))
    }

    func testApprovalTitleReadsSettingsDigestCommands() {
        PowerState.shared.apply(list: [["id": "security-advisor", "name": "Security Advisor", "enabled": true]])
        let domain = PowerApprovalDomain()
        let approval = FaceIDApproval(json: ["id": "a", "command": "settings:security-advisor:1a2b3c4d5e"])!
        XCTAssertEqual(domain.title(for: approval), "Change Security Advisor settings")
        let off = FaceIDApproval(json: ["id": "b", "command": "off:security-advisor"])!
        XCTAssertEqual(domain.title(for: off), "Switch off Security Advisor")
        PowerState.shared.apply(list: [])
    }
}
