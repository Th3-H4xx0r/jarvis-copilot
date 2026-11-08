import CoreBluetooth
import Foundation

enum ConnectionState: Equatable {
    case idle, scanning, connecting, discovering, ready, failed(String)

    var text: String {
        switch self {
        case .idle:         return "Idle"
        case .scanning:     return "Scanning…"
        case .connecting:   return "Connecting…"
        case .discovering:  return "Discovering…"
        case .ready:        return "Connected"
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

/// A wearable in a scan list (any of them, not just rings).
struct DiscoveredWearable: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var peripheral: CBPeripheral

    static func == (a: DiscoveredWearable, b: DiscoveredWearable) -> Bool { a.id == b.id }
}

/// The Bluetooth link every wearable shares (R12, X5, band, bottle, scale): one central,
/// scanning, connecting, a watchdog on service discovery, reconnects, state restoration, the
/// background/foreground rules, and its listing with Jarvis. A device subclass says what it is
/// (its services, how its advertisement reads, its fallback name, its Jarvis face) and does its
/// own setup once services are found.
///
/// Subclasses declare `CBPeripheralDelegate` themselves: an optional Objective-C callback is
/// only exposed to CoreBluetooth from the type that declares the conformance.
@MainActor
class BLEWearableManager: NSObject, ObservableObject, OnDemandWearable, CBCentralManagerDelegate {
    @Published var state: ConnectionState = .idle
    @Published var bluetoothReady = false
    @Published var discovered: [DiscoveredWearable] = []
    @Published var connected: DiscoveredWearable?
    /// Devices forgotten this session: their page must not reconnect them on the way out.
    @Published var forgottenIDs: Set<UUID> = []
    /// The scanner's "Only Jarvis devices": off, a device's subclass may also list look-alikes
    /// (any peripheral with its service, any named one).
    @Published var strictNameMatch = true {
        didSet { if oldValue != strictNameMatch, connected == nil { startScan() } }
    }

    /// True while the device's own screen is open: the link stays up whatever Keep Alive says.
    var screenIsOpen = false {
        didSet { if oldValue != screenIsOpen { holdChanged(screenIsOpen) } }
    }
    /// True while the Health tab is open: held so a refresh or a spot check needs no connect.
    var healthIsOpen = false {
        didSet { if oldValue != healthIsOpen { holdChanged(healthIsOpen, connectIfDown: true) } }
    }

    let linkLogName: String
    /// `WearableKeepAlive` key: what the device is remembered, kept alive and shared under.
    let identityKey: String
    /// How the device is listed with Jarvis.
    let model: String
    let lastPeripheralKey: String
    let fallbackName: String
    /// The service a connected device is found by (a held device doesn't advertise).
    let primaryService: CBUUID
    /// Services asked for on every connect.
    let servicesToDiscover: [CBUUID]
    /// What the user reads when discovery never finishes.
    let discoveryFailure: String

    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var scanTimeoutTask: Task<Void, Never>?
    var idleDropTask: Task<Void, Never>?
    var setupTask: Task<Void, Never>?
    var discoveryTask: Task<Void, Never>?
    var discoveryAttempts = 0
    var wasConnectedBeforeBackground: DiscoveredWearable?
    var isBackgrounded = false

    /// The device's skills, made the first time it is published and kept while its link is down.
    private(set) var exposedDevice: (any WearableDevice)?

    init(logName: String, identity: String, model: String, restoreIdentifier: String,
         lastPeripheralKey: String, fallbackName: String,
         primaryService: CBUUID, servicesToDiscover: [CBUUID], discoveryFailure: String) {
        self.linkLogName = logName
        self.identityKey = identity
        self.model = model
        self.lastPeripheralKey = lastPeripheralKey
        self.fallbackName = fallbackName
        self.primaryService = primaryService
        self.servicesToDiscover = servicesToDiscover
        self.discoveryFailure = discoveryFailure
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier])
    }

    // MARK: What a device says about itself (subclasses override)

    var keepAliveEnabled: Bool { false }
    var holdsLinkForWorkout: Bool { false }
    var isWorking: Bool { isSettingUp }
    var isSettingUp: Bool { setupTask != nil }

    var linkIsUp: Bool {
        switch state {
        case .connecting, .discovering, .ready: return true
        case .idle, .scanning, .failed: return false
        }
    }

    /// Whether an advertisement is this kind of device.
    func matchesAdvertisement(name: String, services: [CBUUID], manufacturer: UInt16?) -> Bool { false }

    /// Whether a peripheral iOS already holds (or the last one used) belongs in the list.
    func belongsInList(_ p: CBPeripheral, isLastUsed: Bool) -> Bool { true }

    /// The device to reopen without a scan: the one used last time.
    func knownPeripheral() -> CBPeripheral? {
        guard let stored = UserDefaults.standard.string(forKey: lastPeripheralKey),
              let uuid = UUID(uuidString: stored) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    /// Clears the device's characteristics and tells its session the link went.
    func resetLink() {}

    /// Bluetooth came on.
    func bluetoothBecameReady() { startScan() }

    /// Back in front with the link still up.
    func foregroundWhileReady() {}

    func dropIdleLink() async { disconnect() }

    /// The device's Jarvis face: the skills it offers.
    func makeExposedDevice() -> any WearableDevice { preconditionFailure("\(Self.self) has no Jarvis device") }

    /// Whether a device in the list is the one just heard. A device that changes its address
    /// (the scale) is matched by name too, so it stays one card.
    func isSameDevice(_ listed: DiscoveredWearable, as p: CBPeripheral, name: String) -> Bool {
        listed.id == p.identifier
    }

    private var peripheralDelegate: CBPeripheralDelegate? { self as? CBPeripheralDelegate }

    // MARK: Scanning

    func startScan() {
        guard bluetoothReady else { return }
        // A deliberate scan is how a forgotten device comes back.
        forgottenIDs.removeAll()
        // A connected device doesn't advertise; keep it in the list across rescans.
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

    /// A device iOS already holds a link to, or the one used last time, belongs in the list
    /// even though it won't show up in scan results.
    func surfaceKnownPeripherals() {
        guard bluetoothReady else { return }
        let last = UserDefaults.standard.string(forKey: lastPeripheralKey)
        var candidates = central.retrieveConnectedPeripherals(withServices: [primaryService])
        if let last, let uuid = UUID(uuidString: last) {
            candidates += central.retrievePeripherals(withIdentifiers: [uuid])
        }
        for p in candidates where !discovered.contains(where: { $0.id == p.identifier }) {
            guard belongsInList(p, isLastUsed: p.identifier.uuidString == last) else { continue }
            discovered.append(DiscoveredWearable(id: p.identifier, name: displayName(p.name), rssi: 0, peripheral: p))
        }
    }

    func displayName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return fallbackName }
        return name
    }

    // MARK: Connection

    func connect(_ device: DiscoveredWearable) {
        JcLog.devices.notice("\(self.linkLogName, privacy: .public): connect \(device.name, privacy: .public) state=\(self.state.text, privacy: .public)")
        stopScan()
        if let current = peripheral, current.identifier != device.id {
            central.cancelPeripheralConnection(current)
            resetLink()
        }
        peripheral = device.peripheral
        connected = device
        if !discovered.contains(where: { $0.id == device.id }) { discovered.insert(device, at: 0) }
        discoveryAttempts = 0
        state = .connecting
        device.peripheral.delegate = peripheralDelegate
        central.connect(device.peripheral)
    }

    func disconnect() {
        JcLog.devices.notice("\(self.linkLogName, privacy: .public): disconnect state=\(self.state.text, privacy: .public)")
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

    /// CoreBluetooth can reopen a known peripheral by identifier, so this costs no scan.
    func startLink() {
        if peripheral == nil, let known = knownPeripheral() {
            connect(DiscoveredWearable(id: known.identifier, name: displayName(known.name), rssi: 0, peripheral: known))
        } else if let p = peripheral, state != .connecting, state != .discovering {
            discoveryAttempts = 0
            state = .connecting
            p.delegate = peripheralDelegate
            central.connect(p)
        }
    }

    /// Asks for the services and keeps a watchdog on the answer. Discovery can stall for good —
    /// the device still held by another app, or a link restored by iOS that never reports — and
    /// nothing else moves the state off "Discovering". Ask again, then reopen the link, then fail.
    func beginDiscovery(_ p: CBPeripheral) {
        discoveryAttempts += 1
        state = .discovering
        p.delegate = peripheralDelegate
        p.discoverServices(servicesToDiscover)
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.state == .discovering, self.peripheral === p else { return }
            switch self.discoveryAttempts {
            case 1:
                JcLog.devices.notice("\(self.linkLogName, privacy: .public): discovery stalled; asking again")
                self.beginDiscovery(p)
            case 2:
                JcLog.devices.notice("\(self.linkLogName, privacy: .public): discovery stalled twice; reopening the link")
                self.discoveryAttempts = 3
                self.resetLink()
                self.central.cancelPeripheralConnection(p)
                self.state = .connecting
                self.central.connect(p)
            default:
                JcLog.devices.error("\(self.linkLogName, privacy: .public): discovery never finished")
                self.state = .failed(self.discoveryFailure)
            }
        }
    }

    /// The link is usable: the discovery watchdog stops.
    func markReady() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryAttempts = 0
        state = .ready
    }

    /// Drops the link and its link-level traces, and takes the device off Jarvis: this session
    /// won't reconnect it, and the next launch won't reopen it. The device's own history stays.
    func forgetLink() {
        if let id = connected?.id ?? peripheral?.identifier {
            forgottenIDs.insert(id)
            discovered.removeAll { $0.id == id }
        }
        disconnect()
        WearableIdentity.forget(identityKey)
        UserDefaults.standard.removeObject(forKey: lastPeripheralKey)
        if let exposedDevice { DeviceRegistry.shared.remove(deviceID: exposedDevice.deviceID) }
        exposedDevice = nil
    }

    // MARK: Jarvis

    var exposedDeviceID: String? { exposedDevice?.deviceID }

    /// `p` is this device (proven, where the device has to prove it): it is the one reopened
    /// next launch, and it is listed with Jarvis.
    func adopt(_ p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: lastPeripheralKey)
        guard state == .ready else { return }
        if exposedDevice == nil { exposedDevice = makeExposedDevice() }
        refreshRegistryMembership()
    }

    /// Adds or removes the device to match its "Share with Jarvis" setting.
    func refreshRegistryMembership() {
        guard let exposedDevice else { return }
        DeviceRegistry.shared.syncMembership(of: exposedDevice, identity: identityKey, model: model)
    }

    /// Lists a remembered device with no live link: `invoke` reconnects on demand, so Jarvis
    /// keeps its skills between launch and the first connect.
    func publishRemembered() {
        if exposedDevice == nil {
            guard WearableIdentity.remembered(identityKey) != nil else { return }
            exposedDevice = makeExposedDevice()
        }
        refreshRegistryMembership()
    }

    // MARK: Foreground / background

    func enterBackground() {
        isBackgrounded = true
        stopScan()
        releaseLinkForBackground()
    }

    /// In the background only a held link stays: a workout, or Keep Alive with the bridge on.
    func releaseLinkForBackground() {
        guard !holdsLinkForWorkout else { return }
        guard !BridgeClient.shared.enabled || !keepAliveEnabled else { return }
        if connected != nil {
            wasConnectedBeforeBackground = connected
            disconnect()
        }
    }

    func enterForeground() {
        isBackgrounded = false
        if let device = wasConnectedBeforeBackground {
            wasConnectedBeforeBackground = nil
            if holdsLink { connect(device) }
        } else if state == .ready {
            foregroundWhileReady()
        }
    }

    // MARK: CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let on = c.state == .poweredOn
        Task { @MainActor in
            self.bluetoothReady = on
            if on {
                self.bluetoothBecameReady()
            } else {
                self.state = .failed("Bluetooth off")
                self.resetLink()
            }
        }
    }

    /// iOS hands the central back after a suspension or relaunch; re-adopt the device.
    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            guard let p = restored.first(where: { $0.state == .connected || $0.state == .connecting }) else { return }
            p.delegate = self.peripheralDelegate
            self.peripheral = p
            self.connected = DiscoveredWearable(id: p.identifier, name: self.displayName(p.name), rssi: 0, peripheral: p)
            self.discoveryAttempts = 0
            if p.state == .connected { self.beginDiscovery(p) } else { self.state = .connecting }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let maker = (ad[CBAdvertisementDataManufacturerDataKey] as? Data).flatMap { data -> UInt16? in
            data.count >= 2 ? UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8 : nil
        }
        let rssi = RSSI.intValue
        Task { @MainActor in
            let isLastUsed = p.identifier.uuidString == UserDefaults.standard.string(forKey: self.lastPeripheralKey)
            guard isLastUsed || self.matchesAdvertisement(name: name, services: services, manufacturer: maker)
            else { return }
            if let i = self.discovered.firstIndex(where: { self.isSameDevice($0, as: p, name: name) }) {
                self.discovered[i] = DiscoveredWearable(id: p.identifier,
                                                        name: name.isEmpty ? self.discovered[i].name : name,
                                                        rssi: rssi, peripheral: p)
            } else {
                self.discovered.append(DiscoveredWearable(id: p.identifier, name: self.displayName(name),
                                                      rssi: rssi, peripheral: p))
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in self.beginDiscovery(p) }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            JcLog.devices.notice("\(self.linkLogName, privacy: .public): failed to connect (\(error?.localizedDescription ?? "?", privacy: .public))")
            self.state = .failed(error?.localizedDescription ?? "could not connect")
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "no error"
        Task { @MainActor in
            // A callback for a peripheral we already let go of is the tail of a deliberate
            // disconnect; acting on it would throw away a fresh connect request.
            guard p === self.peripheral else { return }
            self.setupTask?.cancel()
            self.setupTask = nil
            self.resetLink()
            guard self.holdsLink else {
                JcLog.devices.notice("\(self.linkLogName, privacy: .public): link dropped (\(reason, privacy: .public)); keep-alive off")
                self.connected = nil
                self.state = .idle
                return
            }
            JcLog.devices.notice("\(self.linkLogName, privacy: .public): link dropped (\(reason, privacy: .public)); reconnecting")
            self.discoveryAttempts = 0
            self.state = .connecting
            self.central.connect(p)
        }
    }
}
