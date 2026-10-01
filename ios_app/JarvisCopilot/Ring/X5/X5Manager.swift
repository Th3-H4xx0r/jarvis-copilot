import CoreBluetooth
import Foundation
import UIKit

/// App-lifetime owner of the X5's Bluetooth link: service FFF0, write FFF6, notify FFF7.
///
/// Mirrors `RingManager` (Keep Alive holds the link, off means connect on demand and drop
/// after the grace period; gestures and workouts hold it in the background) and hands every
/// notification to `X5Session` through `X5Frames`. The R12's manager is untouched: the two
/// rings each own their own central and link.
@MainActor
final class X5Manager: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var bluetoothReady = false
    @Published private(set) var discovered: [DiscoveredRing] = []
    @Published private(set) var connected: DiscoveredRing?
    /// What the ring sent lately, newest first — the inputs screen's monitor.
    @Published private(set) var gestureFeed: [RingGestureEvent] = []
    @Published private(set) var lastInput: RingInputEvent?

    /// FFF0 is a generic service, so by default the list only shows X5-named devices; off shows
    /// anything advertising FFF0 (each is still checked before it is remembered).
    @Published var strictNameMatch = false {
        didSet {
            guard oldValue != strictNameMatch else { return }
            if connected == nil { startScan() }
        }
    }

    let session = X5Session()
    private(set) lazy var sync: X5Sync = {
        let sync = X5Sync(transport: session.transport, store: { [weak self] in self?.store },
                          cursors: { [weak self] in self?.deviceID.map { X5Cursors(deviceID: $0) } })
        sync.onDaysChanged = { [weak self] keys in self?.onDaysChanged?(keys) }
        return sync
    }()
    private(set) lazy var measure = X5MeasureController(manager: self)

    /// Days the sync changed — Jarvis Health pushes them when this is its ring.
    var onDaysChanged: ((Set<String>) -> Void)?
    /// A workout the X5 is driving holds the link, in the background too.
    var workoutRunning = false

    var keepAliveEnabled: Bool { WearableKeepAlive.isOn(WearableKeepAlive.x5ring) }
    /// "Jarvis gestures" only works while the ring is connected, so it holds the link.
    var holdsLinkForInputs: Bool { inputs?.wantedMode == .jarvis }
    var holdsLinkForWorkout: Bool { workoutRunning }

    var deviceID: String? {
        WearableIdentity.remembered(WearableKeepAlive.x5ring)
            ?? connected?.id.uuidString
            ?? UserDefaults.standard.string(forKey: Self.lastPeripheralKey)
    }

    var store: RingHistoryStore? { deviceID.map { RingHistoryStore.shared(for: $0) } }
    var exposedDeviceID: String? { exposedDevice?.deviceID }
    var inputs: RingInputStore? { deviceID.map { RingInputStore.shared(for: $0) } }

    var linkIsUp: Bool {
        switch state {
        case .connecting, .discovering, .ready: return true
        case .idle, .scanning, .failed: return false
        }
    }

    /// True while an X5 screen is open: the link stays up whatever Keep Alive says, and the
    /// live stream runs.
    var screenIsOpen = false {
        didSet {
            guard oldValue != screenIsOpen else { return }
            if screenIsOpen { idleDropTask?.cancel(); idleDropTask = nil }
            session.holdsLive = screenIsOpen
            if state == .ready { Task { await session.setLive(screenIsOpen) } }
            if !screenIsOpen { releaseIfIdle() }
        }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var exposedDevice: X5Ring?
    private var scanTimeoutTask: Task<Void, Never>?
    private var idleDropTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryAttempts = 0
    private var wasConnectedBeforeBackground: DiscoveredRing?
    private var isBackgrounded = false
    private var lastBackgroundDrain = Date.distantPast
    static let lastPeripheralKey = "lastConnectedX5Peripheral"

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey:
                        "com.jarviscopilot.jarviscopilotMobileAndIOS.x5Central"])
        session.attach(self)
        _ = sync
        session.onGesture = { [weak self] gesture in self?.received(gesture) }
        onDaysChanged = { [weak self] keys in
            guard let self else { return }
            Task { await X5HealthPush.push(keys, manager: self) }
        }
        session.wantedHID = { [weak self] in Self.hid(for: self?.inputs?.wantedMode ?? .off) }
    }

    /// Whether a device belongs in the X5 list: an X5 name, or — unless only names count — the X5's
    /// FFF0 service, whatever the device calls itself. A ring iOS already holds doesn't advertise,
    /// so it is only ever found that way. Never the R12, which has its own card; anything else is
    /// checked on connect before it is remembered.
    static func isCandidate(name: String, hasService: Bool, strict: Bool) -> Bool {
        guard !RingProtocol.isRingName(name), !isScaleName(name) else { return false }
        return X5Protocol.isX5Name(name) || (!strict && hasService)
    }

    /// The bathroom scale advertises FFF0 too; it has its own card.
    static func isScaleName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("esf551") || n.contains("esf-551") || n.contains("etekcity") || n.contains("scale")
    }

    /// Rings forgotten this session: their page must not reconnect them on the way out.
    @Published private(set) var forgottenIDs: Set<UUID> = []

    /// The touch-surface mode an inputs-screen mode asks for.
    static func hid(for mode: RingInputMode) -> (enabled: Bool, mode: X5HIDMode) {
        switch mode {
        case .jarvis: return (true, .keys)
        case .shortVideo: return (true, .shortVideo)
        case .music: return (true, .music)
        case .camera: return (true, .camera)
        case .off: return (false, .keys)
        }
    }

    // MARK: Touch settings

    private func awakeKey(_ id: String) -> String { "jc.x5.awake.\(id)" }

    var awakePolicy: X5AwakePolicy {
        guard let id = deviceID, let data = UserDefaults.standard.data(forKey: awakeKey(id)),
              let policy = try? JSONDecoder().decode(X5AwakePolicy.self, from: data) else { return .always }
        return policy
    }

    func setAwakePolicy(_ policy: X5AwakePolicy) {
        guard let id = deviceID else { return }
        if let data = try? JSONEncoder().encode(policy) { UserDefaults.standard.set(data, forKey: awakeKey(id)) }
        session.awakePolicy = policy
        objectWillChange.send()
    }

    /// Puts the touch surface where the inputs screen says.
    func applyInputMode() async {
        if state != .ready {
            guard await ensureConnected(timeout: 12) else { return }
        }
        session.awakePolicy = awakePolicy
        await session.applyHID()
        releaseIfIdle()
    }

    // MARK: Gestures

    private var holdGate = X5HoldGate()

    private func received(_ gesture: X5Gesture) {
        let input = gesture.input
        lastInput = RingInputEvent(input: input, date: Date())
        feed(.press, input.label, String(format: "key 0x%02X", gesture.rawValue))
        guard inputs?.wantedMode == .jarvis else {
            feed(.ignored, input.label, "gestures aren't set to Jarvis")
            return
        }
        let bound = { [weak self] (input: RingInput) in self?.inputs?.action(for: input).isSet ?? false }
        for step in holdGate.arrive(gesture, at: Date(), bound: bound) {
            switch step {
            case .run(let input):
                run(input)
            case .cancel(let input):
                feed(.ignored, input.label, "the hold went on")
            case .wait(_, let until):
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, until.timeIntervalSinceNow) * 1_000_000_000))
                    guard let self, let due = self.holdGate.due(at: Date()) else { return }
                    self.run(due)
                }
            }
        }
    }

    private func run(_ input: RingInput) {
        let action = inputs?.action(for: input) ?? .none
        guard action.isSet else {
            session.log.note("X5 gesture: \(input.label)", "no action set")
            feed(.ignored, input.label, "no action set")
            return
        }
        session.log.note("X5 gesture: \(input.label)", action.summary)
        let started = Date()
        Task { [weak self] in
            let outcome = await RingActionRunner.run(action)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            self?.session.log.note("Ran \(input.label)", "\(outcome) — \(ms)ms")
            self?.feed(.ran, input.label, "\(action.summary) · \(ms)ms")
        }
    }

    private func feed(_ kind: RingGestureEvent.Kind, _ title: String, _ detail: String) {
        gestureFeed.insert(RingGestureEvent(kind: kind, title: title, detail: detail, date: Date()), at: 0)
        if gestureFeed.count > 40 { gestureFeed.removeLast(gestureFeed.count - 40) }
    }

    // MARK: Scanning

    func startScan() {
        guard bluetoothReady else { return }
        // A deliberate scan is how a forgotten ring comes back.
        forgottenIDs.removeAll()
        discovered.removeAll { $0.id != connected?.id }
        surfaceKnownPeripherals()
        if !linkIsUp { state = .scanning }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }

    func stopScan() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        central.stopScan()
        if case .scanning = state { state = .idle }
    }

    private func surfaceKnownPeripherals() {
        guard bluetoothReady else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastPeripheralKey)
        var candidates = central.retrieveConnectedPeripherals(withServices: [X5Protocol.service])
        if let last, let uuid = UUID(uuidString: last) {
            candidates += central.retrievePeripherals(withIdentifiers: [uuid])
        }
        for p in candidates where !discovered.contains(where: { $0.id == p.identifier }) {
            let name = p.name ?? ""
            // Everything here was found by its FFF0 service (or is the ring used last time).
            guard p.identifier.uuidString == last
                    || Self.isCandidate(name: name, hasService: true, strict: strictNameMatch) else { continue }
            discovered.append(DiscoveredRing(id: p.identifier, name: name.isEmpty ? "X5 ring" : name, rssi: 0, peripheral: p))
        }
    }

    // MARK: Connection

    func connect(_ ring: DiscoveredRing) {
        JcLog.devices.notice("x5: connect \(ring.name, privacy: .public) state=\(self.state.text, privacy: .public)")
        stopScan()
        if let current = peripheral, current.identifier != ring.id {
            central.cancelPeripheralConnection(current)
            resetLink()
        }
        peripheral = ring.peripheral
        connected = ring
        if !discovered.contains(where: { $0.id == ring.id }) { discovered.insert(ring, at: 0) }
        discoveryAttempts = 0
        state = .connecting
        ring.peripheral.delegate = self
        central.connect(ring.peripheral)
    }

    func disconnect() {
        JcLog.devices.notice("x5: disconnect state=\(self.state.text, privacy: .public)")
        setupTask?.cancel()
        setupTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        connected = nil
        state = .idle
        resetLink()
    }

    private func resetLink() {
        writeCharacteristic = nil
        session.linkDropped()
    }

    func ensureConnected(timeout: TimeInterval = 12) async -> Bool {
        if state == .ready { return true }
        guard bluetoothReady else { return false }
        if peripheral == nil, let known = knownPeripheral() {
            connect(DiscoveredRing(id: known.identifier, name: known.name ?? "X5 ring", rssi: 0, peripheral: known))
        } else if let p = peripheral, state != .connecting, state != .discovering {
            discoveryAttempts = 0
            state = .connecting
            p.delegate = self
            central.connect(p)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .ready { return true }
            if case .failed = state { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return state == .ready
    }

    func waitForSetup(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while setupTask != nil, state == .ready, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func knownPeripheral() -> CBPeripheral? {
        guard WearableIdentity.remembered(WearableKeepAlive.x5ring) != nil
                || UserDefaults.standard.string(forKey: Self.lastPeripheralKey) != nil else { return nil }
        if let stored = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
           let uuid = UUID(uuidString: stored),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            return known
        }
        return nil
    }

    func releaseIfIdle() {
        guard !keepAliveEnabled, !screenIsOpen, !holdsLinkForInputs, !holdsLinkForWorkout else { return }
        idleDropTask?.cancel()
        idleDropTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WearableKeepAlive.idleGraceSeconds))
            while !Task.isCancelled, self?.isWorking == true {
                try? await Task.sleep(for: .seconds(5))
            }
            guard let self, !Task.isCancelled, !self.keepAliveEnabled, !self.screenIsOpen,
                  !self.holdsLinkForInputs, !self.holdsLinkForWorkout else { return }
            JcLog.devices.notice("x5: idle after on-demand use; dropping the link")
            await self.session.setLive(false)
            self.disconnect()
        }
    }

    private var isWorking: Bool {
        setupTask != nil || session.transport.isBusy || session.measurement?.isActive == true || sync.isSyncing
    }

    /// Forgets the ring: unbinds it (best effort), drops the link and every local trace of it
    /// but its history.
    func forget() async {
        if state == .ready { await session.unbind() }
        let id = deviceID
        if let ring = connected?.id ?? peripheral?.identifier {
            forgottenIDs.insert(ring)
            discovered.removeAll { $0.id == ring }
        }
        disconnect()
        if let device = exposedDevice { DeviceRegistry.shared.remove(deviceID: device.deviceID) }
        exposedDevice = nil
        WearableIdentity.forget(WearableKeepAlive.x5ring)
        UserDefaults.standard.removeObject(forKey: Self.lastPeripheralKey)
        if let id { X5Cursors(deviceID: id).reset() }
    }

    private func beginDiscovery(_ p: CBPeripheral) {
        discoveryAttempts += 1
        state = .discovering
        p.delegate = self
        p.discoverServices([X5Protocol.service])
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.state == .discovering, self.peripheral === p else { return }
            switch self.discoveryAttempts {
            case 1:
                self.beginDiscovery(p)
            case 2:
                self.discoveryAttempts = 3
                self.resetLink()
                self.central.cancelPeripheralConnection(p)
                self.state = .connecting
                self.central.connect(p)
            default:
                self.state = .failed("the ring never answered — unbind it in its own app, or toggle Bluetooth")
            }
        }
    }

    private func becomeReady(_ p: CBPeripheral) {
        guard state != .ready else { return }
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryAttempts = 0
        state = .ready
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            guard let self else { return }
            // A device we haven't remembered has to prove it is an X5 before it becomes one.
            let known = WearableIdentity.remembered(WearableKeepAlive.x5ring) == p.identifier.uuidString
                || UserDefaults.standard.string(forKey: Self.lastPeripheralKey) == p.identifier.uuidString
            if !known, await !self.session.verifyIdentity() {
                JcLog.devices.notice("x5: \(p.name ?? "?", privacy: .public) is not an X5; letting go")
                self.setupTask = nil
                self.disconnect()
                self.state = .failed("Not an X5 ring")
                return
            }
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastPeripheralKey)
            self.publishToRegistry()
            guard let id = self.deviceID else { self.setupTask = nil; return }
            self.session.awakePolicy = self.awakePolicy
            X5Ring.seedDefaultInputs(self.inputs, deviceID: id)
            do {
                try await self.session.runSetup(deviceID: id)
            } catch {
                JcLog.devices.notice("x5: setup failed — \(error.localizedDescription, privacy: .public)")
            }
            self.setupTask = nil
            guard self.state == .ready else { return }
            // Workout records wait for something to read them (the shared workout screen).
            if self.session.features.contains(.manualSpO2) { self.sync.extraKinds = [.manualSpO2] }
            // Never from the background: the firmware streams all night once asked.
            if self.screenIsOpen, !self.isBackgrounded { await self.session.setLive(true) }
            if self.sync.isStale { await self.sync.sync() }
            self.releaseIfIdle()
        }
    }

    // MARK: Registry

    private func publishToRegistry() {
        guard state == .ready else { return }
        if exposedDevice == nil { exposedDevice = X5Ring(backend: self) }
        refreshRegistryMembership()
    }

    func refreshRegistryMembership() {
        guard let device = exposedDevice else { return }
        DeviceRegistry.shared.syncMembership(of: device, identity: WearableKeepAlive.x5ring, model: X5Ring.model)
    }

    /// Registers the catalogue with no live link; `invoke` reconnects on demand.
    func publishRemembered() {
        if exposedDevice == nil {
            guard WearableIdentity.remembered(WearableKeepAlive.x5ring) != nil else { return }
            exposedDevice = X5Ring(backend: self)
        }
        refreshRegistryMembership()
    }

    // MARK: Foreground / background

    func enterBackground() {
        isBackgrounded = true
        stopScan()
        Task {
            // The firmware keeps streaming across a disconnect: stop it before letting go.
            if self.session.liveOn, !self.holdsLinkForWorkout { await self.session.setLive(false) }
            self.releaseLinkForBackground()
        }
    }

    private func releaseLinkForBackground() {
        guard !holdsLinkForInputs, !holdsLinkForWorkout else { return }
        guard !BridgeClient.shared.enabled || !keepAliveEnabled else { return }
        if connected != nil {
            wasConnectedBeforeBackground = connected
            disconnect()
        }
    }

    func enterForeground() {
        isBackgrounded = false
        if let ring = wasConnectedBeforeBackground {
            wasConnectedBeforeBackground = nil
            if keepAliveEnabled || screenIsOpen || holdsLinkForWorkout { connect(ring) }
        } else if state == .ready {
            if screenIsOpen { Task { await self.session.setLive(true) } }
            if sync.isStale { Task { await self.sync.sync() } }
        }
    }
}

// MARK: - RingLink

extension X5Manager: RingLink {
    var isLinkReady: Bool { state == .ready && peripheral != nil && writeCharacteristic != nil }
    var hasBigDataChannel: Bool { false }

    func send(_ data: Data, on channel: RingChannel) {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        // The vendor's own app writes with response.
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }
}

// MARK: - CBCentralManagerDelegate

extension X5Manager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let on = c.state == .poweredOn
        Task { @MainActor in
            self.bluetoothReady = on
            if on {
                self.startScan()
            } else {
                self.state = .failed("Bluetooth off")
                self.resetLink()
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            guard let p = restored.first(where: { $0.state == .connected || $0.state == .connecting }) else { return }
            p.delegate = self
            self.peripheral = p
            self.connected = DiscoveredRing(id: p.identifier, name: p.name ?? "X5 ring", rssi: 0, peripheral: p)
            self.discoveryAttempts = 0
            if p.state == .connected { self.beginDiscovery(p) } else { self.state = .connecting }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let rssi = RSSI.intValue
        Task { @MainActor in
            guard Self.isCandidate(name: name, hasService: services.contains(X5Protocol.service),
                                   strict: self.strictNameMatch) else { return }
            if let i = self.discovered.firstIndex(where: { $0.id == p.identifier }) {
                self.discovered[i].rssi = rssi
                if !name.isEmpty { self.discovered[i].name = name }
            } else {
                self.discovered.append(DiscoveredRing(id: p.identifier, name: name.isEmpty ? "X5 ring" : name,
                                                      rssi: rssi, peripheral: p))
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in self.beginDiscovery(p) }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.state = .failed(error?.localizedDescription ?? "could not connect")
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "no error"
        Task { @MainActor in
            guard p === self.peripheral else { return }
            self.setupTask?.cancel()
            self.setupTask = nil
            self.resetLink()
            guard self.keepAliveEnabled || self.screenIsOpen || self.holdsLinkForInputs || self.holdsLinkForWorkout else {
                JcLog.devices.notice("x5: link dropped (\(reason, privacy: .public)); keep-alive off")
                self.connected = nil
                self.state = .idle
                return
            }
            JcLog.devices.notice("x5: link dropped (\(reason, privacy: .public)); reconnecting")
            self.discoveryAttempts = 0
            self.state = .connecting
            self.central.connect(p)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension X5Manager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = p.services?.first(where: { $0.uuid == X5Protocol.service }) else {
                self.state = .failed("X5 service not found")
                return
            }
            p.discoverCharacteristics([X5Protocol.write, X5Protocol.notify], for: service)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            let characteristics = service.characteristics ?? []
            if let write = characteristics.first(where: { $0.uuid == X5Protocol.write }) { self.writeCharacteristic = write }
            for characteristic in characteristics where characteristic.uuid == X5Protocol.notify {
                if !characteristic.isNotifying { p.setNotifyValue(true, for: characteristic) }
            }
            if self.writeCharacteristic != nil,
               characteristics.contains(where: { $0.uuid == X5Protocol.notify && $0.isNotifying }) {
                self.becomeReady(p)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                JcLog.devices.error("x5: notify failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard characteristic.uuid == X5Protocol.notify, characteristic.isNotifying else { return }
            if self.writeCharacteristic != nil { self.becomeReady(p) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == X5Protocol.notify, let data = characteristic.value, !data.isEmpty else { return }
        Task { @MainActor in
            for frame in X5Frames.split(data) { self.session.transport.deliver(frame.inbound, note: frame.note) }
            // A BLE wake is a slice of background time: spend it on Jarvis's queue, once per burst.
            if self.isBackgrounded, BridgeClient.shared.enabled, BridgeClient.shared.status != .online,
               Date().timeIntervalSince(self.lastBackgroundDrain) > 10 {
                self.lastBackgroundDrain = Date()
                await BridgeClient.shared.drainQueue(foreground: false)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            JcLog.devices.notice("x5: write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
