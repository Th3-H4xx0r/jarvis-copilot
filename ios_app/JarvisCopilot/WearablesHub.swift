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

extension WearableNames {
    /// ESP32 boards are named one by one: several can be paired at once (the glasses relay, the
    /// door alarm's proxy), so one name per kind renamed every board together.
    static func esp32Key(_ deviceID: String) -> String { "\(WearableKeepAlive.esp32):\(deviceID)" }
    func esp32Name(id: String, fallback: String) -> String { name(Self.esp32Key(id), fallback: fallback) }
    func renameEsp32(id: String, to name: String) { rename(Self.esp32Key(id), to: name) }
}

extension DiscoveredEsp32 {
    /// The board's own ID once it is known (the same over Bluetooth and Wi‑Fi), else the card's.
    var stableID: String { record?.deviceID ?? id }
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
            // The page's action pill: glyphs in the text colour, like `JcPageButton`.
            JcIcon(icon, size: 17, weight: .semibold)
                .foregroundStyle(JcTheme.text)
                .fixedSize()            // or the bar stretches it to its own height
        }
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}

/// The sync glyph turning, in the accent: what a toolbar's Sync shows while it runs.
struct JcSyncSpinner: View {
    var size: CGFloat = 17

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(JcTheme.accent)
                .rotationEffect(.degrees((t * 240).truncatingRemainder(dividingBy: 360)))
        }
        .fixedSize()
    }
}

/// The ⋯ button at the top of a wearable's page.
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
            JcIcon("ellipsis", size: 17, weight: .semibold).foregroundStyle(JcTheme.text)
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
    let x5 = X5Manager()
    let band = BandManager()
    let glasses = InmoGo3Device.shared

    private var reconnectTask: Task<Void, Never>?
    /// Roster changes, debounced, sent to the server so the Mac's menu can show them without
    /// asking the phone (`sendStateSoon`).
    private var stateWatch: AnyCancellable?
    private var stateSoon: Task<Void, Never>?
    private var sentState: String?

    private init() {
        // The X5 tracks workouts through the same controller as the R12: one live sheet,
        // Health card and Live Activity, whichever ring the start screen picks.
        let x5 = self.x5
        ring.workout.add(X5WorkoutWearable(
            session: x5.session,
            connect: { [weak x5] in
                guard let x5, await x5.ensureConnected(timeout: 12) else { return false }
                await x5.waitForSetup(timeout: 8)
                return true
            },
            disconnect: { [weak x5] in x5?.disconnect() },
            release: { [weak x5] in x5?.releaseIfIdle() },
            deviceID: { [weak x5] in x5?.deviceID },
            state: x5.$state.eraseToAnyPublisher()))
        let workout = ring.workout
        x5.workoutHold = { [weak workout] in workout?.holdsLink(for: WearableKeepAlive.x5ring) ?? false }
        x5.workouts = workout
        // The band too: its own adapter makes the ticks (it has no per-second workout packet).
        let band = self.band
        workout.add(BandWorkoutWearable(
            session: band.session,
            connect: { [weak band] in
                guard let band, await band.ensureConnected(timeout: 12) else { return false }
                await band.waitForSetup(timeout: 8)
                return true
            },
            disconnect: { [weak band] in band?.disconnect() },
            release: { [weak band] in band?.releaseIfIdle() },
            deviceID: { [weak band] in band?.deviceID },
            state: band.$state.eraseToAnyPublisher()))
        band.workoutHold = { [weak workout] in workout?.holdsLink(for: WearableKeepAlive.band) ?? false }
        band.workouts = workout
        let changes = bluetoothWearables.map { $0.manager.objectWillChange.map { _ in () }.eraseToAnyPublisher() }
            + [esp32.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
               glasses.objectWillChange.map { _ in () }.eraseToAnyPublisher()]
        stateWatch = Publishers.MergeMany(changes)
            // A manager may publish off the main thread (a Bluetooth callback): hop first.
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { WearablesHub.shared.sendStateSoon() } }
    }

    /// The roster as the server keeps it for the Mac's menu: who is paired and linked, without the
    /// signal readings that change on every scan (those would make every scan a send).
    nonisolated static func stateRows(_ entries: [WearableEntry]) -> [[String: Any]] {
        entries.map { ["device_id": $0.deviceID, "kind": $0.kind, "model": $0.model, "name": $0.name,
                       "connected": $0.connected] }
    }

    /// Sends the roster 2 s after the last change, and only when it differs from what the server
    /// already has. `force` sends it whatever was sent before (the socket just came back).
    func sendStateSoon(force: Bool = false) {
        if force { sentState = nil }
        stateSoon?.cancel()
        stateSoon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let roster = self.roster()
            // Settings → Battery usage: how long each wearable held a link.
            EnergyLedger.shared.setLinks(Set(roster.filter(\.connected).map(\.name)))
            let rows = Self.stateRows(roster)
            guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
                  let encoded = String(data: data, encoding: .utf8), encoded != self.sentState,
                  BridgeClient.shared.status == .online else { return }
            self.sentState = encoded
            BridgeClient.shared.sendEvent("wearables_state", ["wearables": rows])
        }
    }

    typealias BluetoothWearable = (kind: WearableKind, manager: BLEWearableManager, model: String, fallbackName: String)

    /// The wearables on the shared Bluetooth link (BLEWearableManager), with what their card shows.
    var bluetoothWearables: [BluetoothWearable] {
        linkedWearables + [(.scale, scale, Esf551Scale.model, Esf551Scale.model)]
    }

    /// Those whose link is reopened by identifier and held by Keep Alive. Not the scale: it sleeps
    /// between weighings and may change its address, so only a scan finds it.
    var linkedWearables: [BluetoothWearable] {
        [(.bottle, bottle, VsitooS1Pro.model, VsitooS1Pro.model),
         (.ring, ring, ColmiR12.model, ColmiR12.model),
         (.x5ring, x5, X5Ring.model, X5Ring.model),
         (.band, band, BandDevice.model, BandDevice.fallbackName)]
    }

    /// Foreground: resume links, reconnect remembered devices, re-register.
    func appDidBecomeActive() {
        restoreSharedDevices()
        for linked in linkedWearables { linked.manager.enterForeground() }
        if WearableKeepAlive.isOn(WearableKeepAlive.glasses) { Task { try? await glasses.session.reconnectOnOpen() } }
        if WearableKeepAlive.isOn(WearableKeepAlive.esp32) { esp32.resumeIfNeeded() }
        reconnectKnownDevices()
    }

    /// Background: the managers drop idle links (or hold them in bridge mode),
    /// exactly as the legacy `ScanView` did on `.background`.
    func appDidEnterBackground() {
        reconnectTask?.cancel()
        for linked in linkedWearables { linked.manager.enterBackground() }
    }

    /// Bring remembered devices with Keep Alive back without anyone opening the Devices tab,
    /// so their skills are advertised to the server. Best effort and bounded: Bluetooth may
    /// be off, or the device out of range.
    func reconnectKnownDevices() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            if WearableKeepAlive.isOn(WearableKeepAlive.scale) { self.scale.startScan() }
            // Each linked wearable has its own central, which reports power separately.
            // Keep Alive alone brings the link back at launch. Gestures only reach Jarvis over a
            // live link, so they ride on it — off means off, to save the device's battery.
            for linked in self.linkedWearables {
                let kind = linked.kind.rawValue, manager = linked.manager
                guard WearableIdentity.remembered(kind) != nil, WearableKeepAlive.isOn(kind) else { continue }
                for _ in 0..<20 where !manager.bluetoothReady {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                }
                if await manager.ensureConnected(timeout: 15) == false {
                    JcLog.services.notice("wearables: \(manager.linkLogName, privacy: .public) not reachable at launch")
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

        if let id = WearableIdentity.remembered(WearableKeepAlive.esp32) {
            let live = esp32.discovered.first { $0.id == id } ?? esp32.discovered.first
            out.append(WearableEntry(kind: WearableKeepAlive.esp32,
                                     deviceID: id,
                                     model: Esp32Board.model,
                                     name: WearableNames.shared.esp32Name(id: id,
                                                                          fallback: live?.name ?? esp32.connected?.name ?? Esp32Board.model),
                                     connected: esp32.state == .ready,
                                     // A board on Wi-Fi has no RSSI; 0 means "remembered,
                                     // not advertising" in `DiscoveredEsp32`.
                                     rssi: (live?.rssi).flatMap { $0 == 0 ? nil : $0 },
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.esp32),
                                     lastSeen: WearableIdentity.lastSeen(WearableKeepAlive.esp32),
                                     listed: live != nil))
        }
        for linked in bluetoothWearables {
            let kind = linked.kind.rawValue, manager = linked.manager
            guard let id = WearableIdentity.remembered(kind) else { continue }
            let live = manager.discovered.first { $0.id == manager.connected?.id } ?? manager.discovered.first
            out.append(WearableEntry(kind: kind,
                                     deviceID: id,
                                     model: linked.model,
                                     name: WearableNames.shared.name(kind,
                                                                     fallback: live?.name ?? manager.connected?.name ?? linked.fallbackName),
                                     connected: manager.state == .ready,
                                     // A device surfaced from iOS's own link has no RSSI (0).
                                     rssi: (live?.rssi).flatMap { $0 == 0 ? nil : $0 },
                                     lastRSSI: WearableIdentity.lastRSSI(kind),
                                     lastSeen: WearableIdentity.lastSeen(kind),
                                     listed: live != nil))
        }
        // Control identity stays stable independently of the remembered audio port.
        // The glasses always have their own card (`listed`).
        if WearableIdentity.remembered(WearableKeepAlive.glasses) != nil || WearableIdentity.remembered("inmoGo3Control") != nil {
            let id = glasses.deviceID
            out.append(WearableEntry(kind: WearableKeepAlive.glasses,
                                     deviceID: id,
                                     model: InmoGo3.model,
                                     name: InmoGo3.name,
                                     connected: glasses.isConnected,
                                     rssi: glasses.session.rssi,
                                     lastRSSI: WearableIdentity.lastRSSI(WearableKeepAlive.glasses),
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
        note(WearableKeepAlive.esp32, connected: esp32.state == .ready,
             rssi: esp32.discovered.first(where: { $0.rssi != 0 })?.rssi)
        for linked in bluetoothWearables {
            note(linked.kind.rawValue, connected: linked.manager.state == .ready,
                 rssi: linked.manager.discovered.first(where: { $0.rssi != 0 })?.rssi)
        }
        note(WearableKeepAlive.glasses, connected: glasses.isConnected, rssi: nil)
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
        for wearable in bluetoothWearables { wearable.manager.publishRemembered() }
        esp32.publishRemembered()
        esp32.holdRelayLink()
        InmoTeleprompter.shared.install(on: glasses)
        InmoAIChannel.shared.install(on: glasses)
        GlassesNoteRecorder.shared.install()
        GlassesTranslator.shared.install()
        GlassesFaceLink.shared.install()
        LiveLensBridge.shared.install()
        // Live never records through the glasses as a phone call.
        AudioSessionArbiter.ambientAvoidsCallMic = {
            InmoSession.shared.state == .ready || GlassesAudioLink.shared.state.connected
        }
        InmoAdvancedControls.install(on: glasses)
        GlassesNavigator.shared.install(on: glasses)
        #if DEBUG
        Task { await InmoDeviceTrial.runIfRequested() }
        #endif
        glasses.refreshMembership()
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
        // Two or more paired: the chosen one is linked and primary; the others keep their switch.
        let choosing = HealthRing.bothPaired()
        let rings = WearableKind.workoutKinds
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
        Task {
            // A primary chosen on the server (Health settings' sources, the web) wins over this
            // phone's old copy, so a launch never registers the previous one back.
            if choosing, let key = try? await HealthClient(spaceID: HealthSpace.shared).settings().primaryDevice,
               let ring = HealthRing.ring(forDeviceKey: key), WearableIdentity.remembered(ring.kind) != nil {
                HealthRing.adopt(ring)
            }
            let chosen = HealthRing.current
            let payload = eligible.map { entry -> [String: Any] in
                var out: [String: Any] = [
                    "kind": entry.kind,
                    "device_id": entry.deviceID,
                    "name": entry.name,
                    "bridge_device_id": phone,
                    "timezone": TimeZone.current.identifier,
                ]
                if choosing, rings.contains(entry.kind) {
                    out.merge(HealthRing.serverFlags(for: entry.kind, chosen: chosen)) { _, flag in flag }
                }
                return out
            }
            do {
                _ = try await HealthClient.register(payload)
            } catch {
                JcLog.services.notice("health: could not register wearables — \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Flips a wearable's Keep Alive the way its own switch does: on reconnects now, off lets
    /// go of a link nothing else is using. `on` nil toggles. Returns the new setting.
    @discardableResult
    func setKeepAlive(_ on: Bool?, for device: String) -> Bool {
        let value = on ?? !WearableKeepAlive.isOn(device)
        WearableKeepAlive.set(value, for: device)
        if let manager = linkedWearables.first(where: { $0.kind.rawValue == device })?.manager {
            if value { Task { _ = await manager.ensureConnected(timeout: 10) } } else { manager.releaseIfIdle() }
        }
        return value
    }

    /// Bring one paired device's link up on request. Only devices the user has already
    /// shared are eligible — the agent never pairs something new.
    func connect(deviceID: String, timeout: TimeInterval = 12) async -> Bool {
        guard let entry = roster().first(where: { $0.deviceID == deviceID }) else { return false }
        if let manager = linkedWearables.first(where: { $0.kind.rawValue == entry.kind })?.manager {
            return await connectLinked(manager, deviceID: deviceID, timeout: timeout)
        }
        switch entry.kind {
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
        case WearableKeepAlive.glasses:
            do { try await glasses.session.ensureConnected(force: true); return glasses.isConnected } catch { return false }
        default:
            return false
        }
    }

    /// A known peripheral reopens by identifier; otherwise find it by scanning — and only this
    /// one: any ring or band of the same make nearby answers a scan too, and whichever connects
    /// gets its clock set and its data filed as this user's.
    private func connectLinked(_ manager: BLEWearableManager, deviceID: String, timeout: TimeInterval) async -> Bool {
        if await manager.ensureConnected(timeout: 3) { return true }
        // A device known by another id (the bottle goes by its MAC) can't be picked out of a
        // scan; only its known peripheral reopens.
        guard UUID(uuidString: deviceID) != nil else { return await manager.ensureConnected(timeout: timeout) }
        manager.startScan()
        guard let found = await waitFor(timeout: timeout, {
            manager.discovered.first { $0.id.uuidString == deviceID }
        }) else { return false }
        if manager.connected?.id != found.id || !manager.linkIsUp { manager.connect(found) }
        return await waitUntil(timeout: timeout) { manager.state == .ready }
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
        esp32.startScan()
        for wearable in bluetoothWearables { wearable.manager.startScan() }
    }
}
