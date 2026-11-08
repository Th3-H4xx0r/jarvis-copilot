import Foundation
import CoreBluetooth

/// The Etekcity ESF551 on the shared link. The scale sleeps between weighings and some firmware
/// revisions change their address, so nothing holds its link: the next weighing wakes it and
/// the scan finds it again.
@MainActor
final class ScaleManager: BLEWearableManager {
    @Published private(set) var latestObservation: ScaleObservation?

    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var lastStable: ScaleObservation?
    private var frameAccumulator = VsV2FrameAccumulator()
    private var nextSequence: UInt8 = 0

    init() {
        super.init(logName: "scale", identity: WearableKeepAlive.scale, model: Esf551Scale.model,
                   restoreIdentifier: "com.jarviscopilot.jarviscopilotMobileAndIOS.scaleCentral",
                   lastPeripheralKey: "lastESF551PeripheralIdentifier", fallbackName: "ESF551",
                   primaryService: ScaleProtocol.primaryService,
                   servicesToDiscover: [ScaleProtocol.primaryService, ScaleProtocol.alternateService],
                   discoveryFailure: "the scale never answered — step on it to wake it, then try again")
    }

    // MARK: Link

    /// Only devices Jarvis can identify as this scale, whatever the scanner filter says.
    override func matchesAdvertisement(name: String, services: [CBUUID], manufacturer: UInt16?) -> Bool {
        services.contains(ScaleProtocol.primaryService) || services.contains(ScaleProtocol.alternateService)
            || Self.isScaleName(name)
    }

    /// A remembered identifier alone isn't trusted: older builds saved unrelated peripherals.
    override func belongsInList(_ p: CBPeripheral, isLastUsed: Bool) -> Bool { Self.isScaleName(p.name ?? "") }

    /// Some ESF551 firmware revisions rotate their advertised identity: one scale, one card.
    override func isSameDevice(_ listed: DiscoveredWearable, as p: CBPeripheral, name: String) -> Bool {
        listed.id == p.identifier || (!name.isEmpty && listed.name.caseInsensitiveCompare(name) == .orderedSame)
    }

    private static func isScaleName(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.contains("esf551") || name.contains("esf-551") || name.contains("etekcity")
            || name.contains("smart fitness scale")
    }

    override func connect(_ device: DiscoveredWearable) {
        resetLink()
        super.connect(device)
    }

    override func resetLink() {
        notifyCharacteristic = nil
        writeCharacteristic = nil
        latestObservation = nil
        lastStable = nil
        frameAccumulator.reset()
    }

    override func makeExposedDevice() -> any WearableDevice { Esf551Scale(manager: self) }

    // MARK: Readings

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
        // Into Jarvis Health at once, so the Health tab's weight is this one.
        Task { await ScaleUploader.flush() }
        AppleHealthSync.shared.syncSoon()
    }

    /// The stock app's opening move after subscribing: the scale timestamps a stable weighing
    /// with it and starts reporting live.
    private func sendTimeSync() {
        guard let peripheral, let writeCharacteristic else {
            JcLog.devices.error("scale time sync skipped: no command characteristic")
            return
        }
        let frame = ScaleProtocol.makeTimeSyncFrame(sequence: nextSequence)
        nextSequence &+= 1
        let type: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(frame), for: writeCharacteristic, type: type)
    }
}

extension ScaleManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for service in peripheral.services ?? []
            where service.uuid == ScaleProtocol.primaryService || service.uuid == ScaleProtocol.alternateService {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard let characteristics = service.characteristics else { return }
            // The ESF551 streams on FFF1 and takes commands on FFF2 — the reverse of the generic
            // SDK constant names.
            let stream = characteristics.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
                ?? characteristics.first { $0.uuid == ScaleProtocol.primaryWrite || $0.uuid == ScaleProtocol.alternateWrite }
            let command = characteristics.first { $0.uuid == ScaleProtocol.primaryNotify || $0.uuid == ScaleProtocol.alternateNotify }
            guard let stream else { return }
            notifyCharacteristic = stream
            writeCharacteristic = command
            guard stream.properties.contains(.notify) || stream.properties.contains(.indicate) else {
                JcLog.devices.error("scale stream \(stream.uuid) has no notify/indicate property")
                return
            }
            peripheral.setNotifyValue(true, for: stream)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard error == nil, characteristic.isNotifying else { return }
            markReady()
            adopt(peripheral)
            sendTimeSync()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        Task { @MainActor in
            for frame in frameAccumulator.append(Array(value)) {
                if let observation = ScaleProtocol.parse(frame) { record(observation) }
            }
        }
    }
}
