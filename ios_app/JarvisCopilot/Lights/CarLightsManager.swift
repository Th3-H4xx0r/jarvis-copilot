import Combine
import CoreBluetooth
import Foundation

/// The car's MELK LED controllers over Bluetooth: finds them, keeps a pending connection to every
/// paired one (iOS completes it the moment the car powers the lights), and sends each its frames
/// through its own paced queue. The controllers never report their state, so what was last sent is
/// kept here and is what everything shows.
@MainActor
final class CarLightsManager: NSObject, ObservableObject {
    static let shared = CarLightsManager()

    enum Link: Equatable { case disconnected, connecting, ready }

    struct Found: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    @Published private(set) var controllers: [CarLightsController] = []
    @Published private(set) var states: [String: CarLightsState] = [:]
    @Published private(set) var links: [String: Link] = [:]
    @Published private(set) var found: [Found] = []
    @Published private(set) var bluetoothReady = false
    @Published private(set) var scanning = false

    private static let controllersKey = "jc.lights.controllers"
    private static let statesKey = "jc.lights.states"
    private static let pendingKey = "jc.lights.pending"

    private let defaults: UserDefaults
    private var central: CBCentralManager?
    private var peripherals: [String: CBPeripheral] = [:]
    private var characteristics: [String: CBCharacteristic] = [:]
    private var queues: [String: MelkWriteQueue] = [:]
    private var draining: Set<String> = []
    /// Changes made while a controller was away, kept across launches and sent once it's back:
    /// "state" (power/mode/colour/brightness…), "pin", "pixels", "timer0", "timer1".
    private var pending: [String: Set<String>] = [:]
    private var reading: Set<String> = []
    private var retryDelay: [String: TimeInterval] = [:]
    private var readWaiters: [String: [(token: UUID, continuation: CheckedContinuation<Data?, Never>)]] = [:]
    private var scanStop: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        if let data = defaults.data(forKey: Self.controllersKey),
           let saved = try? JSONDecoder().decode([CarLightsController].self, from: data) { controllers = saved }
        if let data = defaults.data(forKey: Self.statesKey),
           let saved = try? JSONDecoder().decode([String: CarLightsState].self, from: data) { states = saved }
        if let saved = defaults.dictionary(forKey: Self.pendingKey) as? [String: [String]] {
            pending = saved.mapValues(Set.init)
        }
    }

    /// Bring up Bluetooth and the pending connections. Idempotent; nothing happens until a
    /// controller is paired or a scan is asked for, so the permission prompt never comes early.
    func start() {
        guard central == nil, !controllers.isEmpty else { return }
        makeCentral()
    }

    private func makeCentral() {
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.jarviscopilot.jarviscopilotMobileAndIOS.carLightsCentral",
        ])
    }

    func state(for id: String) -> CarLightsState { states[id] ?? CarLightsState() }

    #if DEBUG
    /// Tests: pretend a controller finished its handshake (no Bluetooth in the simulator).
    func markReadyForTesting(_ id: String) { links[id] = .ready }
    #endif
    func link(for id: String) -> Link { links[id] ?? .disconnected }
    var anyReady: Bool { controllers.contains { link(for: $0.id) == .ready } }

    // MARK: Pairing

    func scan(seconds: TimeInterval = 10) {
        if central == nil { makeCentral() }
        found = []
        scanning = true
        if bluetoothReady { central?.scanForPeripherals(withServices: nil, options: nil) }
        scanStop?.cancel()
        scanStop = Task { [weak self] in
            // A newer scan cancels this timer: it must not stop that scan.
            guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
            self?.stopScan()
        }
    }

    func stopScan() {
        scanStop?.cancel()
        central?.stopScan()
        scanning = false
    }

    /// Remember a controller found by a scan and connect to it.
    func pair(_ item: Found) {
        let id = item.id.uuidString
        guard !controllers.contains(where: { $0.id == id }) else { return }
        let name = controllers.isEmpty ? "Car lights" : "Car lights \(controllers.count + 1)"
        controllers.append(CarLightsController(id: id, advertisedName: item.name, name: name))
        found.removeAll { $0.id == item.id }
        save()
        connectRemembered()
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = controllers.firstIndex(where: { $0.id == id }), !trimmed.isEmpty else { return }
        controllers[i].name = String(trimmed.prefix(40))
        save()
    }

    func forget(_ id: String) {
        if let p = peripherals[id] { central?.cancelPeripheralConnection(p) }
        controllers.removeAll { $0.id == id }
        states[id] = nil
        pending[id] = nil
        links[id] = nil
        peripherals[id] = nil
        characteristics[id] = nil
        queues[id] = nil
        save()
    }

    private func connectRemembered() {
        guard let central, bluetoothReady else { return }
        let ids = controllers.compactMap { UUID(uuidString: $0.id) }
        for p in central.retrievePeripherals(withIdentifiers: ids) {
            let id = p.identifier.uuidString
            peripherals[id] = p
            p.delegate = self
            if p.state == .connected {
                // Restored still connected (the app was relaunched mid-drive): finish the setup.
                guard link(for: id) == .disconnected else { continue }
                links[id] = .connecting
                p.discoverServices([CBUUID(string: Melk.service)])
                continue
            }
            guard link(for: id) != .connecting else { continue }
            links[id] = .connecting
            central.connect(p, options: nil)   // never times out: completes when the lights power up
        }
    }

    /// After a failed connect, try again later — 2 s, doubling to a minute — never in a hot loop.
    private func retryLater(_ id: String) {
        let delay = min(60, (retryDelay[id] ?? 1) * 2)
        retryDelay[id] = delay
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.connectRemembered()
        }
    }

    // MARK: Sending

    /// Change one controller, or every paired one (`ids` nil). The state is kept either way; a
    /// controller that's away gets it when it comes back.
    func apply(_ change: CarLightsChange, to ids: [String]? = nil) {
        // A new colour, effect, scene, mic or power ends phone-driven music, or its next beat would undo it.
        if change.changesWhatShows, CarLightsMusic.shared.listening { CarLightsMusic.shared.stopPhoneMic() }
        for id in ids ?? controllers.map(\.id) where controllers.contains(where: { $0.id == id }) {
            let (next, frames) = change.apply(to: state(for: id))
            states[id] = next
            if link(for: id) == .ready {
                frames.forEach { queues[id, default: MelkWriteQueue()].push($0.0, kind: $0.1) }
                drain(id)
            } else {
                pending[id, default: []].insert(change.pendingKey)
            }
        }
        saveStates()
    }

    /// A phone-music colour: sent, not kept (it changes ten times a second) — and only to lights
    /// that are on and in music mode.
    func sendMusicColor(_ color: MelkColor, to ids: [String]? = nil) {
        for id in ids ?? controllers.map(\.id) where link(for: id) == .ready {
            let s = state(for: id)
            guard s.on, s.mode == .phoneMusic else { continue }
            queues[id, default: MelkWriteQueue()].push(Melk.musicColor(color), kind: .color)
            drain(id)
        }
    }

    func setMode(_ mode: CarLightsState.Mode, for ids: [String]? = nil) {
        for id in ids ?? controllers.map(\.id) { states[id, default: CarLightsState()].mode = mode }
        saveStates()
    }

    /// Phone music stopped: back to the colour the lights had (the last beat may have been black).
    func endPhoneMusic(for ids: [String]?) {
        for id in ids ?? controllers.map(\.id) where state(for: id).mode == .phoneMusic {
            apply(.color(state(for: id).color), to: [id])
        }
    }

    private var writeType: (CBCharacteristic) -> CBCharacteristicWriteType {
        { $0.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse }
    }

    private func drain(_ id: String) {
        guard !draining.contains(id) else { return }
        draining.insert(id)
        Task { [weak self] in
            while let self, var queue = self.queues[id], !queue.isEmpty {
                guard self.link(for: id) == .ready, let p = self.peripherals[id], let c = self.characteristics[id] else {
                    self.queues[id] = nil
                    break
                }
                let now = Date()
                if let frame = queue.next(now: now) {
                    self.queues[id] = queue
                    let type = self.writeType(c)
                    // Wait for the radio's buffer rather than overrun it (a frame is 9 bytes; 50 ms is plenty).
                    var waited = 0
                    while type == .withoutResponse, !p.canSendWriteWithoutResponse, waited < 10 {
                        try? await Task.sleep(for: .milliseconds(5))
                        waited += 1
                    }
                    p.writeValue(frame, for: c, type: type)
                    try? await Task.sleep(for: .milliseconds(6))   // the app spaces writes ≥ 5 ms
                } else if let wait = queue.wait(now: now) {
                    try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 1))
                } else {
                    break
                }
            }
            self?.draining.remove(id)
        }
    }

    /// What changed while a controller was away, sent once it's back: what it shows, plus any
    /// wiring or timer change.
    private func replay(_ id: String, _ keys: Set<String>) {
        let s = state(for: id)
        var changes: [CarLightsChange] = []
        if keys.contains("pin") { changes.append(.pinOrder(s.pinOrder)) }
        if keys.contains("pixels"), let n = s.pixelCount { changes.append(.pixelCount(n)) }
        for t in s.timers where keys.contains("timer\(t.slot.rawValue)") { changes.append(.timer(t)) }
        guard keys.contains("state") else {
            for change in changes {
                change.apply(to: s).1.forEach { queues[id, default: MelkWriteQueue()].push($0.0, kind: $0.1) }
            }
            drain(id)
            return
        }
        if !s.on {
            changes = [.power(false)]
        } else {
            changes.append(.power(true))
            switch s.mode {
            case .color, .phoneMusic: changes.append(.color(s.color))
            case .white: changes.append(.white(s.whiteLevel))
            case .temperature: changes.append(.temperature(coldPercent: s.coldPercent))
            case .effect: changes += [.effect(s.effect), .speed(s.speed)]
            case .scene: changes.append(.scene(s.scene))
            case .deviceMic: changes += [.micEffect(s.micEffect), .micSensitivity(s.micSensitivity)]
            }
            changes.append(.brightness(s.shownBrightness))
        }
        for change in changes {
            change.apply(to: s).1.forEach { queues[id, default: MelkWriteQueue()].push($0.0, kind: $0.1) }
        }
        drain(id)
    }

    // MARK: Timers (the only thing that reads back)

    /// Ask a controller for both timers (query, then read FFF3), then resync its clock.
    func readTimers(_ id: String) async -> [MelkTimer]? {
        guard link(for: id) == .ready, let p = peripherals[id], let c = characteristics[id],
              !reading.contains(id) else { return nil }
        reading.insert(id)
        defer { reading.remove(id) }
        var out: [MelkTimer] = []
        for slot in [MelkTimer.Slot.on, .off] {
            p.writeValue(Melk.timerQuery(slot), for: c, type: writeType(c))
            try? await Task.sleep(for: .seconds(1))   // the app waits a second for the answer
            guard let data = await read(id), let timer = Melk.parseTimer(data), timer.slot == slot else { return nil }
            out.append(timer)
            try? await Task.sleep(for: .seconds(1))   // and a second between steps
        }
        queues[id, default: MelkWriteQueue()].push(Melk.timeSync(), kind: .other)
        drain(id)
        states[id, default: CarLightsState()].timers = out
        saveStates()
        return out
    }

    private func read(_ id: String, timeout: TimeInterval = 3) async -> Data? {
        guard let p = peripherals[id], let c = characteristics[id] else { return nil }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            readWaiters[id, default: []].append((token, continuation))
            p.readValue(for: c)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.timeOut(id, token)
            }
        }
    }

    /// An answer goes to every read waiting on that controller.
    private func finishReads(_ id: String, _ data: Data?) {
        let waiters = readWaiters[id] ?? []
        readWaiters[id] = nil
        waiters.forEach { $0.continuation.resume(returning: data) }
    }

    /// Only the read that set this timer gives up.
    private func timeOut(_ id: String, _ token: UUID) {
        guard let i = readWaiters[id]?.firstIndex(where: { $0.token == token }) else { return }
        let waiter = readWaiters[id]!.remove(at: i)
        waiter.continuation.resume(returning: nil)
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(controllers) { defaults.set(data, forKey: Self.controllersKey) }
        saveStates()
    }

    private func saveStates() {
        if let data = try? JSONEncoder().encode(states) { defaults.set(data, forKey: Self.statesKey) }
        defaults.set(pending.mapValues { Array($0) }, forKey: Self.pendingKey)
    }

    private func linkDropped(_ id: String) {
        links[id] = .disconnected
        characteristics[id] = nil
        queues[id] = nil
        finishReads(id, nil)
    }
}

extension CarLightsManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let on = c.state == .poweredOn
        Task { @MainActor in
            self.bluetoothReady = on
            if on {
                self.connectRemembered()
                if self.scanning { c.scanForPeripherals(withServices: nil, options: nil) }
            } else {
                self.controllers.forEach { self.linkDropped($0.id) }
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            for p in restored {
                self.peripherals[p.identifier.uuidString] = p
                p.delegate = self
            }
            // Ones still connected finish their setup once Bluetooth reports on (connectRemembered).
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        // The advertised name: `peripheral.name` can be a stale cached one.
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let rssi = RSSI.intValue
        Task { @MainActor in
            guard Melk.isController(name: name),
                  !self.controllers.contains(where: { $0.id == p.identifier.uuidString }) else { return }
            if let i = self.found.firstIndex(where: { $0.id == p.identifier }) {
                self.found[i].rssi = rssi
            } else {
                self.found.append(Found(id: p.identifier, name: name, rssi: rssi))
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            p.delegate = self
            p.discoverServices([CBUUID(string: Melk.service)])
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.linkDropped(p.identifier.uuidString)
            self.retryLater(p.identifier.uuidString)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.linkDropped(p.identifier.uuidString)
            // Car off → the lights lose power: wait for them to come back.
            self.connectRemembered()
        }
    }
}

extension CarLightsManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil, let service = p.services?.first(where: { $0.uuid == CBUUID(string: Melk.service) }) else {
                JcLog.devices.notice("lights: no FFF0 service on \(p.identifier.uuidString, privacy: .public)")
                // Drop the link: the disconnect callback sets up a fresh pending connection.
                self.central?.cancelPeripheralConnection(p)
                return
            }
            p.discoverCharacteristics([CBUUID(string: Melk.characteristic)], for: service)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil,
                  let c = service.characteristics?.first(where: { $0.uuid == CBUUID(string: Melk.characteristic) }) else {
                self.central?.cancelPeripheralConnection(p)
                return
            }
            let id = p.identifier.uuidString
            self.characteristics[id] = c
            // The app's only handshake: read FFF3 until it answers (every 500 ms, up to 5 s), then the
            // time. No answer → drop the link; the disconnect sets up a fresh pending connection.
            var answered = false
            for _ in 0..<10 where !answered {
                answered = await self.read(id, timeout: 0.5) != nil
            }
            guard answered else {
                self.central?.cancelPeripheralConnection(p)
                return
            }
            self.links[id] = .ready
            self.retryDelay[id] = nil
            self.queues[id, default: MelkWriteQueue()].push(Melk.timeSync(), kind: .other)
            if let keys = self.pending.removeValue(forKey: id) {
                self.saveStates()
                self.replay(id, keys)
            } else {
                self.drain(id)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        Task { @MainActor in self.finishReads(p.identifier.uuidString, error == nil ? value : nil) }
    }
}
