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
final class X5Manager: BLEWearableManager {
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
    /// Whether a workout on the X5 is under way (the workout controller answers).
    var workoutHold: (() -> Bool)?
    /// The workout controller, for `x5_workout`.
    weak var workouts: RingWorkoutController?
    /// A workout the X5 is driving holds the link, in the background too.
    var workoutRunning: Bool { workoutHold?() ?? false }

    override var keepAliveEnabled: Bool { WearableKeepAlive.isOn(WearableKeepAlive.x5ring) }
    override var holdsLinkForWorkout: Bool { workoutRunning }

    var deviceID: String? {
        WearableIdentity.remembered(WearableKeepAlive.x5ring)
            ?? connected?.id.uuidString
            ?? UserDefaults.standard.string(forKey: Self.lastPeripheralKey)
    }

    var store: RingHistoryStore? { deviceID.map { RingHistoryStore.shared(for: $0) } }
    var exposedDeviceID: String? { exposedDevice?.deviceID }
    var inputs: RingInputStore? { deviceID.map { RingInputStore.shared(for: $0) } }

    /// True while an X5 screen is open: the link stays up whatever Keep Alive says, and the
    /// live stream runs.
    override var screenIsOpen: Bool {
        didSet {
            guard oldValue != screenIsOpen else { return }
            session.holdsLive = screenIsOpen
            if state == .ready { Task { await session.setLive(screenIsOpen) } }
        }
    }

    private var writeCharacteristic: CBCharacteristic?
    private var exposedDevice: X5Ring?
    private var lastBackgroundDrain = Date.distantPast
    static let lastPeripheralKey = "lastConnectedX5Peripheral"

    init() {
        super.init(logName: "x5", restoreIdentifier: "com.jarviscopilot.jarviscopilotMobileAndIOS.x5Central",
                   lastPeripheralKey: Self.lastPeripheralKey, fallbackName: "X5 ring",
                   primaryService: X5Protocol.service, servicesToDiscover: [X5Protocol.service],
                   discoveryFailure: "the ring never answered — unbind it in its own app, or toggle Bluetooth")
        session.attach(self)
        _ = sync
        session.onGesture = { [weak self] gesture in self?.received(gesture) }
        onDaysChanged = { [weak self] keys in
            guard let self else { return }
            Task { await self.pushHealthDays(keys) }
            WidgetDataHub.shared.refreshSoon()
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

    /// Days to Jarvis Health, whichever ring leads.
    @discardableResult
    func pushHealthDays(_ keys: Set<String>) async -> Bool {
        await HealthDayPush.push(keys, deviceID: deviceID, store: store, source: WearableKind.x5ring.rawValue,
                                 battery: session.battery, logName: linkLogName)
    }

    override func matchesAdvertisement(name: String, services: [CBUUID], manufacturer: UInt16?) -> Bool {
        Self.isCandidate(name: name, hasService: services.contains(X5Protocol.service), strict: strictNameMatch)
    }

    /// Everything iOS hands back was found by its FFF0 service (or is the ring used last time).
    override func belongsInList(_ p: CBPeripheral, isLastUsed: Bool) -> Bool {
        isLastUsed || Self.isCandidate(name: p.name ?? "", hasService: true, strict: strictNameMatch)
    }

    /// The bathroom scale advertises FFF0 too; it has its own card.
    static func isScaleName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("esf551") || n.contains("esf-551") || n.contains("etekcity") || n.contains("scale")
    }


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

    // MARK: Link

    override func resetLink() {
        writeCharacteristic = nil
        session.linkDropped()
    }

    override func dropIdleLink() async {
        await session.setLive(false)
        disconnect()
    }

    override var isWorking: Bool {
        setupTask != nil || session.transport.isBusy || session.measurement?.isActive == true || sync.isSyncing
    }

    /// Forgets the ring: unbinds it (best effort), drops the link and every local trace of it
    /// but its history.
    func forget() async {
        if state == .ready { await session.unbind() }
        let id = deviceID
        forgetLink(identity: WearableKeepAlive.x5ring)
        if let device = exposedDevice { DeviceRegistry.shared.remove(deviceID: device.deviceID) }
        exposedDevice = nil
        if let id { X5Cursors(deviceID: id).reset() }
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

    override func enterBackground() {
        isBackgrounded = true
        stopScan()
        Task {
            // The firmware keeps streaming across a disconnect: stop it before letting go.
            if self.session.liveOn, !self.holdsLinkForWorkout { await self.session.setLive(false) }
            self.releaseLinkForBackground()
        }
    }

    override func foregroundWhileReady() {
        if screenIsOpen { Task { await self.session.setLive(true) } }
        if sync.isStale { Task { await self.sync.sync() } }
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
