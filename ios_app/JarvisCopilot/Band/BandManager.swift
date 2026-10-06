import CoreBluetooth
import Foundation
import UIKit

/// App-lifetime owner of the HBand (Veepoo) band's Bluetooth link: service F0080001, write
/// `…0003`, notify `…0002`.
///
/// Mirrors `X5Manager`: Keep Alive holds the link, off means connect on demand and drop after
/// the grace period, a workout holds it in the background; every notification goes to
/// `BandSession`. The band advertises only FEE7 and Veepoo's manufacturer data, so a device it
/// hasn't seen before must pass the Veepoo handshake before it is remembered.
@MainActor
final class BandManager: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var bluetoothReady = false
    @Published private(set) var discovered: [DiscoveredRing] = []
    @Published private(set) var connected: DiscoveredRing?
    /// Bands forgotten this session: their page must not reconnect them on the way out.
    @Published private(set) var forgottenIDs: Set<UUID> = []

    let session = BandSession()
    private(set) lazy var sync = BandSync(session: session, store: { [weak self] in self?.store })

    /// Days the sync changed — Jarvis Health pushes them.
    var onDaysChanged: ((Set<String>) -> Void)?
    /// Whether a workout on the band is under way (the workout controller answers).
    var workoutHold: (() -> Bool)?
    /// The workout controller, for `band_workout`.
    weak var workouts: RingWorkoutController?
    var workoutRunning: Bool { workoutHold?() ?? false }
    var holdsLinkForWorkout: Bool { workoutRunning }

    var keepAliveEnabled: Bool { WearableKeepAlive.isOn(WearableKeepAlive.band) }

    var deviceID: String? {
        WearableIdentity.remembered(WearableKeepAlive.band)
            ?? connected?.id.uuidString
            ?? UserDefaults.standard.string(forKey: Self.lastPeripheralKey)
    }

    var store: RingHistoryStore? { deviceID.map { RingHistoryStore.shared(for: $0) } }
    var exposedDeviceID: String? { exposedDevice?.deviceID }

    var linkIsUp: Bool {
        switch state {
        case .connecting, .discovering, .ready: return true
        case .idle, .scanning, .failed: return false
        }
    }

    /// True while the band's screen is open: the link stays up whatever Keep Alive says.
    var screenIsOpen = false {
        didSet {
            guard oldValue != screenIsOpen else { return }
            if screenIsOpen { idleDropTask?.cancel(); idleDropTask = nil } else { releaseIfIdle() }
        }
    }

    /// True while the Health tab is open: held so a refresh or a spot check needs no connect.
    var healthIsOpen = false {
        didSet {
            guard oldValue != healthIsOpen else { return }
            if healthIsOpen {
                idleDropTask?.cancel()
                idleDropTask = nil
                if !linkIsUp { Task { _ = await ensureConnected(timeout: 12) } }
            } else {
                releaseIfIdle()
            }
        }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    /// The ECG waveform channel, subscribed while an ECG runs.
    private var waveCharacteristic: CBCharacteristic?
    private var exposedDevice: BandDevice?
    private var scanTimeoutTask: Task<Void, Never>?
    private var idleDropTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryAttempts = 0
    private var wasConnectedBeforeBackground: DiscoveredRing?
    private var isBackgrounded = false
    static let lastPeripheralKey = "lastConnectedBandPeripheral"

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey:
                        "com.jarviscopilot.jarviscopilotMobileAndIOS.bandCentral"])
        session.attach(self)
        onDaysChanged = { [weak self] keys in
            guard let self else { return }
            Task { await BandHealthPush.push(keys, manager: self) }
            WidgetDataHub.shared.refreshSoon()
        }
        sync.onDaysChanged = { [weak self] keys in self?.onDaysChanged?(keys) }
        session.onMeasured = { [weak self] reading in self?.record(reading) }
        // The ECG's waveform channel, on while one runs (as the SDK's setChannelNotify).
        session.onEcgWave = { [weak self] on in
            guard let self, let peripheral = self.peripheral, let wave = self.waveCharacteristic else { return }
            peripheral.setNotifyValue(on, for: wave)
        }
    }

    /// A reading that ended goes into its day, like the rings' spot checks: the record (values in
    /// canonical units), and heart rate / SpO₂ / temperature into the day's manual series too.
    /// Then that day goes to Jarvis Health.
    private func record(_ r: BandReading) {
        guard let store, r.status != .measuring else { return }
        let key = RingDates.dayKey(r.date)
        let calendar = Calendar.current
        let minute = calendar.component(.hour, from: r.date) * 60 + calendar.component(.minute, from: r.date)
        var extra: [String: Double] = [:]
        if let g = r.bloodGlucose { extra["blood_glucose_mmol_l"] = g }
        if let c = r.bloodComponent {
            for (k, v) in c.json { if let d = v as? Double { extra[k] = d } }
        }
        if let b = r.bodyComposition {
            for (k, v) in b.json { if let d = v as? Double { extra[k] = d } else if let i = v as? Int { extra[k] = Double(i) } }
        }
        if r.measure == .ecg {
            if let h = r.hrv { extra["hrv"] = Double(h) }
            if let b = r.respiratoryRate { extra["respiratory_rate"] = Double(b) }
            if let diagnosis = r.ecg { extra.merge(diagnosis.extra) { a, _ in a } }
            // The whole reading, for its report page.
            if let deviceID, r.ecg != nil || !session.ecgSamples.isEmpty {
                BandEcgStore.save(BandEcgReport(date: r.date, diagnosis: r.ecg, heartRates: session.ecgHeartRates,
                                                samples: session.ecgSamples, sampleRate: session.ecgSampleRate),
                                  deviceID: deviceID)
            }
        }
        let value = r.heartRate ?? r.spo2 ?? r.stress
        store.update(key) { day in
            day.measurements.append(RingMeasurementRecord(
                type: r.measure.name, time: r.date, outcome: r.status.rawValue, value: value,
                systolic: r.systolic, diastolic: r.diastolic, celsius: r.temperatureC,
                extra: extra.isEmpty ? nil : extra))
            guard r.finished else { return }
            if let hr = r.heartRate, r.measure == .heartRate {
                day.manualHeartRate = RingDay.merged(day.manualHeartRate, [RingTimedValue(minute: minute, value: Double(hr))])
            }
            if let o = r.spo2 { day.manualSpO2 = RingDay.merged(day.manualSpO2, [RingTimedValue(minute: minute, value: Double(o))]) }
            if let t = r.temperatureC {
                day.instantTemperature = RingDay.merged(day.instantTemperature, [RingTimedValue(minute: minute, value: t)])
            }
        }
        if r.finished { onDaysChanged?([key]) }
    }

    /// A device for the band list: a Veepoo advertisement (manufacturer 0xF8F8), or the E910's
    /// own name. Never a ring or the scale, which have their own cards.
    static func isCandidate(name: String, manufacturer: UInt16?) -> Bool {
        guard !RingProtocol.isRingName(name), !X5Protocol.isX5Name(name), !X5Manager.isScaleName(name) else { return false }
        if manufacturer == BandGATT.manufacturer { return true }
        let n = name.uppercased()
        return n.hasPrefix("E910") || n.contains("HBAND") || n.contains("VEEPOO")
    }

    // MARK: Scanning

    func startScan() {
        guard bluetoothReady else { return }
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

    /// A band iOS already holds doesn't advertise: find it by its service, or as the last one used.
    private func surfaceKnownPeripherals() {
        guard bluetoothReady else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastPeripheralKey)
        var candidates = central.retrieveConnectedPeripherals(withServices: [BandGATT.service])
        if let last, let uuid = UUID(uuidString: last) {
            candidates += central.retrievePeripherals(withIdentifiers: [uuid])
        }
        for p in candidates where !discovered.contains(where: { $0.id == p.identifier }) {
            discovered.append(DiscoveredRing(id: p.identifier, name: p.name ?? BandDevice.fallbackName, rssi: 0, peripheral: p))
        }
    }

    // MARK: Connection

    func connect(_ band: DiscoveredRing) {
        JcLog.devices.notice("band: connect \(band.name, privacy: .public) state=\(self.state.text, privacy: .public)")
        stopScan()
        if let current = peripheral, current.identifier != band.id {
            central.cancelPeripheralConnection(current)
            resetLink()
        }
        peripheral = band.peripheral
        connected = band
        if !discovered.contains(where: { $0.id == band.id }) { discovered.insert(band, at: 0) }
        discoveryAttempts = 0
        state = .connecting
        band.peripheral.delegate = self
        central.connect(band.peripheral)
    }

    func disconnect() {
        JcLog.devices.notice("band: disconnect state=\(self.state.text, privacy: .public)")
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
        waveCharacteristic = nil
        session.linkDropped()
    }

    func ensureConnected(timeout: TimeInterval = 12) async -> Bool {
        if state == .ready { return true }
        guard bluetoothReady else { return false }
        if peripheral == nil, let known = knownPeripheral() {
            connect(DiscoveredRing(id: known.identifier, name: known.name ?? BandDevice.fallbackName, rssi: 0, peripheral: known))
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
        guard let stored = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
              let uuid = UUID(uuidString: stored) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    func releaseIfIdle() {
        guard !keepAliveEnabled, !screenIsOpen, !healthIsOpen, !holdsLinkForWorkout else { return }
        idleDropTask?.cancel()
        idleDropTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WearableKeepAlive.idleGraceSeconds))
            while !Task.isCancelled, self?.isWorking == true {
                try? await Task.sleep(for: .seconds(5))
            }
            guard let self, !Task.isCancelled, !self.keepAliveEnabled, !self.screenIsOpen,
                  !self.healthIsOpen, !self.holdsLinkForWorkout else { return }
            JcLog.devices.notice("band: idle after on-demand use; dropping the link")
            self.disconnect()
        }
    }

    private var isWorking: Bool {
        setupTask != nil || session.transport.isBusy || session.measuring != nil || sync.isSyncing
    }

    /// Forgets the band: drops the link and every local trace of it but its history.
    func forget() async {
        if let band = connected?.id ?? peripheral?.identifier {
            forgottenIDs.insert(band)
            discovered.removeAll { $0.id == band }
        }
        disconnect()
        session.forgetIdentity()
        if let device = exposedDevice { DeviceRegistry.shared.remove(deviceID: device.deviceID) }
        exposedDevice = nil
        WearableIdentity.forget(WearableKeepAlive.band)
        UserDefaults.standard.removeObject(forKey: Self.lastPeripheralKey)
    }

    private func beginDiscovery(_ p: CBPeripheral) {
        discoveryAttempts += 1
        state = .discovering
        p.delegate = self
        p.discoverServices([BandGATT.service, BandGATT.waveService])
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
                self.state = .failed("the band never answered — toggle Bluetooth, or unbind it in its own app")
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
            // The handshake is also the proof that this is a Veepoo band. Judged by this setup
            // alone: the session still holds the last band's handshake for the status screen.
            let known = UserDefaults.standard.string(forKey: Self.lastPeripheralKey) == p.identifier.uuidString
            var passed = false
            for attempt in 0..<(known ? 2 : 1) {
                do {
                    try await self.session.runSetup(profile: BandProfile.current())
                    passed = true
                    break
                } catch {
                    JcLog.devices.notice("band: setup attempt \(attempt + 1) failed — \(error.localizedDescription, privacy: .public)")
                    guard self.state == .ready else { return }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            guard passed else {
                self.setupTask = nil
                self.disconnect()
                self.state = .failed(known ? "The band didn't answer — bring it closer and try again" : "Not a supported band")
                return
            }
            // An app sport nobody is tracking (the app was closed mid-workout) is ended, so the
            // band isn't left recording and the next start isn't refused as busy.
            if !self.holdsLinkForWorkout { _ = await self.session.sport(.stop) }
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastPeripheralKey)
            self.publishToRegistry()
            self.setupTask = nil
            guard self.state == .ready else { return }
            // Only while someone is looking: a skill or a workout that connected on demand
            // would otherwise queue behind three days of history reads.
            if self.sync.isStale, self.screenIsOpen || self.healthIsOpen, !self.holdsLinkForWorkout {
                await self.sync.sync()
            }
            self.releaseIfIdle()
        }
    }

    // MARK: Registry

    private func publishToRegistry() {
        guard state == .ready else { return }
        if exposedDevice == nil { exposedDevice = BandDevice(backend: self) }
        refreshRegistryMembership()
    }

    func refreshRegistryMembership() {
        guard let device = exposedDevice else { return }
        DeviceRegistry.shared.syncMembership(of: device, identity: WearableKeepAlive.band, model: BandDevice.model)
    }

    /// Registers the catalogue with no live link; `invoke` reconnects on demand.
    func publishRemembered() {
        if exposedDevice == nil {
            guard WearableIdentity.remembered(WearableKeepAlive.band) != nil else { return }
            exposedDevice = BandDevice(backend: self)
        }
        refreshRegistryMembership()
    }

    // MARK: Foreground / background

    func enterBackground() {
        isBackgrounded = true
        stopScan()
        guard !holdsLinkForWorkout else { return }
        guard !BridgeClient.shared.enabled || !keepAliveEnabled else { return }
        if connected != nil {
            wasConnectedBeforeBackground = connected
            disconnect()
        }
    }

    func enterForeground() {
        isBackgrounded = false
        if let band = wasConnectedBeforeBackground {
            wasConnectedBeforeBackground = nil
            if keepAliveEnabled || screenIsOpen || healthIsOpen || holdsLinkForWorkout { connect(band) }
        } else if state == .ready, sync.isStale, !holdsLinkForWorkout {
            Task { await self.sync.sync() }
        }
    }
}

// MARK: - BandLink

extension BandManager: BandLink {
    var isLinkReady: Bool { state == .ready && peripheral != nil && writeCharacteristic != nil }

    func send(_ frame: [UInt8]) {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(frame), for: characteristic, type: type)
    }
}

// MARK: - CBCentralManagerDelegate

extension BandManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let on = c.state == .poweredOn
        Task { @MainActor in
            self.bluetoothReady = on
            if on {
                self.surfaceKnownPeripherals()
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
            self.connected = DiscoveredRing(id: p.identifier, name: p.name ?? BandDevice.fallbackName, rssi: 0, peripheral: p)
            self.discoveryAttempts = 0
            if p.state == .connected { self.beginDiscovery(p) } else { self.state = .connecting }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let maker = (ad[CBAdvertisementDataManufacturerDataKey] as? Data).flatMap { data -> UInt16? in
            data.count >= 2 ? UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8 : nil
        }
        let rssi = RSSI.intValue
        Task { @MainActor in
            guard Self.isCandidate(name: name, manufacturer: maker) else { return }
            if let i = self.discovered.firstIndex(where: { $0.id == p.identifier }) {
                self.discovered[i].rssi = rssi
                if !name.isEmpty { self.discovered[i].name = name }
            } else {
                self.discovered.append(DiscoveredRing(id: p.identifier, name: name.isEmpty ? BandDevice.fallbackName : name,
                                                      rssi: rssi, peripheral: p))
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in self.beginDiscovery(p) }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in self.state = .failed(error?.localizedDescription ?? "could not connect") }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "no error"
        Task { @MainActor in
            guard p === self.peripheral else { return }
            self.setupTask?.cancel()
            self.setupTask = nil
            self.resetLink()
            guard self.keepAliveEnabled || self.screenIsOpen || self.healthIsOpen || self.holdsLinkForWorkout else {
                JcLog.devices.notice("band: link dropped (\(reason, privacy: .public)); keep-alive off")
                self.connected = nil
                self.state = .idle
                return
            }
            JcLog.devices.notice("band: link dropped (\(reason, privacy: .public)); reconnecting")
            self.discoveryAttempts = 0
            self.state = .connecting
            self.central.connect(p)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BandManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let wave = p.services?.first(where: { $0.uuid == BandGATT.waveService }) {
                p.discoverCharacteristics([BandGATT.wave], for: wave)
            }
            guard let service = p.services?.first(where: { $0.uuid == BandGATT.service }) else {
                self.state = .failed("Band service not found")
                return
            }
            p.discoverCharacteristics([BandGATT.write, BandGATT.notify], for: service)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            let characteristics = service.characteristics ?? []
            if service.uuid == BandGATT.waveService {
                self.waveCharacteristic = characteristics.first { $0.uuid == BandGATT.wave }
                return
            }
            if let write = characteristics.first(where: { $0.uuid == BandGATT.write }) { self.writeCharacteristic = write }
            for characteristic in characteristics where characteristic.uuid == BandGATT.notify {
                if !characteristic.isNotifying { p.setNotifyValue(true, for: characteristic) }
            }
            if self.writeCharacteristic != nil,
               characteristics.contains(where: { $0.uuid == BandGATT.notify && $0.isNotifying }) {
                self.becomeReady(p)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                JcLog.devices.error("band: notify failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard characteristic.uuid == BandGATT.notify, characteristic.isNotifying else { return }
            if self.writeCharacteristic != nil { self.becomeReady(p) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let frame = [UInt8](data)
        if characteristic.uuid == BandGATT.wave {
            Task { @MainActor in self.session.ecgWave(frame) }
            return
        }
        guard characteristic.uuid == BandGATT.notify else { return }
        Task { @MainActor in self.session.transport.deliver(frame) }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        Task { @MainActor in JcLog.devices.notice("band: write failed: \(error.localizedDescription, privacy: .public)") }
    }
}
