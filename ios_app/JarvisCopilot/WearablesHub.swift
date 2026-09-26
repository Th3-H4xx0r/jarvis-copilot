import Foundation
import Combine
import Observation
import SwiftUI

/// Names the user gave their Bluetooth wearables, kept on the phone. Keyed by kind
/// (`WearableKeepAlive.bottle`, …) — the roster pairs one device per kind — so the
/// cards, device pages and the agent's device list all show the same name.
@Observable
@MainActor
final class WearableNames {
    static let shared = WearableNames()
    private static let key = "wearableCustomNames"
    private(set) var names: [String: String]

    private init() {
        names = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func name(_ kind: String, fallback: String) -> String { names[kind] ?? fallback }

    /// An empty name goes back to the device's own.
    func rename(_ kind: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[kind] = trimmed.isEmpty ? nil : String(trimmed.prefix(64))
        UserDefaults.standard.set(names, forKey: Self.key)
    }
}

/// A device page's ⋯ menu Rename: the same alert the chat list uses to rename a chat.
private struct WearableRenameAlert: ViewModifier {
    @Binding var isPresented: Bool
    let current: String
    let onSave: (String) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, shown in if shown { text = current } }
            .alert("Rename device", isPresented: $isPresented) {
                TextField("Name", text: $text)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if name != current { onSave(name) }
                }
            }
    }
}

extension View {
    func wearableRename(isPresented: Binding<Bool>, current: String, onSave: @escaping (String) -> Void) -> some View {
        modifier(WearableRenameAlert(isPresented: isPresented, current: current, onSave: onSave))
    }
}

/// The ⋯ button at the top of a wearable's page.
/// One action in a wearable screen's toolbar.
///
/// Icon only, the same shape as the ⋯ beside it. A `Button(title, jcIcon:)` here
/// carries its title into the bar, and the system stretches it into a wide pill
/// around a single glyph — next to a plain icon it reads as a different kind of
/// control entirely.
struct WearableToolbarButton: View {
    let title: String
    let icon: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            JcIcon(icon, size: 17)
                .foregroundStyle(JcTheme.accent)
                .fixedSize()            // or the bar stretches it to its own height
        }
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}

struct WearableMoreMenu<Extra: View>: View {
    let onRename: () -> Void
    /// Device-specific items — a ring's "Find", say — above Rename.
    @ViewBuilder var extra: Extra

    init(onRename: @escaping () -> Void, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.onRename = onRename
        self.extra = extra()
    }

    var body: some View {
        Menu {
            extra
            Button("Rename", jcIcon: "pencil", action: onRename)
        } label: {
            JcIcon("ellipsis").foregroundStyle(JcTheme.accent)
        }
        .accessibilityLabel("More")
    }
}

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
    /// True when the device is in its manager's live `discovered` list, so the Devices grid
    /// already draws a full card for it. A remembered board is surfaced there with an RSSI of
    /// 0 — no signal reading, but a card all the same — and the tab used to add a second
    /// "Not found" row under it for the very same device.
    var listed: Bool = false

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
            // Keep Alive, or a ring whose gestures are set: both need the link back at launch,
            // since a gesture can only reach Jarvis while the ring is connected.
            if let ringID = WearableIdentity.remembered(WearableKeepAlive.ring),
               WearableKeepAlive.isOn(WearableKeepAlive.ring)
                   || RingInputStore.shared(for: ringID).wantedMode == .jarvis {
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
                                     name: WearableNames.shared.name(WearableKeepAlive.bottle,
                                                                     fallback: live?.name ?? bottle.connected?.name ?? VsitooS1Pro.model),
                                     connected: bottle.state == .ready,
                                     rssi: live?.rssi,
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.bottle),
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.bottle),
                                     listed: live != nil))
        }
        if let id = WearableIdentity.remembered(WearableKeepAlive.scale) {
            let live = scale.discovered.first
            out.append(WearableEntry(kind: WearableKeepAlive.scale,
                                     deviceID: id,
                                     model: Esf551Scale.model,
                                     name: WearableNames.shared.name(WearableKeepAlive.scale,
                                                                     fallback: live?.name ?? scale.connected?.name ?? Esf551Scale.model),
                                     connected: scale.connected != nil && scale.state == .ready,
                                     rssi: live?.rssi,
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.scale),
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.scale),
                                     listed: live != nil))
        }
        if let id = WearableIdentity.remembered(WearableKeepAlive.esp32) {
            let live = esp32.discovered.first { $0.id == id } ?? esp32.discovered.first
            out.append(WearableEntry(kind: WearableKeepAlive.esp32,
                                     deviceID: id,
                                     model: Esp32Board.model,
                                     name: WearableNames.shared.name(WearableKeepAlive.esp32,
                                                                     fallback: live?.name ?? esp32.connected?.name ?? Esp32Board.model),
                                     connected: esp32.state == .ready,
                                     // A board on Wi-Fi has no RSSI; 0 means "remembered,
                                     // not advertising" in `DiscoveredEsp32`.
                                     rssi: (live?.rssi).flatMap { $0 == 0 ? nil : $0 },
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.esp32),
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.esp32),
                                     listed: live != nil))
        }
        if let id = WearableIdentity.remembered(WearableKeepAlive.ring) {
            let live = ring.discovered.first { $0.id == ring.connected?.id } ?? ring.discovered.first
            out.append(WearableEntry(kind: WearableKeepAlive.ring,
                                     deviceID: id,
                                     model: ColmiR12.model,
                                     name: WearableNames.shared.name(WearableKeepAlive.ring,
                                                                     fallback: live?.name ?? ring.connected?.name ?? ColmiR12.model),
                                     connected: ring.state == .ready,
                                     // A ring surfaced from iOS's own link has no RSSI (0).
                                     rssi: (live?.rssi).flatMap { $0 == 0 ? nil : $0 },
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.ring),
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.ring),
                                     listed: live != nil))
        }
        // The glasses are a Bluetooth headset iOS holds, not a link of ours: they're known
        // once the audio route has shown them, and always have their own card (`listed`).
        if let id = WearableIdentity.remembered(WearableKeepAlive.glasses) {
            let route = GlassesAudioLink.shared.state
            out.append(WearableEntry(kind: WearableKeepAlive.glasses,
                                     deviceID: id,
                                     model: InmoGo3.model,
                                     name: InmoGo3.name,
                                     connected: route.connected,
                                     rssi: nil,
                                     lastRSSI: nil,
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.glasses),
                                     listed: true))
        }
        // The Jarvis Pod talks to the server, not the phone: its card comes from JarvisPodStore.
        out.append(contentsOf: JarvisPodStore.shared.rosterEntries)
        return out
    }

    /// Record signal for anything the current scan turned up, so a device that drops
    /// out of range keeps a last-known reading to show.
    private func noteWhatWeCanSee() {
        note(WearableKeepAlive.bottle, connected: bottle.state == .ready,
             rssi: bottle.discovered.first(where: { $0.rssi != 0 })?.rssi)
        note(WearableKeepAlive.scale, connected: scale.state == .ready,
             rssi: scale.discovered.first(where: { $0.rssi != 0 })?.rssi)
        note(WearableKeepAlive.esp32, connected: esp32.state == .ready,
             rssi: esp32.discovered.first(where: { $0.rssi != 0 })?.rssi)
        note(WearableKeepAlive.ring, connected: ring.state == .ready,
             rssi: ring.discovered.first(where: { $0.rssi != 0 })?.rssi)
        note(WearableKeepAlive.glasses, connected: GlassesAudioLink.shared.state.connected, rssi: nil)
    }

    /// A device is seen when a scan turns it up OR while we hold a link to it.
    ///
    /// The second half was missing, and it is the common case: connecting stops
    /// the scan, so a connected device never shows up in `discovered` again. A
    /// ring worn for four days straight therefore still read "last seen 4d ago"
    /// the moment it disconnected — the timestamp was from the last scan that
    /// happened to catch it before it linked.
    private func note(_ kind: String, connected: Bool, rssi: Int?) {
        if connected {
            WearableIdentity.noteSeenNow(kind)
            return
        }
        // An RSSI of 0 is a remembered device put in the list, not a sighting —
        // noting it made "last seen" read "just now" forever.
        if let rssi { WearableIdentity.noteSeen(kind, rssi: rssi) }
    }

    /// Register every device the user has already shared, with no live link required,
    /// plus the always-present `wearables_*` hub. Runs before any Bluetooth work so the
    /// catalogue the server receives on `hello` is already complete.
    func restoreSharedDevices() {
        // Here rather than on foreground only: a background launch reads the roster too.
        GlassesAudioLink.shared.start()
        WearableIdentity.seedFromSharedRecords(BridgeClient.sharedRecords)
        bottle.publishRemembered()
        scale.publishRemembered()
        esp32.publishRemembered()
        ring.publishRemembered()
        DeviceRegistry.shared.register(WearablesDevice())
        BridgeClient.shared.sendRegistration()
        registerHealthIntegrations()
    }

    /// Tell the server which wearables report enough to be scored.
    ///
    /// This is what brings a health integration into existence: without it the
    /// server has no space for the ring and every health call 404s. Idempotent,
    /// so running it on each launch and pairing is free.
    func registerHealthIntegrations() {
        let eligible = roster().filter { HealthEligibility.kinds.contains($0.kind) }
        guard !eligible.isEmpty, BridgeClient.shared.isPaired else { return }
        // Without the phone's own id the server has nothing to invoke through,
        // so there is no point registering yet; the next launch tries again.
        guard let phone = UserDefaults.standard.string(forKey: PushHandler.deviceIDKey), !phone.isEmpty else {
            JcLog.services.notice("health: no paired device id yet; registering wearables later")
            return
        }
        // Three things the server cannot work out for itself: the wearable's own
        // id (which its space is named from), the phone whose bridge reaches it,
        // and the timezone whose days its data is bucketed by.
        // The server-issued id for this phone, which is what the device bridge
        // routes a skill call to.
        let payload = eligible.map { entry -> [String: Any] in
            [
                "kind": entry.kind,
                "device_id": entry.deviceID,
                "name": entry.name,
                "bridge_device_id": phone,
                "timezone": TimeZone.current.identifier,
            ]
        }
        Task {
            do {
                _ = try await HealthClient.register(payload)
            } catch {
                JcLog.services.notice("health: could not register wearables — \(error.localizedDescription, privacy: .public)")
            }
        }
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
            // Only this ring: any R-series ring nearby answers a scan, and whichever connects
            // gets its clock set and its data filed as this user's.
            guard let found = await waitFor(timeout: timeout, {
                self.ring.discovered.first { $0.id.uuidString == deviceID }
            }) else { return false }
            if ring.connected?.id != found.id || !ring.linkIsUp { ring.connect(found) }
            return await waitUntil(timeout: timeout) { self.ring.state == .ready }
        case WearableKeepAlive.glasses:
            // iOS holds the glasses' Bluetooth audio; there is no link of ours to open.
            GlassesAudioLink.shared.refresh()
            return GlassesAudioLink.shared.state.connected
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
