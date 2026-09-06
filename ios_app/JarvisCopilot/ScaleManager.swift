import Foundation
import CoreBluetooth

struct DiscoveredScale: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ScaleManager: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var bluetoothReady = false
    @Published private(set) var discovered: [DiscoveredScale] = []
    @Published private(set) var connected: DiscoveredScale?
    @Published private(set) var latestObservation: ScaleObservation?
    /// Mirrors the scanner-wide Jarvis-device filter. When disabled, unknown BLE
    /// peripherals are visible for discovery; when enabled only ESF551 candidates show.
    @Published var strictNameMatch = true {
        didSet { if oldValue != strictNameMatch, connected == nil { startScan() } }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var exposedDevice: Esf551Scale?
    private var lastStable: ScaleObservation?
    private var frameAccumulator = VsV2FrameAccumulator()
    private let lastScaleIdentifierKey = "lastESF551PeripheralIdentifier"
    private var nextSequence: UInt8 = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.jarviscopilot.jarviscopilotMobileAndIOS.scaleCentral"])
    }

    func startScan() {
        guard bluetoothReady else { return }
        discovered.removeAll()
        state = .scanning
        restoreKnownPeripheral()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// An awake scale may already be connected/restored and therefore not emit a fresh
    /// advertisement. Keep its last CoreBluetooth identifier and surface it alongside
    /// ordinary scan results so it never vanishes from the device list in that state.
    private func restoreKnownPeripheral() {
        guard let raw = UserDefaults.standard.string(forKey: lastScaleIdentifierKey),
              let id = UUID(uuidString: raw) else { return }
        let candidates = central.retrievePeripherals(withIdentifiers: [id])
            + central.retrieveConnectedPeripherals(withServices: [ScaleProtocol.primaryService, ScaleProtocol.alternateService])
        // Do not blindly trust a previously saved identifier. Older builds could save
        // an unrelated nearby peripheral while broad scanning was enabled; require a
        // current ESF551 name/service match before restoring a card.
        for candidate in candidates where accept(candidate) && !discovered.contains(where: { $0.id == candidate.identifier }) {
            discovered.append(DiscoveredScale(id: candidate.identifier,
                                              name: candidate.name ?? "ESF551",
                                              rssi: 0,
                                              peripheral: candidate))
        }
    }

    func connect(_ scale: DiscoveredScale) {
        central.stopScan(); state = .connecting; peripheral = scale.peripheral; connected = scale
        latestObservation = nil
        lastStable = nil
        frameAccumulator.reset()
        print("[Scale] connecting \(scale.name) \(scale.id)")
        scale.peripheral.delegate = self
        central.connect(scale.peripheral)
    }

    func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        unpublish(); peripheral = nil; connected = nil; notifyCharacteristic = nil; writeCharacteristic = nil
        latestObservation = nil; lastStable = nil
        frameAccumulator.reset(); state = .idle
    }

    private func accept(_ peripheral: CBPeripheral, advertisementData: [String: Any] = [:]) -> Bool {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = (advertisedName ?? peripheral.name ?? "").lowercased()
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isScaleService = serviceUUIDs.contains(ScaleProtocol.primaryService)
            || serviceUUIDs.contains(ScaleProtocol.alternateService)
        // The scale scanner must never turn unrelated nearby BLE devices into fake
        // Etekcity cards. Both modes show devices Jarvis can actually identify; the
        // broader mode only relaxes future model-specific naming rules.
        return isScaleService || name.contains("esf551") || name.contains("esf-551")
            || name.contains("etekcity") || name.contains("smart fitness scale")
    }

    private func record(_ observation: ScaleObservation) {
        guard observation.weightKg > 0 else {
            latestObservation = nil
            lastStable = nil
            return
        }
        latestObservation = observation
        guard observation.isStable,
              lastStable?.weightKg != observation.weightKg || lastStable?.timestamp != observation.timestamp
        else { return }
        lastStable = observation
        let history = ScaleHistoryStore.shared
        let profile = history.activeProfile
        let metrics = profile.map { ScaleMetricsCalculator.metrics(weightKg: observation.weightKg,
            impedanceOhms: observation.impedanceOhms, profile: $0) } ?? [.weight: observation.weightKg]
        history.add(ScaleReading(date: observation.timestamp, profileID: profile?.id, model: Esf551Scale.model,
            deviceID: connected?.id.uuidString ?? "unknown", weightKg: observation.weightKg,
            impedance: observation.impedanceOhms, metrics: metrics, scaleUnit: .kilograms))
    }

    /// Mirrors the stock app's post-subscription initialization. The scale uses this
    /// to timestamp a stable weighing and begin its normal live-reporting session.
    private func sendTimeSync() {
        guard let peripheral, let writeCharacteristic else {
            print("[Scale] cannot send time sync: command characteristic unavailable")
            return
        }
        let frame = ScaleProtocol.makeTimeSyncFrame(sequence: nextSequence)
        nextSequence &+= 1
        let type: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let hex = frame.map { String(format: "%02X", $0) }.joined()
        print("[Scale] writing time sync to \(writeCharacteristic.uuid): \(hex)")
        peripheral.writeValue(Data(frame), for: writeCharacteristic, type: type)
    }

    private func publish() {
        if exposedDevice == nil { exposedDevice = Esf551Scale(manager: self) }
        refreshRegistryMembership()
    }

    /// Adds or removes the scale from Jarvis according to its per-device setting.
    /// The connected scale still works locally when sharing is off.
    func refreshRegistryMembership() {
        guard let device = exposedDevice else { return }
        let shouldShare = BridgeClient.isExposed(device.deviceID)
        let isShared = DeviceRegistry.shared.device(id: device.deviceID) != nil
        guard shouldShare != isShared else { return }
        if shouldShare {
            DeviceRegistry.shared.register(device)
            BridgeClient.remember(deviceID: device.deviceID, model: Esf551Scale.model)
        } else {
            DeviceRegistry.shared.remove(deviceID: device.deviceID)
            BridgeClient.forget(deviceID: device.deviceID)
        }
        BridgeClient.shared.sendRegistration()
    }

    /// Stable Jarvis identifier used by the scale Settings toggle.
    var exposedDeviceID: String? { exposedDevice?.deviceID }

    private func unpublish() {
        guard let exposedDevice else { return }
        DeviceRegistry.shared.remove(deviceID: exposedDevice.deviceID)
        self.exposedDevice = nil
        BridgeClient.shared.sendRegistration()
    }
}

extension ScaleManager: CBCentralManagerDelegate {
    /// Required whenever CoreBluetooth restoration is enabled. Re-adopt a scale that
    /// iOS restored after suspension or relaunch rather than creating a second link.
    nonisolated func centralManager(_ central: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            guard let peripheral = restored.first(where: {
                $0.state == .connected || $0.state == .connecting
            }) else { return }
            self.peripheral = peripheral
            peripheral.delegate = self
            connected = DiscoveredScale(id: peripheral.identifier, name: peripheral.name ?? "ESF551",
                                        rssi: 0, peripheral: peripheral)
            state = peripheral.state == .connected ? .discovering : .connecting
            if peripheral.state == .connected {
                peripheral.discoverServices([ScaleProtocol.primaryService, ScaleProtocol.alternateService])
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            bluetoothReady = central.state == .poweredOn
            if bluetoothReady { startScan() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            guard accept(peripheral, advertisementData: advertisementData) else { return }
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastScaleIdentifierKey)
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let scale = DiscoveredScale(id: peripheral.identifier, name: advertisedName ?? peripheral.name ?? "ESF551",
                                        rssi: RSSI.intValue, peripheral: peripheral)
            if let index = discovered.firstIndex(where: { $0.id == scale.id }) {
                discovered[index] = scale
            } else if let index = discovered.firstIndex(where: {
                $0.name.caseInsensitiveCompare(scale.name) == .orderedSame
            }) {
                // A few ESF551 firmware revisions rotate their advertised identity;
                // retain the strongest/latest representative rather than duplicating
                // the same physical scale in the list.
                discovered[index] = scale
            } else {
                discovered.append(scale)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            print("[Scale] connected; discovering services")
            state = .discovering
            peripheral.discoverServices([ScaleProtocol.primaryService, ScaleProtocol.alternateService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) { Task { @MainActor in disconnect() } }
}

extension ScaleManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            print("[Scale] services \(peripheral.services?.map { $0.uuid.uuidString } ?? []) error=\(String(describing: error))")
            for service in peripheral.services ?? [] {
                if service.uuid == ScaleProtocol.primaryService || service.uuid == ScaleProtocol.alternateService {
                    // The ESF551 reports FFF1 as its stream and FFF2 as its command
                    // endpoint (the reverse of the generic SDK constant names).
                    peripheral.discoverCharacteristics(nil, for: service)
                }
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            let details = service.characteristics?.map { "\($0.uuid.uuidString):\($0.properties.rawValue)" } ?? []
            print("[Scale] characteristics \(service.uuid): \(details) error=\(String(describing: error))")
            guard let characteristics = service.characteristics else { return }
            let stream = characteristics.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
                ?? characteristics.first { $0.uuid == ScaleProtocol.primaryWrite || $0.uuid == ScaleProtocol.alternateWrite }
            let command = characteristics.first { $0.uuid == ScaleProtocol.primaryNotify || $0.uuid == ScaleProtocol.alternateNotify }
            guard let stream else { return }
            notifyCharacteristic = stream
            writeCharacteristic = command
            guard stream.properties.contains(.notify) || stream.properties.contains(.indicate) else {
                print("[Scale] stream \(stream.uuid) has no notify/indicate property")
                return
            }
            peripheral.setNotifyValue(true, for: stream)
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            print("[Scale] notify \(characteristic.uuid) on=\(characteristic.isNotifying) error=\(String(describing: error))")
            if error == nil, characteristic.isNotifying {
                state = .ready
                publish()
                sendTimeSync()
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        Task { @MainActor in
            let bytes = Array(value)
            let hex = bytes.map { String(format: "%02X", $0) }.joined()
            let frames = frameAccumulator.append(bytes)
            print("[Scale] notify chunk=\(hex) completeFrames=\(frames.count)")
            for frame in frames {
                let observation = ScaleProtocol.parse(frame)
                print("[Scale] frame parsed=\(observation != nil)")
                if let observation { record(observation) }
            }
        }
    }
}
