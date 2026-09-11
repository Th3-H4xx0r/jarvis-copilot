import Foundation
import Combine

/// One paired wearable as both the agent and the Devices list see it.
///
/// The list used to be `manager.discovered` — a live scan buffer that `startScan()`
/// clears — so a bottle that was merely out of range disappeared from the UI and
/// from the agent's tools at the same time. The roster is remembered ∪ discovered,
/// so a paired device always has a row and carries a status instead.
struct WearableEntry: Identifiable {
    /// `WearableKeepAlive.bottle` / `.scale` / `.esp32`.
    let kind: String
    let deviceID: String
    let model: String
    let name: String
    let connected: Bool
    /// Signal from the current scan. Nil when it wasn't seen this time round.
    let rssi: Int?
    let lastRSSI: Int?
    let lastSeen: Date?

    var id: String { deviceID }
    var seenInLastScan: Bool { rssi != nil }

    var statusText: String {
        if connected { return "Connected" }
        if let rssi { return "\(rssi) dBm" }
        return "Not found"
    }

    var json: [String: Any] {
        var out: [String: Any] = [
            "device_id": deviceID,
            "model": model,
            "name": name,
            "connected": connected,
            "seen_in_last_scan": seenInLastScan,
            "status": statusText,
        ]
        if let rssi { out["rssi"] = rssi }
        if let lastRSSI { out["last_rssi"] = lastRSSI }
        if let lastSeen { out["last_seen"] = ISO8601DateFormatter().string(from: lastSeen) }
        return out
    }
}

/// App-lifetime owner of the Bluetooth wearables: the water bottle, the scale
/// and the ESP32 boards.
///
/// In the legacy JarvisWearables app these managers lived in `ScanView`, which
/// WAS the Devices tab and therefore existed for the life of the app. In the
/// Copilot shell `ScanView` is one segment of the Devices page and is only
/// built while that segment is selected — so the managers only existed while
/// the user was looking at the Wearables list, the bottle never reconnected
/// on its own, and its skills never reached the server ("start sterilisation"
/// fell through to Shortcuts). The hub restores the legacy behaviour: created
/// at launch, driven by the app's scene phase, reconnecting the known bottle
/// so its skills are registered whether or not any device screen is open.
@MainActor
final class WearablesHub: ObservableObject {
    static let shared = WearablesHub()

    let bottle = BottleManager()
    let scale = ScaleManager()
    let esp32 = Esp32Manager()
    let ring = RingManager()

    private var reconnectTask: Task<Void, Never>?

    private init() {}

    /// Foreground: resume links, reconnect the remembered bottle, re-register.
    func appDidBecomeActive() {
        restoreSharedDevices()
        bottle.enterForeground()
        ring.enterForeground()
        if WearableKeepAlive.isOn(WearableKeepAlive.esp32) { esp32.resumeIfNeeded() }
        reconnectKnownDevices()
    }

    /// Background: the managers drop idle links (or hold them in bridge mode),
    /// exactly as the legacy `ScanView` did on `.background`.
    func appDidEnterBackground() {
        reconnectTask?.cancel()
        bottle.enterBackground()
        ring.enterBackground()
    }

    /// Bring the last-used bottle back without anyone opening the Devices tab,
    /// so `bottle_*` skills are advertised to the server. Best effort and
    /// bounded: Bluetooth may be off, or the bottle out of range.
    func reconnectKnownDevices() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            // Give CoreBluetooth a moment to report its power state after launch.
            for _ in 0..<20 where !self.bottle.bluetoothReady {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard self.bottle.bluetoothReady, !Task.isCancelled else { return }
            // Keep Alive off: don't reach for the bottle at all. It is connected
            // on demand instead — see BottleManager.ensureConnected.
            if WearableKeepAlive.isOn(WearableKeepAlive.bottle) {
                if await self.bottle.ensureConnected(timeout: 15) == false {
                    JcLog.services.notice("wearables: bottle not reachable at launch")
                }
            }
            if WearableKeepAlive.isOn(WearableKeepAlive.scale) { self.scale.startScan() }
            // The ring has its own central, which reports power separately.
            if WearableKeepAlive.isOn(WearableKeepAlive.ring),
               WearableIdentity.remembered(WearableKeepAlive.ring) != nil {
                for _ in 0..<20 where !self.ring.bluetoothReady {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                }
                if await self.ring.ensureConnected(timeout: 15) == false {
                    JcLog.services.notice("wearables: ring not reachable at launch")
                }
            }
        }
    }

    // MARK: Roster

    /// Every paired wearable, whether or not it is currently reachable — the single
    /// source both `ScanView` and the `wearables_*` skills read, so the cards and the
    /// agent never disagree about what exists.
    func roster() -> [WearableEntry] {
        noteWhatWeCanSee()
        var out: [WearableEntry] = []

        if let id = WearableIdentity.remembered(WearableKeepAlive.bottle) {
            let live = bottle.discovered.first { $0.id == bottle.connected?.id } ?? bottle.discovered.first
            out.append(WearableEntry(kind: WearableKeepAlive.bottle,
                                     deviceID: id,
                                     model: VsitooS1Pro.model,
                                     name: live?.name ?? bottle.connected?.name ?? VsitooS1Pro.model,
                                     connected: bottle.state == .ready,
                                     rssi: live?.rssi,
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.bottle),
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.bottle)))
        }
        if let id = WearableIdentity.remembered(WearableKeepAlive.scale) {
            let live = scale.discovered.first
            out.append(WearableEntry(kind: WearableKeepAlive.scale,
                                     deviceID: id,
                                     model: Esf551Scale.model,
                                     name: live?.name ?? scale.connected?.name ?? Esf551Scale.model,
                                     connected: scale.connected != nil && scale.state == .ready,
                                     rssi: live?.rssi,
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.scale),
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.scale)))
        }
        if let id = WearableIdentity.remembered(WearableKeepAlive.esp32) {
            let live = esp32.discovered.first { $0.id == id } ?? esp32.discovered.first
            out.append(WearableEntry(kind: WearableKeepAlive.esp32,
                                     deviceID: id,
                                     model: Esp32Board.model,
                                     name: live?.name ?? esp32.connected?.name ?? Esp32Board.model,
                                     connected: esp32.state == .ready,
                                     // A board on Wi-Fi has no RSSI; 0 means "remembered,
                                     // not advertising" in `DiscoveredEsp32`.
                                     rssi: (live?.rssi).flatMap { $0 == 0 ? nil : $0 },
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.esp32),
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.esp32)))
        }
        if let id = WearableIdentity.remembered(WearableKeepAlive.ring) {
            let live = ring.discovered.first { $0.id == ring.connected?.id } ?? ring.discovered.first
            out.append(WearableEntry(kind: WearableKeepAlive.ring,
                                     deviceID: id,
                                     model: ColmiR12.model,
                                     name: live?.name ?? ring.connected?.name ?? ColmiR12.model,
                                     connected: ring.state == .ready,
                                     // A ring surfaced from iOS's own link has no RSSI (0).
                                     rssi: (live?.rssi).flatMap { $0 == 0 ? nil : $0 },
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.ring),
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.ring)))
        }
        return out
    }

    /// Record signal for anything the current scan turned up, so a device that drops
    /// out of range keeps a last-known reading to show.
    private func noteWhatWeCanSee() {
        if let r = bottle.discovered.first?.rssi {
            WearableIdentity.noteSeen(WearableKeepAlive.bottle, rssi: r)
        }
        if let r = scale.discovered.first?.rssi {
            WearableIdentity.noteSeen(WearableKeepAlive.scale, rssi: r)
        }
        if let r = esp32.discovered.first(where: { $0.rssi != 0 })?.rssi {
            WearableIdentity.noteSeen(WearableKeepAlive.esp32, rssi: r)
        }
        if let r = ring.discovered.first(where: { $0.rssi != 0 })?.rssi {
            WearableIdentity.noteSeen(WearableKeepAlive.ring, rssi: r)
        }
    }

    /// Register every device the user has already shared, with no live link required,
    /// plus the always-present `wearables_*` hub. Runs before any Bluetooth work so the
    /// catalogue the server receives on `hello` is already complete.
    func restoreSharedDevices() {
        WearableIdentity.seedFromSharedRecords(BridgeClient.sharedRecords)
        bottle.publishRemembered()
        scale.publishRemembered()
        esp32.publishRemembered()
        ring.publishRemembered()
        DeviceRegistry.shared.register(WearablesDevice())
        BridgeClient.shared.sendRegistration()
    }

    /// Bring one paired device's link up on request. Only devices the user has already
    /// shared are eligible — the agent never pairs something new.
    func connect(deviceID: String, timeout: TimeInterval = 12) async -> Bool {
        guard let entry = roster().first(where: { $0.deviceID == deviceID }) else { return false }
        switch entry.kind {
        case WearableKeepAlive.bottle:
            return await bottle.ensureConnected(timeout: timeout)
        case WearableKeepAlive.scale:
            if scale.connected != nil, scale.state == .ready { return true }
            scale.startScan()
            guard let found = await waitFor(timeout: timeout, { self.scale.discovered.first }) else { return false }
            scale.connect(found)
            return await waitUntil(timeout: timeout) { self.scale.state == .ready }
        case WearableKeepAlive.esp32:
            if esp32.state == .ready { return true }
            esp32.startScan()
            guard let found = await waitFor(timeout: timeout, {
                self.esp32.discovered.first { $0.id == deviceID } ?? self.esp32.discovered.first
            }) else { return false }
            esp32.connect(found)
            return await waitUntil(timeout: timeout) { self.esp32.state == .ready }
        case WearableKeepAlive.ring:
            // A known peripheral reopens by identifier; otherwise find it by scanning.
            if await ring.ensureConnected(timeout: 3) { return true }
            ring.startScan()
            guard let found = await waitFor(timeout: timeout, {
                self.ring.discovered.first { $0.id.uuidString == deviceID } ?? self.ring.discovered.first
            }) else { return false }
            if ring.connected?.id != found.id || !ring.linkIsUp { ring.connect(found) }
            return await waitUntil(timeout: timeout) { self.ring.state == .ready }
        default:
            return false
        }
    }

    private func waitFor<T>(timeout: TimeInterval, _ probe: @escaping () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = probe() { return v }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return probe()
    }

    private func waitUntil(timeout: TimeInterval, _ done: @escaping () -> Bool) async -> Bool {
        await waitFor(timeout: timeout) { done() ? true : nil } ?? false
    }

    /// A bounded scan for the `wearables_scan` skill.
    func scan(seconds: TimeInterval) async -> [WearableEntry] {
        rescanAll()
        try? await Task.sleep(for: .seconds(seconds))
        return roster()
    }

    /// The Devices tab's "Rescan".
    func rescanAll() {
        bottle.startScan()
        scale.startScan()
        esp32.startScan()
        ring.startScan()
    }
}
