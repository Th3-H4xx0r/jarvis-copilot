import Foundation
import UIKit
import WidgetKit

/// One area's live values for widgets, keyed `area.name` (see `WidgetDataCatalog`). Called on the
/// main actor, one refresh at a time, so a provider's own cache is never raced.
@MainActor
protocol WidgetDataProvider {
    func values() async -> [String: JCJSON]
    /// The server area this provider asks about, as the server's `widgets` push names it (`health`,
    /// `chat`, `coding`); nil for what the phone knows itself, read on every pass. In the background
    /// an area is asked only when a push named it (or it is old) — a coding change on the Mac used to
    /// refetch all eleven requests, health histories included, twice an hour all night.
    var area: String? { get }
}

extension WidgetDataProvider {
    var area: String? { nil }
}

/// Gathers every area's values into the App Group snapshot the widgets read, and reloads the
/// widgets without burning iOS's reload budget: the first snapshot reloads at once; after that
/// a real change is shown at most every five minutes, and an unchanged one never.
@MainActor
final class WidgetDataHub {
    static let shared = WidgetDataHub(providers: [
        HealthWidgetData(), WearablesWidgetData(), ChatWidgetData(), CodingWidgetData(),
        ServerWidgetData(), PhoneWidgetData(), LiveWidgetData(),
    ])

    static let widgetKind = "JarvisDesignWidget"
    static let reloadSpacing: TimeInterval = 300
    static let refreshEvery: TimeInterval = 900

    private let providers: [any WidgetDataProvider]
    private let write: ([String: JCJSON]) -> Void
    private let reload: () -> Void
    private let now: () -> Date

    private(set) var current: [String: JCJSON] = [:]
    private var reloaded: [String: JCJSON]?
    private var lastReload: Date?
    private var timer: Timer?
    private var soon: Task<Void, Never>?
    private var watches: [NSObjectProtocol] = []
    private var refreshing = false
    private var again = false
    private var foreground = true
    /// Whether any Jarvis widget is on a Home or Lock Screen; nil until asked. With none there is
    /// nothing to keep fresh, so nothing is fetched.
    private(set) var installed: Bool?
    private var lastInstalledCheck: Date?
    /// Server areas owed a fetch: named by a `widgets` push, or all of them after a launch, a
    /// foregrounding or a reconnect.
    private(set) var dirty: Set<String>
    /// When each server area was last asked.
    private var fetchedAt: [String: Date] = [:]
    /// Each provider's values from its last run, by position: a provider this pass does not ask
    /// keeps showing what it gave, and one that stops giving a key drops it.
    private var byProvider: [Int: [String: JCJSON]] = [:]
    /// The next pass runs because the phone was just unlocked: the Home Screen is about to show.
    private var unlockPass = false
    /// In the background a pushed change waits until its area was last asked this long ago — or for
    /// the phone to be unlocked. The widgets can only redraw every few minutes anyway.
    static let backgroundAreaEvery: TimeInterval = 3600
    /// An area nobody pushes for (chat, and health after the phone's own band uploads) is asked
    /// again this often in the background…
    static let backgroundFullEvery: TimeInterval = 7200
    /// …or on an unlock once it is this old.
    static let unlockStaleAfter: TimeInterval = 1800

    init(providers: [any WidgetDataProvider],
         write: @escaping ([String: JCJSON]) -> Void = { WidgetDataFile.write($0) },
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetDataHub.widgetKind) },
         now: @escaping () -> Date = Date.init) {
        self.providers = providers
        self.write = write
        self.reload = reload
        self.now = now
        dirty = Set(providers.compactMap(\.area))
    }

    /// Every server area some provider asks about.
    private var areas: Set<String> { Set(providers.compactMap(\.area)) }

    /// Every 15 minutes while the app is on screen, whenever something worth showing changes, and
    /// in the background when the server pushes `widgets` (at most every 30 minutes).
    func start() {
        guard watches.isEmpty else { return }
        if foreground { startTimer() }      // a background launch (the watch, a push) waits for the screen
        checkInstalled()
        BridgeTopics.shared.on("widgets") { data in WidgetDataHub.shared.pushed(data) }
        // Pushes sent while the socket was down never arrive: catch up once it is back.
        BridgeTopics.shared.onResync { WidgetDataHub.shared.resynced() }
        for name in [Notification.Name.jcKeepAliveChanged, UIDevice.batteryStateDidChangeNotification] {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WidgetDataHub.shared.refreshSoon() }
            })
        }
        watches.append(NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WidgetDataHub.shared.unlocked() }
        })
    }

    /// The server's `widgets` push: the areas in `what` changed (none named: all of them).
    func pushed(_ data: [String: Any]) {
        let named = Set(data["what"] as? [String] ?? [])
        dirty.formUnion(named.isEmpty ? areas : named.intersection(areas))
        refreshSoon()
    }

    /// The socket came back after missing whatever was pushed while it was down.
    func resynced() {
        guard installed != false else { return }
        dirty.formUnion(areas)
        refreshSoon()
    }

    /// The phone was unlocked with the app in the background: what changed is fetched now, so the
    /// Home Screen about to show is current.
    func unlocked() {
        guard !foreground, installed != false else { return }
        unlockPass = true
        refreshSoon()
    }

    /// The app came forward (true) or went to the background (false).
    func setForeground(_ on: Bool) {
        guard on != foreground else { return }
        foreground = on
        if on {
            dirty.formUnion(areas)
            startTimer()
            checkInstalled()        // a widget may have been added or removed meanwhile
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The background refresh task: the phone's own values, and a server area only when `toAsk`
    /// allows it. Forcing the server here made ten requests on every refresh, three or four times
    /// an hour.
    func refreshAll() async {
        checkInstalled()        // a widget added from the Home Screen while the app was away
        await refresh()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { _ in
            Task { @MainActor in await WidgetDataHub.shared.refresh() }
        }
    }

    private func checkInstalled() {
        lastInstalledCheck = now()
        WidgetCenter.shared.getCurrentConfigurations { result in
            // Unknown (the call failed) counts as installed: a widget that stops updating is worse
            // than a few requests.
            let has = (try? result.get()).map { $0.contains { $0.kind == WidgetDataHub.widgetKind } } ?? true
            Task { @MainActor in WidgetDataHub.shared.setInstalled(has) }
        }
    }

    func setInstalled(_ has: Bool) {
        let was = installed
        installed = has
        if has {
            BridgeTopics.shared.want("widgets", owner: "widgets", every: 1800)
            if was != true { Task { await refresh() } }
        } else {
            BridgeTopics.shared.drop("widgets", owner: "widgets")
        }
    }

    /// A refresh a few seconds from now; several asks in a row make one refresh.
    func refreshSoon() {
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// One at a time: a refresh asked for while one runs makes that one go round once more, so
    /// an older, slower pass can never overwrite a newer snapshot.
    func refresh() async {
        if refreshing {
            again = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            again = false
            await refreshOnce()
        } while again
    }

    private func refreshOnce() async {
        guard installed != false else {
            // None installed when last asked; ask again now and then (a local call, no radio).
            if lastInstalledCheck.map({ now().timeIntervalSince($0) > 600 }) ?? true { checkInstalled() }
            return
        }
        let ask = toAsk(at: now(), unlocking: unlockPass)
        unlockPass = false
        for area in ask {
            fetchedAt[area] = now()
            dirty.remove(area)
        }
        // What the phone knows itself is read on every pass; a server area only when asked.
        for (index, provider) in providers.enumerated() {
            if let area = provider.area, !ask.contains(area) { continue }
            byProvider[index] = await provider.values()
        }
        var values: [String: JCJSON] = [:]
        for index in providers.indices {
            values.merge(byProvider[index] ?? [:]) { _, new in new }
        }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        values["time.updated"] = .string(clock.string(from: now()))
        current = values
        write(values)
        let due = lastReload.map { now().timeIntervalSince($0) >= Self.reloadSpacing } ?? true
        if reloaded == nil || (due && Self.changed(reloaded ?? [:], values)) {
            reload()
            reloaded = values
            lastReload = now()
        }
    }

    /// The server areas a pass at `date` asks about. On screen, all of them (each provider keeps
    /// its own short cache). In the background, an area a push named waits until it was last asked
    /// `backgroundAreaEvery` ago, or for an unlock; any other area goes after `backgroundFullEvery`,
    /// or on an unlock after `unlockStaleAfter`.
    func toAsk(at date: Date, unlocking: Bool) -> Set<String> {
        if foreground { return areas }
        return areas.filter { area in
            let age = fetchedAt[area].map { date.timeIntervalSince($0) } ?? .infinity
            if dirty.contains(area) { return unlocking || age >= Self.backgroundAreaEvery }
            return age >= (unlocking ? Self.unlockStaleAfter : Self.backgroundFullEvery)
        }
    }

    /// Whether `new` shows something `old` didn't: any key added, removed or changed, numbers
    /// only when they moved by more than 1%, the update time never.
    nonisolated static func changed(_ old: [String: JCJSON], _ new: [String: JCJSON]) -> Bool {
        let keys = Set(old.keys).union(new.keys).subtracting(["time.updated"])
        return keys.contains { key in
            switch (old[key], new[key]) {
            case (.number(let a), .number(let b)):
                return abs(a - b) > max(abs(a), abs(b)) * 0.01
            case (let a?, let b?):
                return a != b
            default:
                return true
            }
        }
    }
}

// MARK: - Providers

/// Scores from the last Jarvis Health run, and each metric's last seven days from the server.
@MainActor
final class HealthWidgetData: WidgetDataProvider {
    let area: String? = "health"
    private var cache: (at: Date, values: [String: JCJSON])?
    private static let metrics = ["steps": "steps", "sleep": "sleep", "heart_rate": "hr", "hrv": "hrv",
                                  "spo2": "spo2", "stress": "stress", "sleep_debt": "sleep_debt"]

    func values() async -> [String: JCJSON] {
        var out: [String: JCJSON] = [:]
        if let s = HealthSnapshot.read() {
            if let v = s.health { out["health.score"] = .number(Double(v)) }
            out["health.band"] = .string(s.band)
            if let v = s.sleep { out["health.sleep_score"] = .number(Double(v)) }
            if let v = s.recovery { out["health.recovery"] = .number(Double(v)) }
            if let v = s.activity { out["health.activity_score"] = .number(Double(v)) }
            if let v = s.body { out["health.vitals_score"] = .number(Double(v)) }
            out["health.analysis"] = .string(s.analysis)
        }
        if let cache, Date().timeIntervalSince(cache.at) < 600 { return out.merging(cache.values) { a, _ in a } }
        guard BridgeClient.shared.isPaired else { return out }
        var history: [String: JCJSON] = [:]
        let client = HealthClient(spaceID: HealthSpace.shared)
        for metric in Self.metrics.keys.sorted() {
            guard let result = try? await client.history(metric: metric, range: "W"),
                  let name = Self.metrics[metric] else { continue }
            history.merge(Self.values(metric: metric, name: name, history: result)) { _, new in new }
        }
        // Nothing came back (offline): keep what was shown rather than caching an empty week.
        guard !history.isEmpty else { return out.merging(cache?.values ?? [:]) { a, _ in a } }
        cache = (Date(), history)
        return out.merging(history) { a, _ in a }
    }

    /// The week as `{x: weekday, y: value}` points (unmeasured days left out), and today's value.
    static func values(metric: String, name: String, history: HealthHistory) -> [String: JCJSON] {
        var out: [String: JCJSON] = [:]
        let day = DateFormatter()
        day.dateFormat = "EEE"
        let measured = history.buckets.filter { $0.days > 0 && $0.value != nil }
        let points: [JCJSON] = measured.map {
            .object(["x": .string(day.string(from: $0.startDate)), "y": .number($0.value ?? 0)])
        }
        if metric != "stress", metric != "sleep_debt" { out["health.\(name)_week"] = .array(points) }
        guard let last = measured.last, let value = last.value else { return out }
        switch metric {
        case "steps": out["health.steps"] = .number(value.rounded())
        case "sleep":
            out["health.asleep_minutes"] = .number(value.rounded())
            out["health.asleep"] = .string("\(Int(value) / 60)h \(Int(value) % 60)m")
            if let stages = last.stages {
                out["health.deep_minutes"] = .number(stages.deep.rounded())
                out["health.rem_minutes"] = .number(stages.rem.rounded())
                out["health.light_minutes"] = .number(stages.light.rounded())
            }
        case "heart_rate": out["health.hr_avg"] = .number(value.rounded())
        case "hrv": out["health.hrv"] = .number(value.rounded())
        case "spo2": out["health.spo2"] = .number((value * 10).rounded() / 10)
        case "stress": out["health.stress"] = .number(value.rounded())
        case "sleep_debt": out["health.sleep_debt"] = .number(value.rounded())
        default: break
        }
        return out
    }
}

/// Every paired wearable: name, link, battery, keep-alive, and what its commands are doing.
@MainActor
struct WearablesWidgetData: WidgetDataProvider {
    func values() async -> [String: JCJSON] {
        let hub = WearablesHub.shared
        let roster = hub.roster()
        var out = Self.commandValues(Self.devices(hub, paired: Set(roster.map(\.kind))))
        for entry in roster {
            let key = entry.kind
            out["\(key).name"] = .string(entry.name)
            out["\(key).connected"] = .bool(entry.connected)
            out["\(key).status"] = .string(entry.connected ? "Connected" : "Not connected")
            out["\(key).keep_alive"] = .bool(WearableKeepAlive.isOn(key))
        }
        if let b = hub.ring.session.battery { out["ring.battery"] = .number(Double(b.percent)) }
        if let b = hub.x5.session.battery { out["x5ring.battery"] = .number(Double(b.percent)) }
        if let b = hub.bottle.status?.batteryPercent { out["bottle.battery"] = .number(Double(b)) }
        return out
    }

    /// The wearables whose commands report a state, by widget key: the paired ones, plus the
    /// dashcam and car lights (they say nothing until set up).
    static func devices(_ hub: WearablesHub, paired: Set<String>) -> [String: any WearableDevice] {
        var out: [String: any WearableDevice] = [DashcamDevice.identityKey: DashcamDevice.shared,
                                                 CarLightsDevice.kind: CarLightsDevice.shared]
        // Each wraps its manager, as the registered one does.
        let wearables: [(String, any WearableDevice)] = [
            (WearableKeepAlive.bottle, VsitooS1Pro(manager: hub.bottle)),
            (WearableKeepAlive.esp32, Esp32Board(manager: hub.esp32)),
            (WearableKeepAlive.ring, ColmiR12(manager: hub.ring)),
            (WearableKeepAlive.x5ring, X5Ring(backend: hub.x5)),
            (WearableKeepAlive.band, BandDevice(backend: hub.band)),
            (WearableKeepAlive.glasses, hub.glasses),
        ]
        for (key, device) in wearables where paired.contains(key) { out[key] = device }
        return out
    }

    /// `WidgetDataCatalog.commandValues` from each device's `commandState`.
    static func commandValues(_ devices: [String: any WearableDevice]) -> [String: JCJSON] {
        var out: [String: JCJSON] = [:]
        for value in WidgetDataCatalog.commandValues {
            guard let state = devices[value.device]?.commandState(value.skill) else { continue }
            if value.onLabel != nil, let on = state.on { out[value.key] = .bool(on) }
            if value.modeLabel != nil, let mode = state.mode { out[value.modeKey] = .string(mode) }
            if value.endsLabel != nil, let ends = state.endsAt { out[value.endsKey] = .number(ends.timeIntervalSince1970) }
        }
        return out
    }
}

/// The most recent chat: its title, Jarvis's last reply, and whether a turn is running.
@MainActor
final class ChatWidgetData: WidgetDataProvider {
    let area: String? = "chat"
    private var cache: (at: Date, values: [String: JCJSON])?

    func values() async -> [String: JCJSON] {
        if let cache, Date().timeIntervalSince(cache.at) < 120 { return cache.values }
        guard BridgeClient.shared.isPaired,
              // The newest 20 hold the latest chat and any that is streaming; the whole
              // list (660 KB) was fetched for every refresh, in the background too.
              let sessions = try? await SessionsAPI().recent(limit: 20),
              let latest = sessions.filter({ !$0.archived }).max(by: { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) })
        else { return cache?.values ?? [:] }
        var out: [String: JCJSON] = ["chat.last_title": .string(latest.title),
                                     "chat.working": .bool(sessions.contains { $0.isStreaming })]
        if let at = latest.updatedAt {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            out["chat.last_at"] = .string(clock.string(from: Date(timeIntervalSince1970: TimeInterval(at))))
        }
        if let text = try? await SessionsAPI().snapshot(latest.id).lastAssistantText, !text.isEmpty {
            out["chat.last_reply"] = .string(String(text.prefix(280)))
        }
        cache = (Date(), out)
        return out
    }
}

/// Coding sessions: how many are working, how many are waiting on you.
@MainActor
final class CodingWidgetData: WidgetDataProvider {
    let area: String? = "coding"
    private var cache: (at: Date, values: [String: JCJSON])?

    func values() async -> [String: JCJSON] {
        if let cache, Date().timeIntervalSince(cache.at) < 120 { return cache.values }
        guard BridgeClient.shared.isPaired, let sessions = try? await CodingSessionsAPI().listLiveSessions() else {
            return cache?.values ?? [:]
        }
        let running = sessions.filter { $0.activityState != nil }
        let working = running.filter { $0.activityState == "working" }.count
        let waiting = running.filter { $0.activityState == "waiting" }.count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        var out: [String: JCJSON] = [
            "coding.working": .number(Double(working)), "coding.waiting": .number(Double(waiting)),
            "coding.total": .number(Double(running.count)),
            "coding.summary": .string(parts.isEmpty ? (running.isEmpty ? "Nothing running" : "\(running.count) idle")
                                                    : parts.joined(separator: " · ")),
        ]
        // Hook-tracked agents: the most urgent session, the plan, a short list.
        if let overview = try? await AgentsAPI().overview() {
            let live = overview.sessions.filter { $0.state != .idle }
            let lead = live.first
            out["coding.lead_agent"] = .string(lead?.agentName ?? "")
            out["coding.lead_project"] = .string(lead?.project ?? "")
            out["coding.lead_state"] = .string(lead?.state.label ?? "")
            out["coding.lead_step"] = .string(lead?.step ?? "")
            out["coding.lead_waiting"] = .bool(lead?.state.waitsOnYou ?? false)
            out["coding.claude_5h"] = overview.usage?.fiveHour.map { .number(Double($0.percent)) } ?? .null
            out["coding.claude_week"] = overview.usage?.sevenDay.map { .number(Double($0.percent)) } ?? .null
            out["coding.agents"] = .array(live.prefix(4).map { s in
                .object(["project": .string(s.project), "agent": .string(s.agentName),
                         "state": .string(s.state.rawValue), "step": .string(s.step)])
            })
        }
        cache = (Date(), out)
        return out
    }
}

/// The link to the Jarvis server.
@MainActor
struct ServerWidgetData: WidgetDataProvider {
    func values() async -> [String: JCJSON] {
        let status = BridgeClient.shared.status
        return ["server.connected": .bool(status == .online), "server.status": .string(status.text)]
    }
}

/// The door alarm and the car as the live buttons last saw them (`LiveButtons`).
@MainActor
struct LiveWidgetData: WidgetDataProvider {
    func values() async -> [String: JCJSON] {
        LiveButtons.shared.widgetValues()
    }
}

/// The phone's own battery, and the next alarm or timer.
@MainActor
struct PhoneWidgetData: WidgetDataProvider {
    func values() async -> [String: JCJSON] {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var out: [String: JCJSON] = [:]
        let level = UIDevice.current.batteryLevel
        if level >= 0 { out["phone.battery"] = .number((Double(level) * 100).rounded()) }
        let state = UIDevice.current.batteryState
        out["phone.charging"] = .bool(state == .charging || state == .full)
        if let alarms = try? await DefaultAlarmScheduler().list(),
           let next = alarms.compactMap({ alarm in alarm.fireDate.map { (alarm, $0) } }).filter({ $0.1 > Date() })
               .min(by: { $0.1 < $1.1 }) {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            out["alarm.next"] = .string("\(next.0.label) \(clock.string(from: next.1))")
        }
        return out
    }
}
