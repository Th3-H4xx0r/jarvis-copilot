import Foundation
import UIKit
import WidgetKit

/// One area's live values for widgets, keyed `area.name` (see `WidgetDataCatalog`).
protocol WidgetDataProvider {
    func values() async -> [String: JCJSON]
}

/// Gathers every area's values into the App Group snapshot the widgets read, and reloads the
/// widgets without burning iOS's reload budget: the first snapshot reloads at once; after that
/// a real change is shown at most every five minutes, and an unchanged one never.
@MainActor
final class WidgetDataHub {
    static let shared = WidgetDataHub(providers: [
        HealthWidgetData(), WearablesWidgetData(), ChatWidgetData(), CodingWidgetData(),
        ServerWidgetData(), PhoneWidgetData(),
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

    init(providers: [any WidgetDataProvider],
         write: @escaping ([String: JCJSON]) -> Void = { WidgetDataFile.write($0) },
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetDataHub.widgetKind) },
         now: @escaping () -> Date = Date.init) {
        self.providers = providers
        self.write = write
        self.reload = reload
        self.now = now
    }

    /// Every 15 minutes while the app is alive, and whenever something worth showing changes.
    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { _ in
            Task { @MainActor in await WidgetDataHub.shared.refresh() }
        }
        for name in [Notification.Name.jcKeepAliveChanged, UIDevice.batteryStateDidChangeNotification] {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WidgetDataHub.shared.refreshSoon() }
            })
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

    func refresh() async {
        var values: [String: JCJSON] = [:]
        for provider in providers {
            values.merge(await provider.values()) { _, new in new }
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
final class HealthWidgetData: WidgetDataProvider {
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
        guard await BridgeClient.shared.isPaired else { return out }
        var history: [String: JCJSON] = [:]
        let client = HealthClient(spaceID: HealthSpace.shared)
        for metric in Self.metrics.keys.sorted() {
            guard let result = try? await client.history(metric: metric, range: "W"),
                  let name = Self.metrics[metric] else { continue }
            history.merge(Self.values(metric: metric, name: name, history: result)) { _, new in new }
        }
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

/// Every paired wearable: name, link, battery and keep-alive.
@MainActor
struct WearablesWidgetData: WidgetDataProvider {
    func values() async -> [String: JCJSON] {
        let hub = WearablesHub.shared
        var out: [String: JCJSON] = [:]
        for entry in hub.roster() {
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
}

/// The most recent chat: its title, Jarvis's last reply, and whether a turn is running.
final class ChatWidgetData: WidgetDataProvider {
    private var cache: (at: Date, values: [String: JCJSON])?

    func values() async -> [String: JCJSON] {
        if let cache, Date().timeIntervalSince(cache.at) < 120 { return cache.values }
        guard await BridgeClient.shared.isPaired,
              let sessions = try? await SessionsAPI().list(),
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
final class CodingWidgetData: WidgetDataProvider {
    private var cache: (at: Date, values: [String: JCJSON])?

    func values() async -> [String: JCJSON] {
        if let cache, Date().timeIntervalSince(cache.at) < 120 { return cache.values }
        guard await BridgeClient.shared.isPaired, let sessions = try? await CodingSessionsAPI().listSessions() else {
            return cache?.values ?? [:]
        }
        let running = sessions.filter { $0.activityState != nil }
        let working = running.filter { $0.activityState == "working" }.count
        let waiting = running.filter { $0.activityState == "waiting" }.count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        let out: [String: JCJSON] = [
            "coding.working": .number(Double(working)), "coding.waiting": .number(Double(waiting)),
            "coding.total": .number(Double(running.count)),
            "coding.summary": .string(parts.isEmpty ? (running.isEmpty ? "Nothing running" : "\(running.count) idle")
                                                    : parts.joined(separator: " · ")),
        ]
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
