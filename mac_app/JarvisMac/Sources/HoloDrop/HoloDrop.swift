import AppKit
import Network
import SwiftUI

/// Holo Drop on the Mac (docs/superpowers/specs/2026-11-14-holo-drop-design.md): receives
/// drops from his other devices (bridge `holo_drop` frames through jc-client, `/pending` on
/// launch and wake, or straight over the LAN) and lands them as floating cards; sends what's in
/// front from the shortcut, the menu, the notch button or a trackpad flick through the Orbit
/// popup; answers screen-map requests and plays the direction beacons; says when it moved.
/// Everything follows the Power switch (`/api/power` row "holo-drop"): off means no listener,
/// no shortcut, no menu items, and drops are ignored.
@MainActor
@Observable
final class HoloDrop {
    static let shared = HoloDrop()

    /// The Power switch as last read. Unknown counts as on; a server without Holo Drop is off.
    private(set) var on: Bool = HoloDrop.isOnCached
    private(set) var devices: [HoloDevice] = []

    nonisolated static var isOnCached: Bool {
        UserDefaults.standard.object(forKey: "holoDrop.on") as? Bool ?? true
    }

    /// Settings → Shortcuts: a three-finger flick up sends what's in front (best effort: macOS
    /// keeps most trackpad swipes for itself, and a global monitor needs Accessibility).
    static var flick: Bool {
        get { UserDefaults.standard.bool(forKey: "holoDrop.flick") }
        set {
            UserDefaults.standard.set(newValue, forKey: "holoDrop.flick")
            shared.syncFlick()
        }
    }

    @ObservationIgnored private let lan = HoloLanReceiver()
    @ObservationIgnored private let moved = HoloMovedWatch()
    @ObservationIgnored private let beacons = HoloBeacons()
    @ObservationIgnored private let ble = HoloBLEAdvertiser()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var orbit: HoloOrbitController?
    @ObservationIgnored private var flickMonitor: Any?
    @ObservationIgnored private var lastFlick = Date.distantPast
    @ObservationIgnored private var lanTimer: Timer?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var powerLoop: Task<Void, Never>?
    @ObservationIgnored private var wakeToken: NSObjectProtocol?
    /// Drops this Mac sent, by id → device name (for the landed line).
    @ObservationIgnored private var awaiting: [String: String] = [:]
    /// Landings already shown (the Orbit, a toast, or the direct path's own answer): every other
    /// landed frame gets a toast, once.
    @ObservationIgnored private var shownLandings: [String] = []
    /// Drops already landed here (a frame and `/pending` can both bring one).
    @ObservationIgnored private var handled: [String] = UserDefaults.standard.stringArray(forKey: "holoDrop.handled") ?? []
    /// Shows a landing line (tests catch it).
    @ObservationIgnored var toaster: (String, String) -> Void = { HoloCards.shared.toast($0, symbol: $1) }
    /// `power` topic pushes seen (each one re-reads the switch).
    @ObservationIgnored private(set) var powerPokes = 0

    static let lanAdvertEvery: TimeInterval = 10 * 60
    static let lanTokenLife: TimeInterval = 15 * 60

    var api: HoloDropAPI? { AppModel.shared.apiOrigin.map(HoloDropAPI.init(origin:)) }

    // MARK: lifecycle

    func start() {
        guard !started, !AppDelegate.isTesting else { return }
        started = true
        Task.detached(priority: .utility) { HoloTemp.sweep() }   // copies older than a day
        lan.handler = { [weak self] fields, file, inline in
            await self?.landDirect(fields, file: file, inline: inline) ?? .failed
        }
        moved.onMoved = { [weak self] why in
            NSLog("Jarvis: Holo Drop — this Mac moved (\(why))")
            Task { await self?.api?.moved() }
        }
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))   // the network comes back first
                    await self?.refreshPower()
                    await self?.fetchPending()
                    self?.advertise()
                }
            }
        }
        powerLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                await self?.refreshPower()
            }
        }
        sync()
    }

    /// jc-client said hello: the server is reachable through its proxy now.
    func serverReady() {
        writeShareInfo()
        if on, started, let id = AppModel.shared.deviceId { ble.start(deviceID: id) }
        Task {
            await refreshPower()
            guard on else { return }
            await loadDevices()
            await fetchPending()
            advertise()
        }
    }

    /// The server published `power` (any integration switched or changed): read the switch now.
    func powerTopic() {
        powerPokes += 1
        Task { await refreshPower() }
    }

    func refreshPower() async {
        guard let api else { return }
        let enabled: Bool?
        do {
            enabled = try await api.powerEnabled()
        } catch {
            return   // unknown: keep what we had
        }
        set(on: enabled ?? false)   // no Holo Drop row: this server has none
    }

    private func set(on new: Bool) {
        UserDefaults.standard.set(new, forKey: "holoDrop.on")
        guard new != on else { return sync() }
        on = new
        NSLog("Jarvis: Holo Drop is \(new ? "on" : "off")")
        NotificationCenter.default.post(name: .jarvisShortcutsChanged, object: nil)   // the shortcut follows
        sync()
        writeShareInfo()
    }

    private func sync() {
        guard started else { return }
        if on { startServices() } else { stopServices() }
        syncFlick()
    }

    private func startServices() {
        if !moved.running { moved.start() }
        if let id = AppModel.shared.deviceId { ble.start(deviceID: id) }   // else once jc-client says hello
        if !lan.running {
            lan.start { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.advertise() } }
            }
            lanTimer = Timer.scheduledTimer(withTimeInterval: Self.lanAdvertEvery, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advertise() }
            }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.advertise() } }
            }
            monitor.start(queue: DispatchQueue(label: "jarvis.holo.path"))
            pathMonitor = monitor
        }
    }

    private func stopServices() {
        moved.stop()
        ble.stop()
        beacons.stop()
        orbit?.close()
        lanTimer?.invalidate()
        lanTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if lan.running {
            lan.stop()
            Task { await api?.clearLan() }
        }
    }

    /// Tell Jarvis where this Mac listens on the LAN, with a fresh token.
    private func advertise() {
        guard on, started, let api, let port = lan.port, let ip = HoloLanAddress.current() else { return }
        let token = lan.newToken(validFor: Self.lanTokenLife)
        let expires = Date().addingTimeInterval(Self.lanTokenLife)
        Task {
            do {
                try await api.advertiseLan(url: "http://\(ip):\(port)", token: token, expires: expires)
            } catch HoloFailure.off {
                set(on: false)
            } catch {}
        }
    }

    // MARK: frames from the server

    /// A `holo_drop` frame jc-client passed on (`{type: "holo_drop", event, …}`).
    func handle(frame: [String: Any]) {
        switch J.s(frame["event"]) {
        case "drop":
            guard on, let drop = HoloDropRecord(json: J.obj(frame["drop"])) else { return }
            receive(drop)
        case "landed":
            landed(J.obj(frame["drop"]), error: frame["error"] as? String)
        case "screen_request":
            let request = J.s(frame["request"])
            guard on, !request.isEmpty, let api else { return }
            Task { await api.answerScreen(request, HoloScreenReport.current()) }
        case "beacon":
            guard on else { return }
            beacons.handle(mode: J.s(frame["mode"]), nonce: J.s(frame["nonce"]))
        default:
            break
        }
    }

    private func fetchPending() async {
        guard on, let api else { return }
        do {
            for drop in try await api.pending() { receive(drop) }
        } catch HoloFailure.off {
            set(on: false)
        } catch {}
    }

    private func receive(_ drop: HoloDropRecord) {
        guard !drop.id.isEmpty, !handled.contains(drop.id) else { return }
        remember(drop.id)
        let api = self.api
        let from = senderName(drop)
        Task {
            let (outcome, error) = await HoloReceiver.shared.land(drop, fromName: from, api: api)
            await api?.landed(drop.id, outcome, error: error)
        }
    }

    /// A drop that came straight over the LAN: lands the same way (and is reported to Jarvis
    /// too when the sender already recorded it there).
    private func landDirect(_ fields: [String: Any], file: URL?, inline: [String: Any]) async -> HoloOutcome {
        await refreshPower()   // the live switch, not the last poll
        guard on else { return .failed }
        var json = fields.merging(inline) { _, new in new }
        json["created"] = json["created"] ?? Date().timeIntervalSince1970
        guard let drop = HoloDropRecord(json: json) else { return .failed }
        if !drop.id.isEmpty {
            guard !handled.contains(drop.id) else { return .shown }
            remember(drop.id)
        }
        let (outcome, error) = await HoloReceiver.shared.land(drop, fromName: senderName(drop), file: file, api: nil)
        if !drop.id.isEmpty { await api?.landed(drop.id, outcome, error: error) }
        return outcome
    }

    private func remember(_ id: String) {
        handled.append(id)
        if handled.count > 200 { handled = Array(handled.suffix(100)) }
        UserDefaults.standard.set(handled, forKey: "holoDrop.handled")
    }

    private func senderName(_ drop: HoloDropRecord) -> String {
        if !drop.fromName.isEmpty { return drop.fromName }
        if let d = devices.first(where: { $0.id == drop.from }) { return d.name }
        return "your device"
    }

    /// A drop this Mac sent has landed (the server sends `landed` only to the sender): shown in
    /// the Orbit when it's still waiting there, else as a toast — once, however late.
    private func landed(_ json: [String: Any], error: String?) {
        guard let drop = HoloDropRecord(json: json), !drop.id.isEmpty, markShown(drop.id) else { return }
        let name = awaiting.removeValue(forKey: drop.id) ?? devices.first { $0.id == drop.target }?.name ?? "your device"
        let why = (error?.isEmpty == false ? error : nil) ?? J.s(json["error"])
        let line = HoloDropRecord.landedLine(device: name, outcome: drop.outcome, error: why)
        if let orbit, orbit.isWaiting(for: drop.id) {
            orbit.landed(line)
        } else {
            toaster(line, drop.outcome == "failed" ? "exclamationmark.triangle" : "checkmark.circle.fill")
        }
    }

    /// True the first time a landing is shown.
    private func markShown(_ id: String) -> Bool {
        guard !shownLandings.contains(id) else { return false }
        shownLandings.append(id)
        if shownLandings.count > 400 { shownLandings = Array(shownLandings.suffix(200)) }
        return true
    }

    private func loadDevices() async {
        guard let api else { return }
        do {
            devices = try await api.devices()
        } catch HoloFailure.off {
            set(on: false)
        } catch {}
    }

    // MARK: sending

    /// The shortcut, menu item, notch button and flick: grab what's in front and open the Orbit.
    func grabAndSend() {
        guard on else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? WindowContext.lastApp : front
        let controller = orbit ?? HoloOrbitController(owner: self)
        orbit = controller
        controller.show()
        Task {
            let item = await HoloGrab.grab(bundleID: app?.bundleIdentifier, pid: app?.processIdentifier ?? 0,
                                           probe: HoloSystemProbe())
            if controller.model.item == nil, let item { controller.model.setItem(item) }
        }
        Task {
            await loadDevices()
            controller.model.devices = devices
            controller.model.loading = false
            if api == nil { controller.model.phase = .unavailable("Jarvis isn't running on this Mac") }
        }
    }

    /// Send from the Orbit.
    fileprivate func send(_ item: HoloItem, to device: HoloDevice, action: HoloAction, from controller: HoloOrbitController) {
        guard let api else {
            controller.model.phase = .failed("Jarvis isn't running on this Mac")
            return
        }
        controller.model.phase = .sending(device.name)
        controller.model.onRetry = nil
        controller.sendStarted()
        Task {
            defer { controller.sendEnded() }
            do {
                let sent = try await HoloSender(api: api, tryDirect: true).send(item, to: device, action: action)
                for id in sent.directIDs { _ = markShown(id) }   // answered already, here
                if let outcome = sent.outcome, sent.ids.isEmpty {
                    let line = HoloDropRecord.landedLine(device: device.name, outcome: outcome.rawValue, error: sent.error)
                    if outcome == .failed {
                        controller.fail(line, retry: retry(item, to: device, action: action, from: controller))
                    } else {
                        controller.finish(line)
                    }
                    return
                }
                for id in sent.ids { awaiting[id] = device.name }
                controller.waitFor(Set(sent.ids))
                controller.model.phase = .waiting(device.online ? "Sent — waiting for \(device.name)"
                                                                : "\(device.name) is away — it lands when it's back")
                guard let last = sent.ids.last else { return }
                if let d = await api.waitLanded(last, timeout: 4), markShown(last) {
                    awaiting[last] = nil
                    let line = HoloDropRecord.landedLine(device: device.name, outcome: d.outcome)
                    if d.outcome == "failed" { controller.fail(line) {} } else { controller.finish(line) }
                } else {
                    controller.closeSoon(3)   // a later landing arrives as a frame → a toast
                }
            } catch HoloFailure.off {
                controller.model.phase = .off
                set(on: false)
            } catch {
                let why = (error as? HoloFailure)?.message ?? error.localizedDescription
                controller.fail("Couldn't send — \(why)", retry: retry(item, to: device, action: action, from: controller))
            }
        }
    }

    /// Try again, from the Orbit's failure line. Held by the controller's model, so it holds the
    /// controller weakly.
    private func retry(_ item: HoloItem, to device: HoloDevice, action: HoloAction,
                       from controller: HoloOrbitController) -> () -> Void {
        { [weak controller] in
            guard let controller else { return }
            HoloDrop.shared.send(item, to: device, action: action, from: controller)
        }
    }

    fileprivate func orbitClosed(_ controller: HoloOrbitController) {
        if orbit === controller { orbit = nil }
    }

    // MARK: flick

    func syncFlick() {
        let want = on && started && Self.flick
        if want, flickMonitor == nil {
            flickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.swipe]) { event in
                guard event.deltaY > 0 else { return }   // up
                MainActor.assumeIsolated {
                    let me = HoloDrop.shared
                    guard Date().timeIntervalSince(me.lastFlick) > 1.5 else { return }
                    me.lastFlick = Date()
                    me.grabAndSend()
                }
            }
        } else if !want, let m = flickMonitor {
            NSEvent.removeMonitor(m)
            flickMonitor = nil
        }
    }

    // MARK: the Share extension

    /// Where the Share extension finds the loopback proxy (it can't reach jc-client's socket
    /// from its sandbox) and whether Holo Drop is on. The proxy already answers any local
    /// process, so this file reveals nothing new.
    static var shareInfoPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".jarviscopilot-client/holo-share.json")
    }

    private func writeShareInfo() {
        guard started else { return }
        let info: [String: Any] = ["api": AppModel.shared.apiOrigin ?? "", "on": on,
                                   "updated": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: info) else { return }
        let url = URL(fileURLWithPath: Self.shareInfoPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

// MARK: - the Orbit popup's window

/// A panel that takes the keyboard (⌘V, Esc) without bringing Jarvis forward.
final class HoloKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class HoloOrbitController {
    let model = HoloOrbitModel()
    private weak var owner: HoloDrop?
    private var panel: HoloKeyPanel?
    private var keyMonitor: Any?
    private var waiting: Set<String> = []
    private var closeTask: Task<Void, Never>?
    /// Sends still running: the item's temporary copy stays until they're done.
    private var inFlight = 0

    init(owner: HoloDrop) {
        self.owner = owner
        model.onSend = { [weak self] device, action in
            guard let self, let item = self.model.item else { return }
            self.closeTask?.cancel()
            owner.send(item, to: device, action: action, from: self)
        }
        model.onClose = { [weak self] in self?.close() }
    }

    var visible: Bool { panel?.isVisible ?? false }
    var window: NSWindow? { panel }

    func show() {
        closeTask?.cancel()
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        model.phase = .choosing
        model.loading = true
        model.override = nil
        model.aimed = nil
        model.setItem(nil)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? HoloCards.mainScreen
        let size = HoloOrbitView.size
        let v = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        let p = HoloKeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = false
        p.contentView = NSHostingView(rootView: HoloOrbitView(model: model).environment(\.colorScheme, .dark))
        panel = p
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if event.keyCode == 53 { self.close(); return nil }   // Esc
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
                if !self.model.busy, let item = HoloItemLoader.fromPasteboard() { self.model.setItem(item) }
                return nil
            }
            return event
        }
        // It stays up when it loses focus (clicking Finder to drag a file in, an Automation
        // prompt): Esc, ✕ or a settled send closes it.
    }

    func sendStarted() { inFlight += 1 }

    func sendEnded() {
        inFlight = max(0, inFlight - 1)
        if inFlight == 0, !visible { HoloTemp.release(model.item) }
    }

    func isWaiting(for id: String) -> Bool { visible && waiting.contains(id) }

    func waitFor(_ ids: Set<String>) { waiting = ids }

    func landed(_ line: String) { finish(line) }

    func finish(_ line: String) {
        guard visible else {
            HoloCards.shared.toast(line)
            return
        }
        model.phase = .landed(line)
        closeSoon(2.2)
    }

    func fail(_ why: String, retry: (() -> Void)? = nil) {
        guard visible else {
            HoloCards.shared.toast(why, symbol: "exclamationmark.triangle")
            return
        }
        model.phase = .failed(why)
        model.onRetry = retry
    }

    func closeSoon(_ seconds: Double) {
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        closeTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        waiting = []
        if inFlight == 0 { HoloTemp.release(model.item) }   // else once the send is done
        if let p = panel {
            panel = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        owner?.orbitClosed(self)
    }
}
