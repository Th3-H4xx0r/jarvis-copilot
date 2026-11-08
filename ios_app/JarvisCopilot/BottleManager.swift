import Foundation
import CoreBluetooth

struct TrafficEntry: Identifiable {
    enum Direction { case out, `in` }
    let id = UUID()
    let direction: Direction
    let hex: String
    let note: String
}

/// The VSITOO S1 Pro bottle on the shared wearable link: the link rules live in
/// `BLEWearableManager`; this adds the bottle's command queue, its replies and polling.
@MainActor
final class BottleManager: BLEWearableManager {
    @Published private(set) var status: BottleStatus?
    @Published private(set) var version: BottleVersion?
    @Published private(set) var macAddress: String?
    @Published private(set) var reminderSlots: [TimeSlot] = []
    @Published private(set) var autoCleanSlots: [TimeSlot] = []
    @Published private(set) var traffic: [TrafficEntry] = []

    /// Opt-in continuous polling, for watching traffic while reverse-engineering.
    /// Off by default: an idle connection should generate no traffic at all.
    @Published var liveUpdates = false { didSet { updatePolling() } }

    override var keepAliveEnabled: Bool { WearableKeepAlive.isOn(WearableKeepAlive.bottle) }
    override var isWorking: Bool { !queue.isEmpty || inFlight != nil }

    private var writeChar: CBCharacteristic?

    // The app serialises writes: one in flight, next goes out on reply or timeout.
    private var queue: [BottleCommand] = []
    private var inFlight: BottleCommand?
    private var timeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init() {
        // The restore identifier is what actually enables background CoreBluetooth.
        // `UIBackgroundModes: [bluetooth-central]` on its own does nothing — without
        // this, iOS suspends the app on background and drops the connection.
        super.init(logName: "bottle", identity: WearableKeepAlive.bottle, model: VsitooS1Pro.model,
                   restoreIdentifier: "com.jarviscopilot.jarviscopilotMobileAndIOS.central",
                   lastPeripheralKey: "lastConnectedPeripheral", fallbackName: "VSITOO-S1-Pro",
                   primaryService: BottleProtocol.service, servicesToDiscover: [BottleProtocol.service],
                   discoveryFailure: "the bottle never answered — move closer, or toggle Bluetooth")
    }

    // MARK: Link

    override func matchesAdvertisement(name: String, services: [CBUUID], manufacturer: UInt16?) -> Bool {
        BottleProtocol.namePrefixes.contains { name.hasPrefix($0) } || (!strictNameMatch && !name.isEmpty)
    }

    override func connect(_ device: DiscoveredWearable) {
        status = nil; version = nil; macAddress = nil
        reminderSlots = []; autoCleanSlots = []
        traffic.removeAll()
        super.connect(device)
    }

    override func resetLink() {
        pollTask?.cancel(); pollTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        inFlight = nil
        queue.removeAll()
        writeChar = nil
    }

    override func makeExposedDevice() -> any WearableDevice { VsitooS1Pro(manager: self) }

    // MARK: Sending

    func send(_ command: BottleCommand) { send([command]) }

    /// Each change is followed by a status read, so the screen shows what the bottle did.
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

    /// Bridge mode holds the link in the background. The link is nearly free on its own — the
    /// drain came from polling — so polling stops there and the server reads state on demand.
    override func enterBackground() {
        super.enterBackground()
        stopPolling()
    }

    override func enterForeground() {
        super.enterForeground()
        updatePolling()
    }
}

extension BottleManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == BottleProtocol.service }) else {
            Task { @MainActor in self.state = .failed("service A300 not found") }
            return
        }
        p.discoverCharacteristics(nil, for: svc)
    }

    nonisolated func peripheral(_ p: CBPeripheral,
                                didDiscoverCharacteristicsFor svc: CBService,
                                error: Error?) {
        let write  = svc.characteristics?.first { $0.uuid == BottleProtocol.write }
        let notify = svc.characteristics?.first { $0.uuid == BottleProtocol.notify }

        Task { @MainActor in
            self.writeChar = write
            guard write != nil, let n = notify else {
                self.state = .failed("A301/A303 characteristics missing")
                return
            }
            p.setNotifyValue(true, for: n)
            self.markReady()
            self.adopt(p)
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
            // A BLE wake is a reliable slice of background runtime: when the bridge
            // socket is down, spend it on the server's command queue.
            if self.isBackgrounded, BridgeClient.shared.enabled,
               BridgeClient.shared.status != .online {
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
