import Foundation
import CoreBluetooth

struct DiscoveredBottle: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var peripheral: CBPeripheral

    var hasModel: Bool { BottleProtocol.hasModel(forName: name) }

    static func == (a: DiscoveredBottle, b: DiscoveredBottle) -> Bool { a.id == b.id }
}

struct TrafficEntry: Identifiable {
    enum Direction { case out, `in` }
    let id = UUID()
    let direction: Direction
    let hex: String
    let note: String
}

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

@MainActor
final class BottleManager: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var bluetoothReady = false
    @Published private(set) var discovered: [DiscoveredBottle] = []
    @Published private(set) var connected: DiscoveredBottle?

    @Published private(set) var status: BottleStatus?
    @Published private(set) var version: BottleVersion?
    @Published private(set) var macAddress: String?
    @Published private(set) var reminderSlots: [TimeSlot] = []
    @Published private(set) var autoCleanSlots: [TimeSlot] = []
    @Published private(set) var traffic: [TrafficEntry] = []

    /// Set false to see every bottle-like peripheral, not just name-matched ones.
    @Published var strictNameMatch = true {
        didSet {
            guard oldValue != strictNameMatch else { return }
            // The filter is applied at discovery time, so without a rescan the list keeps
            // whatever it already had until the user hits refresh themselves.
            if connected == nil { startScan() }
        }
    }

    /// Opt-in continuous polling, for watching traffic while reverse-engineering.
    /// Off by default: an idle connection should generate no traffic at all.
    @Published var liveUpdates = false { didSet { updatePolling() } }

    private var wasConnectedBeforeBackground: DiscoveredBottle?
    /// Bridge mode holds the BLE link open in the background. That link is nearly free
    /// on its own — the drain came from *polling* — so all periodic traffic is
    /// suppressed while backgrounded and the server reads state on demand instead.
    private var isBackgrounded = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?

    // The app serialises writes: one in flight, next goes out on reply or timeout.
    private var queue: [BottleCommand] = []
    private var inFlight: BottleCommand?
    private var timeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var scanTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        // The restore identifier is what actually enables background CoreBluetooth.
        // `UIBackgroundModes: [bluetooth-central]` on its own does nothing — without
        // this, iOS suspends the app on background and drops the connection.
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey:
                        "com.jarviscopilot.jarviscopilotMobileAndIOS.central"])
    }

    // MARK: Scanning

    func startScan() {
        guard bluetoothReady else { return }
        discovered.removeAll()
        state = .scanning
        // No duplicate reports: one sighting is all the list needs, and duplicate-flooding
        // an unfiltered scan is the most power-hungry mode CoreBluetooth offers.
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
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        central.stopScan()
        if case .scanning = state { state = .idle }
    }

    // MARK: Connection

    func connect(_ bottle: DiscoveredBottle) {
        stopScan()
        resetDeviceState()
        peripheral = bottle.peripheral
        connected = bottle
        state = .connecting
        central.connect(bottle.peripheral)
    }

    func disconnect() {
        pollTask?.cancel(); pollTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        connected = nil
        writeChar = nil
        queue.removeAll()
        inFlight = nil
        state = .idle
    }

    /// The `WearableDevice` face of this bottle, registered while connected so the
    /// JarvisCopilot bridge can advertise its commands.
    private var exposedDevice: VsitooS1Pro?

    /// Registry membership follows the connection, and re-registers with the bridge
    /// when the catalogue changes.
    /// The last bottle we were connected to, so a queued command can bring the link
    /// back up without scanning.
    private static let lastPeripheralKey = "lastConnectedPeripheral"

    /// Reconnects if needed and waits for the link to be usable. Returns false on
    /// timeout. CoreBluetooth can re-open a known peripheral by identifier, so this
    /// costs no scan.
    func ensureConnected(timeout: TimeInterval = 12) async -> Bool {
        if state == .ready { return true }
        guard bluetoothReady else { return false }

        if peripheral == nil,
           let stored = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
           let uuid = UUID(uuidString: stored),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(DiscoveredBottle(id: known.identifier,
                                     name: known.name ?? "VSITOO-S1-Pro",
                                     rssi: 0,
                                     peripheral: known))
        } else if let p = peripheral, state != .connecting, state != .discovering {
            central.connect(p)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .ready { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func publishToRegistry() {
        guard state == .ready else { return }
        if exposedDevice == nil {
            exposedDevice = VsitooS1Pro(manager: self)
        }
        refreshRegistryMembership()
    }

    /// Adds or removes this bottle from the registry to match its "Share with Jarvis"
    /// setting. Called on connect and whenever the user flips that toggle.
    func refreshRegistryMembership() {
        guard let device = exposedDevice else { return }
        let shouldShare = BridgeClient.isExposed(device.deviceID)
        let isShared = DeviceRegistry.shared.device(id: device.deviceID) != nil
        guard shouldShare != isShared else { return }
        if shouldShare {
            DeviceRegistry.shared.register(device)
            BridgeClient.remember(deviceID: device.deviceID, model: VsitooS1Pro.model)
        } else {
            DeviceRegistry.shared.remove(deviceID: device.deviceID)
            if !BridgeClient.isExposed(device.deviceID) {
                // Opted out, as opposed to merely offline.
                BridgeClient.forget(deviceID: device.deviceID)
            }
        }
        BridgeClient.shared.sendRegistration()
    }

    /// The stable id this bottle is exposed under, for the settings toggle.
    var exposedDeviceID: String? { exposedDevice?.deviceID }

    private func unpublishFromRegistry() {
        guard let device = exposedDevice else { return }
        DeviceRegistry.shared.remove(deviceID: device.deviceID)
        exposedDevice = nil
        BridgeClient.shared.sendRegistration()
    }

    private func resetDeviceState() {
        status = nil; version = nil; macAddress = nil
        reminderSlots = []; autoCleanSlots = []
        traffic.removeAll()
    }

    // MARK: Sending

    func send(_ command: BottleCommand) {
        queue.append(command)
        if !command.isQuery { queue.append(.status) }
        pump()
    }

    func send(_ commands: [BottleCommand]) {
        for c in commands { queue.append(c); if !c.isQuery { queue.append(.status) } }
        pump()
    }

    private func pump() {
        guard inFlight == nil,
              let next = queue.first,
              let p = peripheral,
              let ch = writeChar,
              case .ready = state
        else { return }

        queue.removeFirst()
        inFlight = next
        log(.out, next.hex, next.label)

        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(next.bytes, for: ch, type: type)

        // Timeouts mirror the app's: simple queries 500ms, everything else 800ms.
        let isSimple = [0x02, 0x03, 0x07].contains(next.opcode)
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: isSimple ? 500_000_000 : 800_000_000)
            guard !Task.isCancelled else { return }
            self?.finishInFlight()
        }
    }

    private func finishInFlight() {
        timeoutTask?.cancel(); timeoutTask = nil
        inFlight = nil
        pump()
    }

    private func log(_ direction: TrafficEntry.Direction, _ hex: String, _ note: String) {
        traffic.insert(TrafficEntry(direction: direction, hex: hex, note: note), at: 0)
        if traffic.count > 60 { traffic.removeLast(traffic.count - 60) }
    }

    // MARK: Notifications

    private func handleNotify(_ data: Data) {
        let op = data.first ?? 0
        var note = String(format: "op %02X", op)

        switch op {
        case 0x07:
            if let s = BottleStatus(frame: data) { status = s; note = "status"; updatePolling() }
        case 0x0B:
            if let v = BottleVersion(frame: data) { version = v; note = "version \(v.firmware)" }
        case 0x10:
            if let m = parseMacAddress(frame: data) {
                macAddress = m
                note = "mac \(m)"
                // deviceID is derived from the MAC, so the catalogue changed identity.
                refreshRegistryMembership()
                BridgeClient.shared.sendRegistration()
            }
        case 0x05:
            reminderSlots = BottleProtocol.decodeTimeSlots(data.dropFirst())
            note = "reminders 1"
            send(.reminderListPart2)
        case 0x06:
            reminderSlots += BottleProtocol.decodeTimeSlots(data.dropFirst())
            note = "reminders 2"
        case 0x15:
            autoCleanSlots = BottleProtocol.decodeTimeSlots(data.dropFirst())
            note = "auto-clean times"
        case 0x02:
            note = "clock ack"
            send([.reminderListPart1, .autoSteriliseTimes])
        default:
            break
        }

        log(.in, data.hexString, note)

        // A reply for the command in flight releases the queue.
        if let f = inFlight, f.opcode == op {
            finishInFlight()
        }
    }

    /// The stock VSITOO app sends **nothing** on an idle connection — its 500 ms timer only
    /// drains a queue and its 3 s timer only reconnects. Status is read on connect and once
    /// after each user action. So we only poll while a sterilise cycle is actually running,
    /// where progress has to move and the UV-C LED dwarfs the radio anyway.
    private func updatePolling() {
        // Re-entered from handleNotify on every status frame, so without this guard a
        // running cycle would restart polling right after enterBackground() stopped it.
        let shouldPoll = !isBackgrounded && (liveUpdates || (status?.isSterilising ?? false))
        guard shouldPoll else {
            pollTask?.cancel(); pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self, self.state == .ready else { return }
                self.send(.status)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel(); pollTask = nil
    }

    // MARK: Foreground / background

    /// The app disconnects rather than holding an idle link in your pocket
    /// (`onHide` → `setNotify(false)` → `bleDisconnect()` → `closeAdapter()`).
    func enterBackground() {
        isBackgrounded = true
        stopPolling()
        stopScan()
        // Bridge mode deliberately holds the link: JarvisCopilot can't run a command
        // on a bottle we've disconnected from. Costs battery, which is why it's opt-in.
        guard !BridgeClient.shared.enabled else { return }
        if connected != nil { wasConnectedBeforeBackground = connected; disconnect() }
    }

    func enterForeground() {
        isBackgrounded = false
        updatePolling()
        if let b = wasConnectedBeforeBackground {
            wasConnectedBeforeBackground = nil
            connect(b)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BottleManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let on = c.state == .poweredOn
        Task { @MainActor in
            self.bluetoothReady = on
            if on { self.startScan() } else { self.state = .failed("Bluetooth off") }
        }
    }

    /// Called when iOS hands the central back after a background suspension or a
    /// relaunch. The peripherals here are already connected — re-adopt them rather than
    /// starting a fresh scan.
    nonisolated func centralManager(_ c: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey]
            as? [CBPeripheral] ?? []
        Task { @MainActor in
            for p in restored where p.state == .connected || p.state == .connecting {
                p.delegate = self
                self.peripheral = p
                self.connected = DiscoveredBottle(id: p.identifier,
                                                  name: p.name ?? "VSITOO-S1-Pro",
                                                  rssi: 0,
                                                  peripheral: p)
                self.state = .discovering
                // Services may already be populated, but re-discovering is cheap and
                // guarantees writeChar/notifyChar are wired up again.
                p.discoverServices([CBUUID(string: BottleProtocol.serviceUUID)])
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager,
                                    didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = ad[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? p.name ?? ""
        let rssi = RSSI.intValue
        Task { @MainActor in
            let matches = BottleProtocol.namePrefixes.contains { name.hasPrefix($0) }
            guard matches || (!self.strictNameMatch && !name.isEmpty) else { return }

            if let i = self.discovered.firstIndex(where: { $0.id == p.identifier }) {
                self.discovered[i].rssi = rssi
                self.discovered[i].name = name
            } else {
                self.discovered.append(
                    DiscoveredBottle(id: p.identifier, name: name, rssi: rssi, peripheral: p))
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            self.state = .discovering
            p.delegate = self
            p.discoverServices([CBUUID(string: BottleProtocol.serviceUUID)])
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager,
                                    didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.state = .failed(error?.localizedDescription ?? "could not connect")
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager,
                                    didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.pollTask?.cancel(); self.pollTask = nil
            self.timeoutTask?.cancel(); self.timeoutTask = nil
            self.inFlight = nil
            self.queue.removeAll()
            self.connected = nil
            self.state = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BottleManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: {
            $0.uuid == CBUUID(string: BottleProtocol.serviceUUID)
        }) else {
            Task { @MainActor in self.state = .failed("service A300 not found") }
            return
        }
        p.discoverCharacteristics(nil, for: svc)
    }

    nonisolated func peripheral(_ p: CBPeripheral,
                                didDiscoverCharacteristicsFor svc: CBService,
                                error: Error?) {
        let write  = svc.characteristics?.first { $0.uuid == CBUUID(string: BottleProtocol.writeUUID) }
        let notify = svc.characteristics?.first { $0.uuid == CBUUID(string: BottleProtocol.notifyUUID) }

        Task { @MainActor in
            self.writeChar = write
            guard write != nil, let n = notify else {
                self.state = .failed("A301/A303 characteristics missing")
                return
            }
            p.setNotifyValue(true, for: n)
            self.state = .ready
            UserDefaults.standard.set(p.identifier.uuidString,
                                      forKey: Self.lastPeripheralKey)
            self.publishToRegistry()
            // Same opening sequence the app performs.
            self.send([.status, .macAddress, .version, .setClock(Date())])
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral,
                                didUpdateValueFor ch: CBCharacteristic,
                                error: Error?) {
        guard let data = ch.value, !data.isEmpty else { return }
        Task { @MainActor in
            self.handleNotify(data)
            // Being woken for a BLE event is the one reliable slice of background
            // runtime we get without a push entitlement — spend it on the queue.
            if self.isBackgrounded, BridgeClient.shared.enabled {
                await BridgeClient.shared.drainQueue(foreground: false)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral,
                                didWriteValueFor ch: CBCharacteristic,
                                error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.log(.out, "", "write failed: \(error.localizedDescription)")
            self.finishInFlight()
        }
    }
}
