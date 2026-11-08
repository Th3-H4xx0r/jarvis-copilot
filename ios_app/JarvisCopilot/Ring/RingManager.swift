import AudioToolbox
import CoreBluetooth
import Foundation
import UIKit

/// App-lifetime owner of the ring's Bluetooth link.
///
/// Follows `BottleManager`'s semantics — Keep Alive holds and restores the link, off means
/// connect on demand and drop after the grace period, bridge mode holds it in the
/// background — and hands every byte to `RingSession`, which owns the protocol.
@MainActor
final class RingManager: BLEWearableManager {

    let session = RingSession()
    private(set) lazy var sync: RingSync = {
        let sync = RingSync(session: session, store: { [weak self] in self?.store })
        sync.deviceIDForHealth = deviceID
        return sync
    }()
    /// On-demand readings, shared by the ring screen and the Health tab.
    private(set) lazy var measure = RingMeasureController(manager: self)

    override var keepAliveEnabled: Bool { WearableKeepAlive.isOn(WearableKeepAlive.ring) }

    /// The ring hides its MAC from iOS, so identity is the remembered id, else this install's
    /// CoreBluetooth identifier.
    /// Must stay stable while the ring is away. It used to fall back to the live connection
    /// alone, so a dropped link took the input actions with it — and with them the reason to
    /// hold the link open at all, which is why gestures died in the background.
    var deviceID: String? {
        WearableIdentity.remembered(WearableKeepAlive.ring)
            ?? connected?.id.uuidString
            ?? UserDefaults.standard.string(forKey: Self.lastPeripheralKey)
    }

    var store: RingHistoryStore? { deviceID.map { RingHistoryStore.shared(for: $0) } }
    /// What each tap, swipe or press on the ring runs.
    var inputs: RingInputStore? { deviceID.map { RingInputStore.shared(for: $0) } }
    private var commandWrite: CBCharacteristic?
    private var bigDataWrite: CBCharacteristic?
    private var pendingChunks: [Data] = []
    private var lastBackgroundDrain = Date.distantPast
    private static let lastPeripheralKey = "lastConnectedRingPeripheral"

    init() {
        super.init(logName: "ring", identity: WearableKeepAlive.ring, model: ColmiR12.model,
                   restoreIdentifier: "com.jarviscopilot.jarviscopilotMobileAndIOS.ringCentral",
                   lastPeripheralKey: Self.lastPeripheralKey, fallbackName: "Ring",
                   primaryService: RingProtocol.commandService,
                   servicesToDiscover: [RingProtocol.commandService, RingProtocol.bigDataService, RingProtocol.deviceInfoService],
                   discoveryFailure: "the ring never answered — unbind it in QRing, or toggle Bluetooth")
        session.attach(self)
        // Wires the session's push and measurement hooks before a restored link delivers any.
        _ = sync
        session.appIsActive = { UIApplication.shared.applicationState == .active }
        session.onFindPhone = { active in
            // The ring's "find my phone" gesture.
            if active { AudioServicesPlayAlertSound(SystemSoundID(1005)) }
        }
        session.onInput = { [weak self] input in self?.runAction(for: input) }
        session.maxBoundPresses = { [weak self] in self?.inputs?.maxBoundPresses ?? 1 }
        session.wantsShake = { [weak self] in self?.inputs?.usesShake ?? false }
        session.actionSummary = { [weak self] input in
            let action = self?.inputs?.action(for: input) ?? .none
            return action.isSet ? action.summary : nil
        }
        session.pressWindow = { [weak self] in self?.inputs?.pressWindow ?? 3.0 }
        watchInputBindings()
    }

    /// Some gestures have to be armed on the ring rather than merely read: the shake detector is
    /// a command. The store is per ring and only exists once the ring is known, so this is
    /// attached here and again on every connect rather than once at launch — the first version
    /// ran while `inputs` was still nil, and the detector was never armed at all.
    private func watchInputBindings() {
        guard let inputs else { return }
        inputs.onActionsChanged = { [weak self] in
            guard let self, let inputs = self.inputs else { return }
            Task { await self.session.setShakeDetector(inputs.usesShake && inputs.wantedMode == .jarvis) }
        }
    }

    // MARK: Link

    override func resetLink() {
        commandWrite = nil
        bigDataWrite = nil
        pendingChunks.removeAll()
        session.linkDropped()
    }

    /// The ring used last time, else one iOS already holds.
    override func knownPeripheral() -> CBPeripheral? {
        super.knownPeripheral() ?? central.retrieveConnectedPeripherals(withServices: [RingProtocol.commandService])
            .first { RingProtocol.isRingName($0.name ?? "") }
    }

    /// Off shows any peripheral advertising the ring's UART service, not just ring names.
    override func matchesAdvertisement(name: String, services: [CBUUID], manufacturer: UInt16?) -> Bool {
        RingProtocol.isRingName(name) || (!strictNameMatch && services.contains(RingProtocol.commandService))
    }

    override func belongsInList(_ p: CBPeripheral, isLastUsed: Bool) -> Bool {
        RingProtocol.isRingName(p.name ?? "") || isLastUsed
    }

    /// A tap or swipe on the ring: run whatever it is set to, and say so in the log.
    private func runAction(for input: RingInput) {
        let action = inputs?.action(for: input) ?? .none
        guard action.isSet else {
            session.log.note("Ring input: \(input.label)", "no action set")
            return
        }
        session.log.note("Ring input: \(input.label)", action.summary)
        let started = Date()
        Task { [weak self] in
            let outcome = await RingActionRunner.run(action)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            self?.session.log.note("Ran \(input.label)", "\(outcome) — \(ms)ms")
            self?.session.noteGestureRun(input, "\(action.summary) · \(ms)ms")
        }
    }

    override var isWorking: Bool {
        setupTask != nil || session.transport.isBusy || session.measurement?.isActive == true || sync.isSyncing
            || workouts?.isActive == true
    }

    private func becomeReady(_ p: CBPeripheral) {
        guard state != .ready else { return }
        markReady()
        adopt(p)
        if let id = deviceID {
            session.loadCache(deviceID: id)
            sync.deviceIDForHealth = id
        }
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            guard let self else { return }
            await self.session.runSetup()
            self.setupTask = nil
            guard self.state == .ready else { return }
            if let id = self.deviceID { self.session.saveCache(deviceID: id) }
            // Put the ring where the user asked — reporting to Jarvis, driving music, or off.
            self.watchInputBindings()
            await self.session.setInputMode(self.inputs?.wantedMode ?? .off)
            // Find out what this ring actually answers; its own flags under-report.
            await self.session.runProbe()
            self.sync.syncIfStale()
        }
    }

    // MARK: Registry

    override func makeExposedDevice() -> any WearableDevice { ColmiR12(manager: self) }

    /// The saved capabilities go in first: they decide which skills the ring lists.
    override func publishRemembered() {
        if exposedDevice != nil || WearableIdentity.remembered(identityKey) != nil, let id = deviceID {
            session.loadCache(deviceID: id)
            sync.deviceIDForHealth = id
        }
        super.publishRemembered()
    }

    // MARK: Foreground / background

    override func enterForeground() {
        session.noteAppBecameActive()
        // An open ring screen holds the link whatever Keep Alive says; its wear watch starts
        // again once the link is ready.
        super.enterForeground()
    }

    override func foregroundWhileReady() { sync.syncIfStale() }
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
