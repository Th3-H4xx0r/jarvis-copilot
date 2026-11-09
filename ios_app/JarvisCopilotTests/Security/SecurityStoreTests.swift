import SwiftUI
import UserNotifications
import XCTest
@testable import JarvisCopilot

/// More → Security: decoding the advisor's answers, the status line (the same strings as the web
/// page), the event filters, and Block / Allow signed with Face ID in the `jarvis-security` domain.
/// Fixtures use documentation IPs only (the repo is public).
@MainActor
final class SecurityStoreTests: XCTestCase {
    static let status: [String: Any] = [
        "state": "alerts", "open_alerts": 2, "blocks": 1,
        "last_event": ["id": 5, "ts": "2026-11-08T03:08:00Z", "kind": "pair.claimed"],
        "sources": ["ssh": "running", "files": "running"], "chain_ok": true,
    ]
    static let alerts: [[String: Any]] = [
        ["id": 7, "event_id": 2, "rule": "ssh.new_ip", "title": "SSH login from a new address",
         "summary": "root from 198.51.100.4", "explanation": "Someone logged in as root from a new address.",
         "severity": "high", "count": 1, "status": "open",
         "created": "2026-11-08T03:05:00Z", "updated": "2026-11-08T03:05:00Z"],
        ["id": "8", "event_id": 4, "rule": "agent.tainted_tool", "title": "Risky tool blocked",
         "summary": "terminal in session-1", "explanation": NSNull(), "severity": "medium", "count": 3,
         "status": "open", "created": "2026-11-08T03:07:00Z", "updated": "2026-11-08T03:09:00Z"],
    ]
    static let events: [[String: Any]] = [
        ["id": 1, "ts": "2026-11-08T03:04:05Z", "source": "device", "kind": "auth.failed", "actor": "203.0.113.7",
         "detail": [:] as [String: Any], "outcome": "block"],
        ["id": 2, "ts": "2026-11-08T03:05:00Z", "source": "host", "kind": "ssh.login", "actor": "root@198.51.100.4",
         "detail": [:] as [String: Any], "outcome": "alert"],
        ["id": 3, "ts": "2026-11-08T03:06:00Z", "source": "host", "kind": "file.changed", "actor": "webui/app.py",
         "detail": [:] as [String: Any], "outcome": "digest"],
        ["id": 4, "ts": "2026-11-08T03:07:00Z", "source": "agent", "kind": "tool.risky", "actor": "session-1",
         "detail": [:] as [String: Any], "outcome": "alert"],
    ]
    static let blocks: [[String: Any]] = [
        ["ip": "203.0.113.7", "reason": "12 failed logins", "until": "2026-11-09T03:04:05Z", "event_id": 1],
    ]
    static let settings: [String: Any] = [
        "settings": ["alert_cap_per_hour": 3, "digest_hour": 8, "block_ttl_hours": 24,
                     "quiet_hours": [23, 7], "usual_hours": [7, 23], "disabled_rules": ["file.repo_change"]],
        "model": ["provider": "claude-code", "model": "claude-haiku-5-5"],
        "models": [["provider": "claude-code", "model": "claude-haiku-5-5", "label": "Claude Haiku 5.5"],
                   "@claude-code:claude-sonnet-5-5"],
        "rules": [["id": "auth.burst", "title": "Failed-login bursts"], "ssh.new_ip"],
    ]

    private let signer = FakeCarSigner()

    private func store() -> (SecurityStore, MockTransport) {
        let (jarvis, transport) = JarvisAPI.mocked()
        let key = try! signer.publicKey()
        transport.route("/api/car/approver", json: ["registered": true, "public_key": key])
        transport.route("/api/security/status", json: Self.status)
        transport.route("/api/security/alerts/", json: ["ok": true])
        transport.route("/api/security/alerts", json: Self.alerts)
        transport.route("/api/security/events", json: ["events": Self.events])
        transport.route("/api/security/blocks/", json: ["ok": true])
        transport.route("/api/security/blocks", json: Self.blocks)
        transport.route("/api/security/digests", json: [["date": "2026-11-08", "text": "Quiet night."]])
        transport.route("/api/security/settings", json: Self.settings)
        let approver = ToyotaApprover(signer: signer, api: ToyotaAPI(api: jarvis))
        return (SecurityStore(api: SecurityAPI(api: jarvis), approver: approver), transport)
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        guard let d = request.httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    // MARK: Decoding

    func testStatusDecodes() {
        let s = SecurityStatus(json: Self.status)
        XCTAssertEqual(s.state, "alerts")
        XCTAssertEqual(s.openAlerts, 2)
        XCTAssertEqual(s.blocks, 1)
        XCTAssertEqual(s.sources["ssh"], "running")
        XCTAssertEqual(s.chainOK, true)
        XCTAssertEqual(s.lastEventTime, "2026-11-08T03:08:00Z")
    }

    func testAlertsDecodeWithNumberOrStringIds() {
        let alerts = Self.alerts.compactMap(SecurityAlert.init(json:))
        XCTAssertEqual(alerts.map(\.id), ["7", "8"])
        XCTAssertEqual(alerts[0].title, "SSH login from a new address")
        XCTAssertEqual(alerts[0].severity, "high")
        XCTAssertEqual(alerts[1].count, 3)
        XCTAssertNil(alerts[1].explanation)          // JSON null stays nil
        XCTAssertTrue(alerts.allSatisfy(\.isOpen))
    }

    func testLoadReadsEverySectionBareOrWrapped() async {
        let (store, _) = store()
        await store.load()
        XCTAssertNil(store.problem)
        XCTAssertEqual(store.status?.openAlerts, 2)
        XCTAssertEqual(store.openAlerts.count, 2)
        XCTAssertEqual(store.events.count, 4)          // wrapped under "events"
        XCTAssertEqual(store.blocks.map(\.ip), ["203.0.113.7"])  // a bare array
        XCTAssertEqual(store.digests.first?.text, "Quiet night.")
        XCTAssertEqual(store.settings?.settings.quietHours, [23, 7])
        XCTAssertEqual(store.settings?.settings.disabledRules, ["file.repo_change"])
        XCTAssertEqual(store.settings?.models.map(\.model), ["claude-haiku-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(store.settings?.models.last?.provider, "claude-code")
        // The server's rules, then any it has disabled that it didn't list.
        XCTAssertEqual(store.settings?.rules.map(\.id), ["auth.burst", "ssh.new_ip", "file.repo_change"])
        XCTAssertEqual(store.settings?.rules.first?.title, "Failed-login bursts")
    }

    // MARK: Status line — the same strings as the web page

    func testStatusLine() {
        XCTAssertEqual(SecurityStore.statusLine(nil), "")
        XCTAssertEqual(SecurityStore.statusLine(SecurityStatus(json: ["state": "quiet", "open_alerts": 0])), "All quiet")
        XCTAssertEqual(SecurityStore.statusLine(SecurityStatus(json: ["state": "alerts", "open_alerts": 1])), "1 open alert")
        XCTAssertEqual(SecurityStore.statusLine(SecurityStatus(json: ["state": "alerts", "open_alerts": 2])), "2 open alerts")
    }

    // MARK: Filters

    func testFiltersMatchSourceAndOutcome() {
        let events = Self.events.compactMap(SecurityEvent.init(json:))
        XCTAssertEqual(SecurityStore.filter(events, source: .all, level: .all).map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(SecurityStore.filter(events, source: .host, level: .all).map(\.id), ["2", "3"])
        XCTAssertEqual(SecurityStore.filter(events, source: .all, level: .alert).map(\.id), ["2", "4"])
        XCTAssertEqual(SecurityStore.filter(events, source: .device, level: .block).map(\.id), ["1"])
        XCTAssertEqual(SecurityStore.filter(events, source: .agent, level: .digest).map(\.id), [])
    }

    // MARK: Resolving

    func testBlockSignsTheSecurityDomainAndPostsTheProof() async {
        let (store, transport) = store()
        let ok = await store.resolve("7", .block)
        XCTAssertTrue(ok)
        XCTAssertEqual(signer.signed.count, 1)
        XCTAssertTrue(signer.signed[0].hasPrefix("jarvis-security|block:7|"), signer.signed[0])
        let post = transport.requests.first { $0.url?.path == "/api/security/alerts/7/resolve" }
        XCTAssertEqual(post?.httpMethod, "POST")
        let sent = post.map(body) ?? [:]
        XCTAssertEqual(sent["action"] as? String, "block")
        XCTAssertNotNil(sent["nonce"] as? String)
        XCTAssertNotNil(sent["ts"] as? Int)
        XCTAssertNotNil(sent["signature"] as? String)
        // The signed nonce and time are the ones sent.
        let parts = signer.signed[0].split(separator: "|").map(String.init)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[2], sent["nonce"] as? String)
        XCTAssertEqual(parts[3], (sent["ts"] as? Int).map(String.init))
    }

    func testAllowSignsAllow() async {
        let (store, _) = store()
        _ = await store.resolve("8", .allow)
        XCTAssertTrue(signer.signed.first?.hasPrefix("jarvis-security|allow:8|") == true)
    }

    func testDismissNeedsNoFaceID() async {
        let (store, transport) = store()
        let ok = await store.resolve("7", .dismiss)
        XCTAssertTrue(ok)
        XCTAssertTrue(signer.signed.isEmpty)
        let post = transport.requests.first { $0.url?.path == "/api/security/alerts/7/resolve" }
        XCTAssertEqual(post.map(body)?["action"] as? String, "dismiss")
        XCTAssertNil(post.map(body)?["signature"])
    }

    func testCancelledFaceIDSendsNothing() async {
        let (store, transport) = store()
        signer.cancel = true
        let ok = await store.resolve("7", .block)
        XCTAssertFalse(ok)
        XCTAssertTrue(transport.requests.filter { $0.url?.path.hasSuffix("/resolve") == true }.isEmpty)
    }

    func testUndoPostsTheIP() async {
        let (store, transport) = store()
        await store.undo("203.0.113.7")
        XCTAssertTrue(transport.requests.contains { $0.url?.path == "/api/security/blocks/203.0.113.7/undo" && $0.httpMethod == "POST" })
    }

    func testSaveSendsSettingsAndModel() async {
        let (store, transport) = store()
        await store.load()
        var draft = store.settings!.settings
        draft.alertCapPerHour = 5
        draft.disabledRules = []
        await store.save(draft, model: SecurityModelOption(provider: "claude-code", model: "claude-sonnet-5-5", label: ""))
        let post = transport.requests.last { $0.url?.path == "/api/security/settings" && $0.httpMethod == "POST" }
        let sent = post.map(body) ?? [:]
        let s = sent["settings"] as? [String: Any] ?? [:]
        XCTAssertEqual(s["alert_cap_per_hour"] as? Int, 5)
        XCTAssertEqual(s["quiet_hours"] as? [Int], [23, 7])
        XCTAssertEqual(s["disabled_rules"] as? [String], [])
        XCTAssertEqual((sent["model"] as? [String: Any])?["model"] as? String, "claude-sonnet-5-5")
    }

    // MARK: The push

    func testPushDecodesTheAlertAndItsButtons() {
        let info: [AnyHashable: Any] = ["jarviscopilot": ["type": "security_alert", "alert_id": 7]]
        XCTAssertTrue(SecurityPush.isSecurityPush(info))
        XCTAssertEqual(SecurityPush.alertID(from: info), "7")
        let block = NotificationAction.decode(actionIdentifier: SecurityPush.block, userInfo: info)
        XCTAssertEqual(block.verdict, .securityBlock)
        XCTAssertEqual(block.alertID, "7")
        XCTAssertEqual(NotificationAction.decode(actionIdentifier: SecurityPush.allow, userInfo: info).verdict, .securityAllow)
        XCTAssertEqual(NotificationAction.decode(actionIdentifier: SecurityPush.open, userInfo: info).verdict, .open)

        let category = NotificationCategories.all().first { $0.identifier == "SECURITY_ALERT" }
        XCTAssertEqual(category?.actions.map(\.title), ["Block", "Allow", "Open"])
        let b = category?.actions.first { $0.identifier == SecurityPush.block }
        XCTAssertTrue(b?.options.contains(.destructive) == true)
        XCTAssertTrue(b?.options.contains(.authenticationRequired) == true)
        let a = category?.actions.first { $0.identifier == SecurityPush.allow }
        XCTAssertTrue(a?.options.contains(.authenticationRequired) == true)
    }
}

/// Draws More → Security with the fixtures to /tmp/ringshots/security-page.png, so the page can be
/// looked at before it is installed.
@MainActor
final class SecurityPageRenderTests: XCTestCase {
    func testRenderSecurityPage() async throws {
        let (jarvis, transport) = JarvisAPI.mocked()
        transport.route("/api/security/status", json: SecurityStoreTests.status)
        transport.route("/api/security/alerts", json: SecurityStoreTests.alerts)
        transport.route("/api/security/events", json: SecurityStoreTests.events)
        transport.route("/api/security/blocks", json: SecurityStoreTests.blocks)
        transport.route("/api/security/digests", json: [["date": "2026-11-08", "text": "Quiet night. 3 code changes from Jarvis, 1 relay SSH login."]])
        transport.route("/api/security/settings", json: SecurityStoreTests.settings)
        let store = SecurityStore(api: SecurityAPI(api: jarvis))
        await store.load()
        try RenderHarness.write(NavigationStack { SecurityPage(store: store) },
                                size: CGSize(width: 402, height: 2600), name: "security-page")
    }
}
