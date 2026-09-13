import Foundation

/// What a new chat shows instead of suggestion chips: how Jarvis's world looks
/// right now — wearables, paired devices, coding sessions, usage.
///
/// Each card loads on its own, so a slow or failing endpoint leaves the other
/// three standing. Nothing here polls in the background; the page refreshes it
/// when Chat comes on screen.
@MainActor
@Observable
final class ChatDashboardStore {

    /// One card's data as it arrives.
    enum Card<Value: Equatable>: Equatable {
        case loading
        case ready(Value)
        /// The server did not answer; the card says so instead of a number.
        case unavailable
    }

    struct Wearables: Equatable {
        var connected: Int
        var total: Int
        /// `WearableKeepAlive` kinds, connected ones first — the card stacks
        /// their pictures in this order.
        var kinds: [String]
    }

    struct Devices: Equatable {
        var online: Int
        var total: Int
        /// `deviceIconKind` values (laptop, phone, watch, …), online first.
        var iconKinds: [String]
    }

    struct Coding: Equatable {
        var running: Int
        /// Running sessions stopped on a question or a permission.
        var waiting: Int
    }

    struct Usage: Equatable {
        var provider: String
        var window: String
        var usedPercent: Double
        var resetText: String?
    }

    /// Where each card reads from. Closures rather than the stores themselves,
    /// so a test hands in plain values and nothing touches Bluetooth or the
    /// network.
    struct Sources {
        var wearables: @MainActor () -> [WearableEntry]
        var devices: () async throws -> [Device]
        var codingSessions: () async throws -> [CodingSession]
        var quota: () async throws -> [QuotaProvider]
        var now: () -> Date = Date.init

        @MainActor static func live() -> Sources {
            Sources(wearables: { WearablesHub.shared.roster() },
                    devices: { try await DevicesAPI().list() },
                    codingSessions: { try await CodingSessionsAPI().listSessions() },
                    quota: { try await QuotaAPI().all() })
        }
    }

    private(set) var wearables: Wearables
    private(set) var devices: Card<Devices> = .loading
    private(set) var coding: Card<Coding> = .loading
    private(set) var usage: Card<Usage> = .loading

    /// Opening Chat repeatedly should not re-ask the server every time.
    static let minRefreshInterval: TimeInterval = 15
    private var lastRefresh: Date?
    private let sources: Sources

    init(sources: Sources) {
        self.sources = sources
        wearables = Self.summarize(sources.wearables())
    }

    static func production() -> ChatDashboardStore {
        ChatDashboardStore(sources: .live())
    }

    /// Re-read everything. Wearables are local and always refresh; the three
    /// server cards wait out `minRefreshInterval` unless `force`.
    func refresh(force: Bool = false) async {
        wearables = Self.summarize(sources.wearables())
        let now = sources.now()
        if !force, let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.minRefreshInterval { return }
        lastRefresh = now

        let sources = self.sources
        async let deviceList = Self.attempt { try await sources.devices() }
        async let sessionList = Self.attempt { try await sources.codingSessions() }
        async let providerList = Self.attempt { try await sources.quota() }
        let (devicesResult, sessionsResult, providersResult) = await (deviceList, sessionList, providerList)

        devices = devicesResult.map { .ready(Self.summarize($0)) } ?? Self.keepOrUnavailable(devices)
        coding = sessionsResult.map { .ready(Self.summarize($0)) } ?? Self.keepOrUnavailable(coding)
        if let providersResult {
            usage = Self.summarize(providersResult, now: now).map { .ready($0) } ?? .unavailable
        } else {
            usage = Self.keepOrUnavailable(usage)
        }
    }

    /// The local half only: no network, cheap enough to follow Bluetooth.
    func refreshWearables() {
        let next = Self.summarize(sources.wearables())
        if next != wearables { wearables = next }
    }

    // MARK: - Summaries

    static func summarize(_ roster: [WearableEntry]) -> Wearables {
        let ordered = roster.filter(\.connected) + roster.filter { !$0.connected }
        return Wearables(connected: roster.filter(\.connected).count,
                         total: roster.count,
                         kinds: ordered.map(\.kind))
    }

    static func summarize(_ list: [Device]) -> Devices {
        let ordered = list.filter(\.online) + list.filter { !$0.online }
        return Devices(online: list.filter(\.online).count,
                       total: list.count,
                       iconKinds: ordered.map { deviceIconKind(["kind": $0.platform, "name": $0.label]) })
    }

    static func summarize(_ sessions: [CodingSession]) -> Coding {
        let running = sessions.filter { ["running", "starting"].contains($0.status) }
        return Coding(running: running.count,
                      waiting: running.filter { $0.activityState == "waiting" }.count)
    }

    /// The window closest to its limit, across every provider: the one number
    /// worth a glance.
    static func summarize(_ providers: [QuotaProvider], now: Date) -> Usage? {
        var best: Usage?
        for provider in providers {
            for window in provider.windows {
                guard let used = window.effectiveUsedPercent, used >= (best?.usedPercent ?? -1) else { continue }
                best = Usage(provider: provider.displayName, window: window.label,
                             usedPercent: used, resetText: window.resetText(now: now))
            }
        }
        return best
    }

    // MARK: - Private

    /// A refresh that fails keeps the last good numbers on screen; only a card
    /// that never loaded says it is unavailable.
    private static func keepOrUnavailable<Value>(_ card: Card<Value>) -> Card<Value> {
        if case .ready = card { return card }
        return .unavailable
    }

    private nonisolated static func attempt<Value>(_ work: () async throws -> Value) async -> Value? {
        do { return try await work() } catch {
            JcLog.dropped(JcLog.core, "chat dashboard card", error)
            return nil
        }
    }
}
