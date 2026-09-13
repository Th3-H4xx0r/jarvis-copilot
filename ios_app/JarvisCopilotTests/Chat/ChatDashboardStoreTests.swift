import XCTest
@testable import JarvisCopilot

/// The new-chat status dashboard: what each card says, and that one failing
/// source leaves the others standing.
@MainActor
final class ChatDashboardStoreTests: XCTestCase {

    private struct Boom: Error {}

    private func wearable(_ kind: String, connected: Bool) -> WearableEntry {
        WearableEntry(kind: kind, deviceID: kind + "-id", model: kind, name: kind,
                      connected: connected, rssi: nil, lastRSSI: nil, lastSeen: nil)
    }

    private func device(_ id: String, online: Bool, platform: String, label: String) -> Device {
        Device(json: ["id": id, "online": online, "platform": platform, "label": label])
    }

    private func sources(wearables: [WearableEntry] = [],
                         devices: Result<[Device], Error> = .success([]),
                         sessions: Result<[CodingSession], Error> = .success([]),
                         quota: Result<[QuotaProvider], Error> = .success([]),
                         clock: @escaping () -> Date = Date.init) -> ChatDashboardStore.Sources {
        ChatDashboardStore.Sources(wearables: { wearables },
                                   devices: { try devices.get() },
                                   codingSessions: { try sessions.get() },
                                   quota: { try quota.get() },
                                   now: clock)
    }

    func testWearablesCountTheConnectedOnesAndStackThemFirst() {
        let store = ChatDashboardStore(sources: sources(wearables: [
            wearable(WearableKeepAlive.scale, connected: false),
            wearable(WearableKeepAlive.bottle, connected: true),
            wearable(WearableKeepAlive.ring, connected: true),
        ]))
        XCTAssertEqual(store.wearables.connected, 2)
        XCTAssertEqual(store.wearables.total, 3)
        XCTAssertEqual(store.wearables.kinds, [WearableKeepAlive.bottle, WearableKeepAlive.ring, WearableKeepAlive.scale])
    }

    func testDevicesCountTheOnlineOnesWithTheirKindOfDevice() async {
        let store = ChatDashboardStore(sources: sources(devices: .success([
            device("d1", online: false, platform: "mobile-ios", label: "iPhone"),
            device("d2", online: true, platform: "desktop", label: "MacBook Pro"),
        ])))
        await store.refresh()
        XCTAssertEqual(store.devices, .ready(.init(online: 1, total: 2, iconKinds: ["laptop", "phone"])))
    }

    func testCodingCountsRunningSessionsAndThoseWaitingOnYou() async {
        let store = ChatDashboardStore(sources: sources(sessions: .success([
            CodingSession(id: "a", status: "running", activityState: "working"),
            CodingSession(id: "b", status: "running", activityState: "waiting"),
            CodingSession(id: "c", status: "stopped"),
        ])))
        await store.refresh()
        XCTAssertEqual(store.coding, .ready(.init(running: 2, waiting: 1)))
    }

    func testUsageShowsTheWindowClosestToItsLimit() async {
        let providers = [
            QuotaProvider(json: ["provider": "claude", "display_name": "Claude Code", "windows": [
                ["label": "5-hour", "used_percent": 42],
                ["label": "Weekly", "used_percent": 71],
            ]]),
            QuotaProvider(json: ["provider": "codex", "display_name": "Codex", "windows": [
                ["label": "Daily", "remaining_percent": 80],
            ]]),
        ]
        let store = ChatDashboardStore(sources: sources(quota: .success(providers)))
        await store.refresh()
        XCTAssertEqual(store.usage, .ready(.init(provider: "Claude Code", window: "Weekly",
                                                 usedPercent: 71, resetText: nil)))
    }

    func testUsageIsUnavailableWhenNoProviderReportsANumber() async {
        let store = ChatDashboardStore(sources: sources(quota: .success([])))
        await store.refresh()
        XCTAssertEqual(store.usage, .unavailable)
    }

    func testOneFailingSourceLeavesTheOtherCardsStanding() async {
        let store = ChatDashboardStore(sources: sources(
            devices: .failure(Boom()),
            sessions: .success([CodingSession(id: "a", status: "running")])))
        await store.refresh()
        XCTAssertEqual(store.devices, .unavailable)
        XCTAssertEqual(store.coding, .ready(.init(running: 1, waiting: 0)))
    }

    func testAFailedRefreshKeepsTheLastGoodNumbers() async {
        var failing = false
        var clock = Date(timeIntervalSince1970: 0)
        let store = ChatDashboardStore(sources: ChatDashboardStore.Sources(
            wearables: { [] },
            devices: {
                if failing { throw Boom() }
                return [Device(json: ["id": "d", "online": true, "platform": "desktop", "label": "Mac"])]
            },
            codingSessions: { [] },
            quota: { [] },
            now: { clock }))
        await store.refresh()
        failing = true
        clock = clock.addingTimeInterval(ChatDashboardStore.minRefreshInterval + 1)
        await store.refresh()
        XCTAssertEqual(store.devices, .ready(.init(online: 1, total: 1, iconKinds: ["desktop"])))
    }

    func testReopeningChatSoonAfterDoesNotAskTheServerAgain() async {
        var calls = 0
        var clock = Date(timeIntervalSince1970: 0)
        let store = ChatDashboardStore(sources: ChatDashboardStore.Sources(
            wearables: { [] },
            devices: { calls += 1; return [] },
            codingSessions: { [] },
            quota: { [] },
            now: { clock }))
        await store.refresh()
        clock = clock.addingTimeInterval(3)
        await store.refresh()
        XCTAssertEqual(calls, 1)
        await store.refresh(force: true)
        XCTAssertEqual(calls, 2)
    }
}
