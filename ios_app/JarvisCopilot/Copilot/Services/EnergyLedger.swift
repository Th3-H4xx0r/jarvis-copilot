import Foundation
import Network
import UIKit

/// Where the phone's battery went, hour by hour: kept on the phone for Settings → Battery usage,
/// and sent to the server with the hourly probe.
///
/// iOS's own Battery screen says "Background 17 h" and nothing else. This splits that time by what
/// the app was doing — on screen (which tab, which screen), in a pocket with or without the
/// keepalive, on Wi-Fi or cellular, in Low Power Mode, charging — with the CPU each state burned,
/// the battery level at each end of the hour, and counts of what woke the radio (bridge frames,
/// requests by feature).
///
/// Thread-safe: the bridge, the HTTP transport and Bluetooth callbacks count from wherever they run.
final class EnergyLedger: @unchecked Sendable {
    static let shared = EnergyLedger()

    enum Flag: String, CaseIterable, Sendable {
        case foreground, keepalive, bridge, lowPower, charging
    }

    /// One hour of the app's life (or the stretch between two probes, when iOS had it suspended).
    struct Hour: Codable, Equatable, Sendable, Identifiable {
        var start: Date
        var end: Date
        /// Wall seconds in each state: `foreground` / `background`; the network (`wifi`, `cellular`,
        /// `wired`, `offline`, `other`); `keepalive`, `bridge`, `lowPower`, `charging`; while on
        /// screen `tab.<tab>` and `where.<tab>|<screen title>` (title empty at a tab's root);
        /// in a pocket `left.<tab>|<screen title>`, the screen left open;
        /// `link.<wearable>` while its Bluetooth link is up; and
        /// `bg.<key>` for the background share of any of them.
        var seconds: [String: Double] = [:]
        /// CPU seconds burned in each of those states.
        var cpu: [String: Double] = [:]
        /// What woke the radio or the CPU: `bridge.in`, `bridge.out`, `bridge.out_bytes`, `bridge.drop`,
        /// `register.sent.<caller>` / `register.same.<caller>` (skill catalogue sent, or unchanged and
        /// kept home), `keepalive.reassert` / `restart`, `keepalive.smart.sleep` / `wake` (Smart let it
        /// go on cellular, or took it back), `net.<feature>`, `net.bg.<feature>`,
        /// `bytes.<feature>`.
        var counts: [String: Int] = [:]
        /// The battery level (0–1) when the hour began and ended.
        var batteryStart: Double?
        var batteryEnd: Double?
        /// CPU seconds by thread name, from the hourly probe.
        var threads: [String: Double] = [:]

        var id: Date { start }
        var wall: Double { max(0, end.timeIntervalSince(start)) }
        func seconds(_ key: String) -> Double { seconds[key] ?? 0 }
        func cpu(_ key: String) -> Double { cpu[key] ?? 0 }
        func count(_ key: String) -> Int { counts[key] ?? 0 }
        var totalCPU: Double { cpu("foreground") + cpu("background") }
        /// Battery points lost in the hour; nil when either end is unknown or it charged.
        var drained: Double? {
            guard let a = batteryStart, let b = batteryEnd, seconds("charging") < 60, a >= b else { return nil }
            return (a - b) * 100
        }
    }

    /// The battery level whenever iOS said it changed.
    struct Sample: Codable, Equatable, Sendable {
        var at: Date
        var level: Double
        var charging: Bool
    }

    /// A stretch the app was on screen.
    struct Span: Codable, Equatable, Sendable {
        var start: Date
        var end: Date
    }

    /// Hours kept on the phone.
    static let keepHours = 96
    static let keepSamples = 1500
    static let keepSpans = 400

    private let lock = NSLock()
    private let cpuClock: @Sendable () -> Double
    private let clock: @Sendable () -> Date
    private let file: URL?
    private var flags: Set<Flag> = [.foreground]
    private var network = "other"
    private var tab: String?
    private var screens: [String] = []
    /// Wearables with a live Bluetooth link, by name.
    private var links: Set<String> = []
    private var hour: Hour
    private var history: [Hour] = []
    private var samples: [Sample] = []
    private var spans: [Span] = []
    private var foregroundSince: Date?
    private var lastAt: Date
    private var lastCPU: Double
    private var monitor: NWPathMonitor?
    private var watches: [NSObjectProtocol] = []

    init(cpu: @escaping @Sendable () -> Double = { MetricKitReporter.cpuSeconds() },
         now: @escaping @Sendable () -> Date = { Date() },
         file: URL? = EnergyLedger.defaultFile) {
        cpuClock = cpu
        clock = now
        self.file = file
        let t = now()
        hour = Hour(start: t, end: t)
        lastAt = t
        lastCPU = cpu()
        foregroundSince = t
        load()
    }

    static var defaultFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("energy-ledger.json")
    }

    // MARK: - Starting (main thread: UIDevice)

    /// The network path, Low Power Mode and the charger, watched from launch.
    @MainActor
    func start() {
        guard monitor == nil else { return }
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.setNetwork(Self.kind(of: path)) }
        monitor.start(queue: DispatchQueue(label: "jc.energy.path", qos: .utility))
        self.monitor = monitor
        set(.lowPower, ProcessInfo.processInfo.isLowPowerModeEnabled)
        readBattery(device)
        lock.withLock { if hour.batteryStart == nil { hour.batteryStart = Self.level(device) } }
        let center = NotificationCenter.default
        watches.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.set(.lowPower, ProcessInfo.processInfo.isLowPowerModeEnabled)
        })
        for name in [UIDevice.batteryStateDidChangeNotification, UIDevice.batteryLevelDidChangeNotification] {
            watches.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readBattery(UIDevice.current) }
            })
        }
    }

    @MainActor
    private func readBattery(_ device: UIDevice) {
        let charging = device.batteryState == .charging || device.batteryState == .full
        set(.charging, charging)
        guard let level = Self.level(device) else { return }
        lock.withLock {
            if let last = samples.last, last.level == level, last.charging == charging { return }
            samples.append(Sample(at: clock(), level: level, charging: charging))
            if samples.count > Self.keepSamples { samples.removeFirst(samples.count - Self.keepSamples) }
        }
    }

    @MainActor
    static func level(_ device: UIDevice = .current) -> Double? {
        let level = device.batteryLevel
        return level < 0 ? nil : Double(level)
    }

    // MARK: - State

    func set(_ flag: Flag, _ on: Bool) {
        let leftScreen: Bool = lock.withLock {
            guard flags.contains(flag) != on else { return false }
            markLocked()
            if on { flags.insert(flag) } else { flags.remove(flag) }
            guard flag == .foreground else { return false }
            if on {
                foregroundSince = clock()
            } else if let since = foregroundSince {
                spans.append(Span(start: since, end: clock()))
                if spans.count > Self.keepSpans { spans.removeFirst(spans.count - Self.keepSpans) }
                foregroundSince = nil
            }
            return !on
        }
        // Into a pocket: the moment the process may be suspended or killed.
        if leftScreen { save() }
    }

    func setNetwork(_ kind: String) {
        lock.withLock {
            guard kind != network else { return }
            markLocked()
            network = kind
        }
    }

    func setTab(_ tab: String?) {
        lock.withLock {
            guard tab != self.tab else { return }
            markLocked()
            self.tab = tab
        }
    }

    /// A titled screen (`.jcScreen`) came on; the newest one showing is the one charged.
    func screenAppeared(_ name: String) {
        lock.withLock {
            markLocked()
            screens.removeAll { $0 == name }
            screens.append(name)
        }
    }

    func screenDisappeared(_ name: String) {
        lock.withLock {
            markLocked()
            screens.removeAll { $0 == name }
        }
    }

    /// The wearables linked right now. A held link wakes the phone for every reading it sends.
    func setLinks(_ names: Set<String>) {
        lock.withLock {
            guard names != links else { return }
            markLocked()
            links = names
        }
    }

    func count(_ key: String, by n: Int = 1) {
        lock.withLock { hour.counts[key, default: 0] += n }
    }

    /// One request to the server: counted under its feature, with its bytes both ways.
    func request(path: String, bytes: Int, background: Bool) {
        let feature = Self.feature(for: path)
        lock.withLock {
            hour.counts["net.\(feature)", default: 0] += 1
            if background { hour.counts["net.bg.\(feature)", default: 0] += 1 }
            hour.counts["bytes.\(feature)", default: 0] += bytes
        }
    }

    /// Ends the running hour now and starts the next. The probe calls this every hour.
    @discardableResult
    func closeHour(threads: [String: Double], battery: Double?) -> Hour {
        let done: Hour = lock.withLock {
            markLocked()
            var done = hour
            done.end = clock()
            done.threads = threads
            done.batteryEnd = battery
            // Two closes in one instant would file an empty hour sharing the next one's start.
            if done.wall >= 1 { history.append(done) }
            if history.count > Self.keepHours { history.removeFirst(history.count - Self.keepHours) }
            hour = Hour(start: done.end, end: done.end, batteryStart: battery)
            return done
        }
        save()
        return done
    }

    /// Every kept hour, oldest first, then the running one (counted up to now).
    func timeline() -> [Hour] {
        lock.withLock {
            markLocked()
            var open = hour
            open.end = clock()
            return history + (open.wall > 0 ? [open] : [])
        }
    }

    func batterySamples() -> [Sample] { lock.withLock { samples } }

    /// Stretches on screen, the running one included.
    func screenSpans() -> [Span] {
        lock.withLock { spans + (foregroundSince.map { [Span(start: $0, end: clock())] } ?? []) }
    }

    // MARK: - Attribution

    /// Charges the time and CPU since the last mark to the state that held until now.
    private func markLocked() {
        let t = clock()
        let c = cpuClock()
        let wall = max(0, t.timeIntervalSince(lastAt))
        let used = max(0, c - lastCPU)
        lastAt = t
        lastCPU = c
        guard wall > 0 || used > 0 else { return }
        let foreground = flags.contains(.foreground)
        var keys = [foreground ? "foreground" : "background", network]
        keys += Flag.allCases.filter { $0 != .foreground && flags.contains($0) }.map(\.rawValue)
        keys += links.sorted().map { "link.\($0)" }
        if foreground {
            if let tab { keys.append("tab.\(tab)") }
            // Exactly one place per on-screen second, so a ranking never counts it twice.
            keys.append("where.\(tab ?? "app")|\(screens.last ?? "")")
        }
        for key in keys {
            hour.seconds[key, default: 0] += wall
            hour.cpu[key, default: 0] += used
            guard !foreground, key != "background" else { continue }
            hour.seconds["bg.\(key)", default: 0] += wall
            hour.cpu["bg.\(key)", default: 0] += used
        }
        if !foreground {
            // The screen left open: SwiftUI still redraws it in a pocket whenever its data changes.
            let left = "left.\(tab ?? "app")|\(screens.last ?? "")"
            hour.seconds[left, default: 0] += wall
            hour.cpu[left, default: 0] += used
        }
    }

    static func kind(of path: NWPath) -> String {
        guard path.status == .satisfied else { return "offline" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "other"
    }

    /// The feature a server path belongs to, as the Battery page names it.
    static func feature(for path: String) -> String {
        let p = path.lowercased()
        if p.contains("/health/history") { return "Health history" }
        if p.contains("/health/day") { return "Health uploads" }
        if p.contains("/health") { return "Health" }
        if p.hasPrefix("/api/session") || p.hasPrefix("/api/chat") || p.hasPrefix("/api/models") { return "Chat" }
        if p.hasPrefix("/api/coding") { return "Coding agents" }
        if p.hasPrefix("/api/voice") || p.hasPrefix("/api/live") { return "Voice" }
        if p.hasPrefix("/api/dashcam") { return "Dashcam" }
        if p.hasPrefix("/api/devices/mobile/energy") { return "Battery reports" }
        if p.hasPrefix("/api/devices/mobile") { return "Commands queue" }
        if p.hasPrefix("/api/devices") || p.hasPrefix("/api/pods") { return "Devices" }
        if p.hasPrefix("/api/widgets") || p.hasPrefix("/api/island") { return "Widgets & island" }
        if p.hasPrefix("/api/door") { return "Door alarm" }
        if p.hasPrefix("/api/car") || p.hasPrefix("/api/toyota") { return "Car" }
        if p.hasPrefix("/api/harnesses") { return "Harnesses" }
        let parts = p.split(separator: "/").filter { $0 != "api" }
        return parts.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Other"
    }

    // MARK: - Disk

    private struct Saved: Codable {
        var history: [Hour]
        var open: Hour?
        var samples: [Sample]?
        var spans: [Span]?
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// The last process's hours, its unfinished one closed where it was last saved.
    private func load() {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? Self.decoder().decode(Saved.self, from: data) else { return }
        history = saved.history
        if let open = saved.open, open.wall > 0 { history.append(open) }
        if history.count > Self.keepHours { history.removeFirst(history.count - Self.keepHours) }
        samples = saved.samples ?? []
        spans = saved.spans ?? []
    }

    func save() {
        guard let file else { return }
        let data: Data? = lock.withLock {
            markLocked()
            var open = hour
            open.end = clock()
            return try? Self.encoder().encode(Saved(history: history, open: open, samples: samples, spans: spans))
        }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
