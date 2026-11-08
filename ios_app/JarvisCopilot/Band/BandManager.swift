import Combine
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
final class BandManager: BLEWearableManager {

    let session = BandSession()
    /// The band's measuring, managed by the band or by the phone.
    let measureScheduler = BandMeasureScheduler()
    /// The band's battery level over time and what it was doing (the Battery page).
    let battery = BandBatteryLog()
    private(set) lazy var sync = BandSync(session: session, store: { [weak self] in self?.store })
    /// Changed days go to Jarvis Health at most every 30 minutes, at once while a screen shows them.
    private(set) lazy var uploads = DayUploadThrottle { [weak self] keys in
        guard let self else { return true }
        WidgetDataHub.shared.refreshSoon()
        return await BandHealthPush.push(keys, manager: self)
    }

    /// Days the sync changed — Jarvis Health pushes them.
    var onDaysChanged: ((Set<String>) -> Void)?
    /// Whether a workout on the band is under way (the workout controller answers).
    var workoutHold: (() -> Bool)?
    /// The workout controller, for `band_workout`.
    weak var workouts: RingWorkoutController?
    var workoutRunning: Bool { workoutHold?() ?? false }
    override var holdsLinkForWorkout: Bool { workoutRunning }

    override var keepAliveEnabled: Bool { WearableKeepAlive.isOn(WearableKeepAlive.band) }

    var deviceID: String? {
        WearableIdentity.remembered(WearableKeepAlive.band)
            ?? connected?.id.uuidString
            ?? UserDefaults.standard.string(forKey: Self.lastPeripheralKey)
    }

    var store: RingHistoryStore? { deviceID.map { RingHistoryStore.shared(for: $0) } }
    var exposedDeviceID: String? { exposedDevice?.deviceID }

    /// True while the band's screen is open: the link stays up whatever Keep Alive says.
    override var screenIsOpen: Bool {
        didSet { if screenIsOpen, !oldValue { uploads.flush() } }
    }

    /// True while the Health tab is open: held so a refresh or a spot check needs no connect.
    override var healthIsOpen: Bool {
        didSet { if healthIsOpen, !oldValue { uploads.flush() } }
    }

    private var writeCharacteristic: CBCharacteristic?
    /// The ECG waveform channel, subscribed while an ECG runs.
    private var waveCharacteristic: CBCharacteristic?
    private var exposedDevice: BandDevice?
    /// Backgrounded mid-reading: the link drops once the reading ends.
    private var backgroundDropTask: Task<Void, Never>?
    private var periodicSync: Task<Void, Never>?
    private var batteryWatch: Set<AnyCancellable> = []
    private var batteryTicker: Task<Void, Never>?
    private var lastBatteryRead = Date.distantPast
    static let lastPeripheralKey = "lastConnectedBandPeripheral"

    init() {
        super.init(logName: "band", restoreIdentifier: "com.jarviscopilot.jarviscopilotMobileAndIOS.bandCentral",
                   lastPeripheralKey: Self.lastPeripheralKey, fallbackName: BandDevice.fallbackName,
                   primaryService: BandGATT.service, servicesToDiscover: [BandGATT.service, BandGATT.waveService],
                   discoveryFailure: "the band never answered — toggle Bluetooth, or unbind it in its own app")
        session.attach(self)
        measureScheduler.attach(self)
        measureScheduler.noteControlIfUnlogged(in: battery)
        onDaysChanged = { [weak self] keys in
            guard let self else { return }
            self.uploads.changed(keys, urgent: self.screenIsOpen || self.healthIsOpen)
        }
        sync.onDaysChanged = { [weak self] keys in self?.onDaysChanged?(keys) }
        startPeriodicSync()
        watchBattery()
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
            if let qtc = r.qtcMs, extra["qtc_ms"] == nil { extra["qtc_ms"] = Double(qtc) }
            // The whole reading, for its report page — with how far it got when it stopped early.
            if let deviceID, r.ecg != nil || !session.ecgSamples.isEmpty {
                var report = BandEcgReport(date: r.date, diagnosis: r.ecg, heartRates: session.ecgHeartRates,
                                           samples: BandEcgSignal.withoutLeadIn(session.ecgSamples),
                                           sampleRate: session.ecgSampleRate)
                report.qtcs = session.ecgQtcs
                report.hrvs = session.ecgHrvs
                report.progress = r.status == .done ? 100 : r.progress
                report.stopped = r.status == .done ? nil : r.failure
                BandEcgStore.save(report, deviceID: deviceID)
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

    override func matchesAdvertisement(name: String, services: [CBUUID], manufacturer: UInt16?) -> Bool {
        Self.isCandidate(name: name, manufacturer: manufacturer)
    }

    // MARK: Link

    override func resetLink() {
        writeCharacteristic = nil
        waveCharacteristic = nil
        session.linkDropped()
    }

    /// Syncs on the interval picked in the band's settings: when one is due it connects to the
    /// band (if it isn't already), syncs, and lets the link go again. A band it can't reach is
    /// tried once more, then left until the next interval. Wakes when the next sync is due — and
    /// at least every 15 minutes, so a new interval takes hold.
    private func startPeriodicSync() {
        periodicSync = Task { [weak self] in
            while !Task.isCancelled {
                let due = self?.sync.nextDue?.timeIntervalSinceNow ?? 15 * 60
                try? await Task.sleep(for: .seconds(min(15 * 60, max(60, due))))
                guard let self, !Task.isCancelled else { return }
                guard self.sync.isDue, self.peripheral != nil || self.knownPeripheral() != nil,
                      !self.isWorking, !self.holdsLinkForWorkout else { continue }
                await self.periodicSyncNow()
            }
        }
    }

    /// One due sync: two tries at reaching the band, then it gives up until the next interval.
    private func periodicSyncNow() async {
        sync.attempted()
        for attempt in 1...2 {
            if attempt > 1 { try? await Task.sleep(for: .seconds(5)) }
            guard !holdsLinkForWorkout else { return }
            if await ensureConnected(timeout: 12) {
                await waitForSetup(timeout: 10)
                // Setup syncs by itself while a screen is open; otherwise it's done here.
                if sync.isStale || !sync.lastReached { await sync.sync() }
                if sync.lastReached && !sync.isStale {
                    releaseIfIdle()
                    return
                }
            }
            JcLog.devices.notice("band: periodic sync couldn't reach the band (try \(attempt) of 2)")
        }
        releaseIfIdle()
    }

    /// Feeds the battery log each level the band reports and what it's doing — linked, a reading,
    /// a workout, its every-minute sensing, a sync, a find — and, while linked, reads the level
    /// every 10 minutes.
    private func watchBattery() {
        let log = battery
        session.$battery.compactMap { $0 }
            .sink { [weak self] level in
                self?.lastBatteryRead = Date()
                log.record(percent: level.percent, charging: level.charging)
                if !level.charging { self?.checkDrain() }
            }
            .store(in: &batteryWatch)
        $state.map { $0 == .ready }.removeDuplicates()
            .sink { log.set(.linked, $0) }
            .store(in: &batteryWatch)
        session.$measuring.removeDuplicates()
            .sink { type in
                log.set(.reading, false)
                if let type { log.set(.reading, true, detail: type.name) }
            }
            .store(in: &batteryWatch)
        // Unknown while unlinked: the band keeps sensing (or not) as it was told.
        session.$settings.compactMap { $0?.isOn("auto_ppg") }.removeDuplicates()
            .sink { log.set(.sensing, $0) }
            .store(in: &batteryWatch)
        session.$finding.removeDuplicates().filter { $0 }
            .sink { _ in log.note(.find) }
            .store(in: &batteryWatch)
        sync.$isSyncing.removeDuplicates().dropFirst().filter { !$0 }
            .sink { [weak self] _ in
                log.note(.sync)
                guard let self, self.isLinkReady else { return }
                Task { await self.session.refreshBattery() }
            }
            .store(in: &batteryWatch)
        batteryTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                log.set(.workout, self.workoutRunning)
                guard self.isLinkReady, !self.isWorking,
                      Date().timeIntervalSince(self.lastBatteryRead) >= BandBatteryLog.readEvery else { continue }
                self.lastBatteryRead = Date()
                await self.session.refreshBattery()
            }
        }
    }

    /// Over `BandDrainAlert.threshold` points a day across the last day: one notification a day
    /// saying the likely cause (2026-11-06: four days at 23–29% went unnoticed).
    private func checkDrain() {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: BandDrainAlert.lastKey) as? Date,
           Date().timeIntervalSince(last) < BandDrainAlert.every { return }
        let autos = BandMeasurePlan.autoSwitches.filter { session.settings?.isOn($0) == true }
        guard let text = BandDrainAlert.message(battery.report(), control: measureScheduler.plan.control,
                                                autosOn: autos) else { return }
        defaults.set(Date(), forKey: BandDrainAlert.lastKey)
        Task { _ = try? await DefaultNotifier().post(LocalNotificationRequest(title: "Band battery draining fast", body: text)) }
    }

    override var isWorking: Bool {
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

    override func enterBackground() {
        isBackgrounded = true
        stopScan()
        guard !holdsLinkForWorkout else { return }
        guard !BridgeClient.shared.enabled || !keepAliveEnabled else { return }
        // Measuring managed by the phone: its schedule needs the band there in the background
        // (the link was dropped here, and nothing was measured until the app was opened again).
        guard measureScheduler.plan.control != .phone else { return }
        guard connected != nil else { return }
        // A reading under way finishes first: an ECG cut off loses the band's analysis (his
        // 21:54 run stopped at 83% when the app was switched away).
        backgroundDropTask?.cancel()
        backgroundDropTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.session.measuring != nil {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, self.isBackgrounded, !self.holdsLinkForWorkout,
                  let band = self.connected else { return }
            self.wasConnectedBeforeBackground = band
            self.disconnect()
        }
    }

    override func enterForeground() {
        backgroundDropTask?.cancel()
        backgroundDropTask = nil
        super.enterForeground()
    }

    override func foregroundWhileReady() {
        if sync.isStale, !holdsLinkForWorkout { Task { await self.sync.sync() } }
    }

    /// A band iOS already holds doesn't advertise; Bluetooth coming on lists it, no scan.
    override func bluetoothBecameReady() { surfaceKnownPeripherals() }
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
