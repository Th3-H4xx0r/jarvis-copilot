import AudioToolbox
import CoreBluetooth
import Foundation
import UIKit

struct DiscoveredRing: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var peripheral: CBPeripheral

    static func == (a: DiscoveredRing, b: DiscoveredRing) -> Bool { a.id == b.id }
}

/// App-lifetime owner of the ring's Bluetooth link.
///
/// Follows `BottleManager`'s semantics — Keep Alive holds and restores the link, off means
/// connect on demand and drop after the grace period, bridge mode holds it in the
/// background — and hands every byte to `RingSession`, which owns the protocol.
@MainActor
final class RingManager: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var bluetoothReady = false
    @Published private(set) var discovered: [DiscoveredRing] = []
    @Published private(set) var connected: DiscoveredRing?

    /// Off shows any peripheral advertising the ring's UART service, not just ring names.
    @Published var strictNameMatch = true {
        didSet {
            guard oldValue != strictNameMatch else { return }
            if connected == nil { startScan() }
        }
    }

    let session = RingSession()
    private(set) lazy var sync = RingSync(session: session, store: { [weak self] in self?.store })

    /// True while a ring screen is open: the link stays up whatever Keep Alive says.
    var screenIsOpen = false {
        didSet { if screenIsOpen { idleDropTask?.cancel(); idleDropTask = nil } }
    }

    var keepAliveEnabled: Bool { WearableKeepAlive.isOn(WearableKeepAlive.ring) }

    /// The ring hides its MAC from iOS, so identity is the remembered id, else this install's
    /// CoreBluetooth identifier.
    var deviceID: String? {
        WearableIdentity.remembered(WearableKeepAlive.ring) ?? connected?.id.uuidString
    }

    var store: RingHistoryStore? { deviceID.map { RingHistoryStore.shared(for: $0) } }
    /// What each tap, swipe or press on the ring runs.
    var inputs: RingInputStore? { deviceID.map { RingInputStore.shared(for: $0) } }
    var exposedDeviceID: String? { exposedDevice?.deviceID }

    var linkIsUp: Bool {
        switch state {
        case .connecting, .discovering, .ready: return true
        case .idle, .scanning, .failed: return false
        }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandWrite: CBCharacteristic?
    private var bigDataWrite: CBCharacteristic?
    private var pendingChunks: [Data] = []
    private var exposedDevice: ColmiR12?
    private var scanTimeoutTask: Task<Void, Never>?
    private var idleDropTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryAttempts = 0
    private var wasConnectedBeforeBackground: DiscoveredRing?
    private var isBackgrounded = false
    private var lastBackgroundDrain = Date.distantPast
    private static let lastPeripheralKey = "lastConnectedRingPeripheral"

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey:
                        "com.jarviscopilot.jarviscopilotMobileAndIOS.ringCentral"])
        session.attach(self)
        // Wires the session's push and measurement hooks before a restored link delivers any.
        _ = sync
        session.appIsActive = { UIApplication.shared.applicationState == .active }
        session.onFindPhone = { active in
            // The ring's "find my phone" gesture.
            if active { AudioServicesPlayAlertSound(SystemSoundID(1005)) }
        }
        session.onInput = { [weak self] input in self?.runAction(for: input) }
    }

    // MARK: Scanning

    func startScan() {
        guard bluetoothReady else { return }
        // A connected ring doesn't advertise; keep it in the list across rescans.
        discovered.removeAll { $0.id != connected?.id }
        surfaceKnownPeripherals()
        if !linkIsUp { state = .scanning }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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

    /// A ring iOS already holds a link to, or the one used last time, belongs in the list
    /// even though it won't show up in scan results.
    private func surfaceKnownPeripherals() {
        guard bluetoothReady else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastPeripheralKey)
        var candidates = central.retrieveConnectedPeripherals(withServices: [RingProtocol.commandService])
        if let last, let uuid = UUID(uuidString: last) {
            candidates += central.retrievePeripherals(withIdentifiers: [uuid])
        }
        for p in candidates where !discovered.contains(where: { $0.id == p.identifier }) {
            let name = p.name ?? "Ring"
            guard RingProtocol.isRingName(name) || p.identifier.uuidString == last else { continue }
            discovered.append(DiscoveredRing(id: p.identifier, name: name, rssi: 0, peripheral: p))
        }
    }

    // MARK: Connection

    func connect(_ ring: DiscoveredRing) {
        JcLog.devices.notice("ring: connect \(ring.name, privacy: .public) state=\(self.state.text, privacy: .public)")
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
        JcLog.devices.notice("ring: disconnect state=\(self.state.text, privacy: .public)")
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
        commandWrite = nil
        bigDataWrite = nil
        pendingChunks.removeAll()
        session.linkDropped()
    }

    /// Reconnects if needed and waits until the link is usable. CoreBluetooth can reopen a
    /// known peripheral by identifier, so this costs no scan.
    func ensureConnected(timeout: TimeInterval = 12) async -> Bool {
        if state == .ready { return true }
        guard bluetoothReady else { return false }
        if peripheral == nil, let known = knownPeripheral() {
            connect(DiscoveredRing(id: known.identifier, name: known.name ?? "Ring", rssi: 0, peripheral: known))
        } else if let p = peripheral, state != .connecting, state != .discovering {
            discoveryAttempts = 0
            state = .connecting
            p.delegate = self
            central.connect(p)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .ready { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return state == .ready
    }

    /// Waits (bounded) for the per-connection setup, so capability checks see real values.
    func waitForSetup(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while setupTask != nil, state == .ready, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func knownPeripheral() -> CBPeripheral? {
        if let stored = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
           let uuid = UUID(uuidString: stored),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            return known
        }
        return central.retrieveConnectedPeripherals(withServices: [RingProtocol.commandService])
            .first { RingProtocol.isRingName($0.name ?? "") }
    }

    /// Releases an on-demand link once the work is done (Keep Alive off, no screen open).
    func releaseIfIdle() {
        guard !keepAliveEnabled, !screenIsOpen else { return }
        idleDropTask?.cancel()
        idleDropTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WearableKeepAlive.idleGraceSeconds))
            // A first sync after launch easily outlasts the grace; the link goes when the work does.
            while !Task.isCancelled, self?.ringIsWorking == true {
                try? await Task.sleep(for: .seconds(5))
            }
            guard let self, !Task.isCancelled, !self.keepAliveEnabled, !self.screenIsOpen else { return }
            JcLog.devices.notice("ring: idle after on-demand use; dropping the link")
            self.disconnect()
        }
    }

    /// A tap or swipe on the ring: run whatever it is set to, and say so in the log.
    private func runAction(for input: RingInput) {
        let action = inputs?.action(for: input) ?? .none
        guard action.isSet else {
            session.log.note("Ring input: \(input.label)", "no action set")
            return
        }
        session.log.note("Ring input: \(input.label)", action.summary)
        Task { [weak self] in
            let outcome = await RingActionRunner.run(action)
            self?.session.log.note("Ran \(input.label)", outcome)
        }
    }

    private var ringIsWorking: Bool {
        setupTask != nil || session.transport.isBusy || session.measurement?.isActive == true || sync.isSyncing
    }

    /// Asks for the ring's services and keeps a watchdog on the answer. Discovery can stall
    /// for good — the ring still held by another app, or a link restored by iOS that never
    /// reports — and nothing else moves the state off "Discovering".
    private func beginDiscovery(_ p: CBPeripheral) {
        discoveryAttempts += 1
        state = .discovering
        p.delegate = self
        p.discoverServices([RingProtocol.commandService, RingProtocol.bigDataService, RingProtocol.deviceInfoService])
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.state == .discovering, self.peripheral === p else { return }
            switch self.discoveryAttempts {
            case 1:
                JcLog.devices.notice("ring: discovery stalled; asking again")
                self.beginDiscovery(p)
            case 2:
                JcLog.devices.notice("ring: discovery stalled twice; reopening the link")
                self.discoveryAttempts = 3
                self.resetLink()
                self.central.cancelPeripheralConnection(p)
                self.state = .connecting
                self.central.connect(p)
            default:
                JcLog.devices.error("ring: discovery never finished")
                self.state = .failed("the ring never answered — unbind it in QRing, or toggle Bluetooth")
            }
        }
    }

    private func becomeReady(_ p: CBPeripheral) {
        guard state != .ready else { return }
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryAttempts = 0
        state = .ready
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastPeripheralKey)
        publishToRegistry()
        if let id = deviceID { session.loadCache(deviceID: id) }
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            guard let self else { return }
            await self.session.runSetup()
            self.setupTask = nil
            guard self.state == .ready else { return }
            if let id = self.deviceID { self.session.saveCache(deviceID: id) }
            // Only ask the ring to report taps and swipes when something is set to run.
            if self.inputs?.isConfigured == true { await self.session.enableInputReporting() }
            // Find out what this ring actually answers; its own flags under-report.
            await self.session.runProbe()
            self.sync.syncIfStale()
        }
    }

    // MARK: Registry

    private func publishToRegistry() {
        guard state == .ready else { return }
        if exposedDevice == nil { exposedDevice = ColmiR12(manager: self) }
        refreshRegistryMembership()
    }

    /// Adds or removes the ring to match its "Share with Jarvis" setting.
    func refreshRegistryMembership() {
        guard let device = exposedDevice else { return }
        DeviceRegistry.shared.syncMembership(of: device, identity: WearableKeepAlive.ring, model: ColmiR12.model)
    }

    /// Registers the catalogue with no live link; `invoke` reconnects on demand.
    func publishRemembered() {
        if exposedDevice == nil {
            guard WearableIdentity.remembered(WearableKeepAlive.ring) != nil else { return }
            exposedDevice = ColmiR12(manager: self)
        }
        if let id = deviceID { session.loadCache(deviceID: id) }
        refreshRegistryMembership()
    }

    // MARK: Foreground / background

    func enterBackground() {
        isBackgrounded = true
        stopScan()
        // Bridge mode + Keep Alive holds the link so Jarvis can reach the ring; otherwise
        // the link is reopened on demand.
        guard !BridgeClient.shared.enabled || !keepAliveEnabled else { return }
        if connected != nil {
            wasConnectedBeforeBackground = connected
            disconnect()
        }
    }

    func enterForeground() {
        isBackgrounded = false
        session.noteAppBecameActive()
        if let ring = wasConnectedBeforeBackground {
            wasConnectedBeforeBackground = nil
            if keepAliveEnabled { connect(ring) }
        } else if state == .ready {
            sync.syncIfStale()
        }
    }
}

// MARK: - RingLink

extension RingManager: RingLink {
    var isLinkReady: Bool { state == .ready && peripheral != nil && commandWrite != nil }
    var hasBigDataChannel: Bool { bigDataWrite != nil }

    func send(_ data: Data, on channel: RingChannel) {
        guard let peripheral else { return }
        switch channel {
        case .command:
            guard let characteristic = commandWrite else { return }
            let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            peripheral.writeValue(data, for: characteristic, type: type)
        case .bigData:
            guard bigDataWrite != nil else {
                JcLog.devices.notice("ring: no large-data characteristic on this ring")
                return
            }
            let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
            let size = max(RingProtocol.minimumChunk, min(session.chunkSize, mtu))
            pendingChunks += RingProtocol.chunks(data, size: size)
            drainChunks()
        }
    }

    /// Write-without-response chunks go out as fast as CoreBluetooth will take them.
    private func drainChunks() {
        guard let peripheral, let characteristic = bigDataWrite else {
            pendingChunks.removeAll()
            return
        }
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        while !pendingChunks.isEmpty {
            if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse { return }
            peripheral.writeValue(pendingChunks.removeFirst(), for: characteristic, type: type)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension RingManager: CBCentralManagerDelegate {
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

    /// iOS hands the central back after a suspension or relaunch; re-adopt the ring.
    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            guard let p = restored.first(where: { $0.state == .connected || $0.state == .connecting }) else { return }
            p.delegate = self
            self.peripheral = p
            self.connected = DiscoveredRing(id: p.identifier, name: p.name ?? "Ring", rssi: 0, peripheral: p)
            self.discoveryAttempts = 0
            if p.state == .connected {
                self.beginDiscovery(p)
            } else {
                self.state = .connecting
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let rssi = RSSI.intValue
        Task { @MainActor in
            let byName = RingProtocol.isRingName(name)
            let byService = services.contains(RingProtocol.commandService)
            guard byName || (!self.strictNameMatch && byService) else { return }
            if let i = self.discovered.firstIndex(where: { $0.id == p.identifier }) {
                self.discovered[i].rssi = rssi
                if !name.isEmpty { self.discovered[i].name = name }
            } else {
                self.discovered.append(DiscoveredRing(id: p.identifier, name: name.isEmpty ? "Ring" : name,
                                                      rssi: rssi, peripheral: p))
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            self.beginDiscovery(p)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            JcLog.devices.notice("ring: failed to connect (\(error?.localizedDescription ?? "?", privacy: .public))")
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
            guard self.keepAliveEnabled || self.screenIsOpen else {
                JcLog.devices.notice("ring: link dropped (\(reason, privacy: .public)); keep-alive off")
                self.connected = nil
                self.state = .idle
                return
            }
            JcLog.devices.notice("ring: link dropped (\(reason, privacy: .public)); reconnecting")
            self.discoveryAttempts = 0
            self.state = .connecting
            self.central.connect(p)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RingManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            let services = p.services ?? []
            guard services.contains(where: { $0.uuid == RingProtocol.commandService }) else {
                self.state = .failed("ring service not found")
                return
            }
            for service in services {
                p.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            let characteristics = service.characteristics ?? []
            // Record the writes BEFORE subscribing: the notify callback checks for the write
            // characteristic, and it can land before this loop would have reached it.
            for characteristic in characteristics {
                switch characteristic.uuid {
                case RingProtocol.commandWrite:
                    self.commandWrite = characteristic
                case RingProtocol.bigDataWrite:
                    self.bigDataWrite = characteristic
                case RingProtocol.firmwareRevision, RingProtocol.hardwareRevision:
                    p.readValue(for: characteristic)
                default:
                    break
                }
            }
            for characteristic in characteristics
            where characteristic.uuid == RingProtocol.commandNotify || characteristic.uuid == RingProtocol.bigDataNotify {
                if !characteristic.isNotifying { p.setNotifyValue(true, for: characteristic) }
            }
            // A reconnect can hand back a subscription that is still live, in which case no
            // notify callback follows — so go ready here rather than wait for one that never comes.
            if self.commandWrite != nil,
               characteristics.contains(where: { $0.uuid == RingProtocol.commandNotify && $0.isNotifying }) {
                self.becomeReady(p)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                JcLog.devices.error("ring: notify on \(characteristic.uuid.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard characteristic.uuid == RingProtocol.commandNotify, characteristic.isNotifying else { return }
            // The write characteristic may still be on its way; the characteristics callback
            // finishes the job in that case, so this must not fail the connection.
            if self.commandWrite != nil { self.becomeReady(p) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            switch uuid {
            case RingProtocol.commandNotify:
                self.session.transport.receive(data, on: .command)
            case RingProtocol.bigDataNotify:
                self.session.transport.receive(data, on: .bigData)
            case RingProtocol.firmwareRevision:
                self.session.setRevision(firmware: String(decoding: data, as: UTF8.self), hardware: nil)
            case RingProtocol.hardwareRevision:
                self.session.setRevision(firmware: nil, hardware: String(decoding: data, as: UTF8.self))
            default:
                return
            }
            // A BLE wake is a reliable slice of background time: spend it on Jarvis's queue —
            // once per burst, since a sync delivers hundreds of notifications.
            if self.isBackgrounded, BridgeClient.shared.enabled, BridgeClient.shared.status != .online,
               Date().timeIntervalSince(self.lastBackgroundDrain) > 10 {
                self.lastBackgroundDrain = Date()
                await BridgeClient.shared.drainQueue(foreground: false)
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        Task { @MainActor in self.drainChunks() }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            JcLog.devices.notice("ring: write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
