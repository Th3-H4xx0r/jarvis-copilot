import Foundation
import Combine
import CoreBluetooth
import Security
#if os(iOS)
import Contacts
#endif
#if os(iOS)
import UIKit
#endif

enum InmoConnectionState: String { case idle, discovering, connecting, discoveringServices, subscribing, authenticating, ready, setupRequired, unavailable, failed, disconnected }

/// Keep the owner on this device, but usable after locking once unlocked after boot.
struct InmoOwnerIdentityStore {
    var service = "Jarvis.InmoGO3"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "owner"]
    }
    func save(_ identity: Data) throws {
        guard !identity.isEmpty, identity.count <= 1024 else { throw InmoProtocolError.malformed("Owner identity must contain 1–1024 bytes") }
        let attributes: [String: Any] = [kSecValueData as String: identity, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query; item.merge(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw InmoProtocolError.unavailable("Could not save owner identity securely") }
        } else if result != errSecSuccess {
            // Never delete the previous credential if writing its replacement fails.
            throw InmoProtocolError.unavailable("Could not save owner identity securely")
        }
    }
    func read() -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any], let identity = item[kSecValueData as String] as? Data else { return nil }
        // A successful read proves a legacy WhenUnlocked item is currently
        // accessible. Update protection in place; failed migration retains it.
        if item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String {
            let attributes = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
                Task { @MainActor in InmoRuntimeDiagnostics.note("owner identity background accessibility migration deferred") }
            }
        }
        return identity
    }
}

/// Drops a lens card identical to one sent moments ago: a visible push reaches both
/// PushService and PushHandler.willPresent, and each forwards it.
struct InmoCardDeduper {
    var window: TimeInterval = 5
    private var last: (key: String, at: Date)?
    init(window: TimeInterval = 5) { self.window = window }
    mutating func shouldSend(title: String, body: String, now: Date = Date()) -> Bool {
        let key = title + "\u{1F}" + body
        if let last, last.key == key, now.timeIntervalSince(last.at) < window { return false }
        last = (key, now)
        return true
    }
}

/// Cards that arrived while the glasses weren't connected (a push waking the app, a
/// reconnect in progress): the newest few, delivered once the link is ready and
/// dropped once stale.
struct InmoPendingCards {
    struct Card { let title: String; let body: String; let at: Date }
    var limit = 3
    var lifetime: TimeInterval = 60
    private var cards: [Card] = []
    init(limit: Int = 3, lifetime: TimeInterval = 60) { self.limit = limit; self.lifetime = lifetime }
    mutating func add(title: String, body: String, now: Date = Date()) {
        cards.append(Card(title: title, body: body, at: now))
        if cards.count > limit { cards.removeFirst(cards.count - limit) }
    }
    mutating func drain(now: Date = Date()) -> [Card] {
        defer { cards.removeAll() }
        return cards.filter { now.timeIntervalSince($0.at) < lifetime }
    }
}

/// One restorable control session. Owner bytes never enter logs or remote schemas.
@MainActor final class InmoSession: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = InmoSession()
    @Published private(set) var state: InmoConnectionState = .idle {
        didSet {
            if oldValue != state {
                InmoRuntimeDiagnostics.note("connection \(oldValue.rawValue) -> \(state.rawValue)")
                for observer in Array(observers.values) { observer(.connectionChanged(state)) }
            }
        }
    }
    static let maximumFrameLength = 244
    private var audioMessageCount = 0
    private var incomingLogBudget = 80
    private var cardDeduper = InmoCardDeduper()
    private var pendingCards = InmoPendingCards()
    private var lastCallReply: (key: String, at: Date)?
    @Published private(set) var rssi: Int?
    @Published private(set) var status = InmoDeviceStatus()
    @Published private(set) var lastError: String?
    @Published private(set) var discoveredServices: [String] = []
    var isReady: Bool { state == .ready }
    var counters: InmoProtocolCounters { codec.counters }
    // Whether the user wants the phone's own notifications mirrored to the lens
    // over iOS ANCS. Persisted so it survives relaunch; read live so a change
    // takes effect on the next connect.
    static let notificationsEnabledKey = "inmo.ancsNotificationsEnabled"
    static var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: notificationsEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: notificationsEnabledKey) }
    }
    #if os(iOS)
    /// Whether iOS currently authorises this accessory to receive the phone's
    /// notifications over ANCS (Apple Notification Center Service). nil when not
    /// connected.
    var ancsAuthorized: Bool? { peripheral?.ancsAuthorized }
    // Require ANCS on the CoreBluetooth link when notifications are enabled (or
    // when the debug flag forces it) so iOS exposes its notification service to
    // the glasses and prompts, one time, to authorise it.
    private static let requiresANCSFlag = ProcessInfo.processInfo.arguments.contains("--inmo-ancs-require")
    private var connectOptions: [String: Any]? {
        (Self.requiresANCSFlag || Self.notificationsEnabled) ? [CBConnectPeripheralOptionRequiresANCS: true] : nil
    }
    #else
    private var connectOptions: [String: Any]? { nil }
    #endif
    /// Apps put on the glasses' own notification list when notifications are on,
    /// by display name as the official app sends them (it shows Messages as "iMessage").
    static let notificationApps = ["Messages", "iMessage", "Phone", "WhatsApp", "Telegram", "Gmail", "Mail", "Slack", "Calendar", "JARVIS"]
    /// Turn glasses notifications on or off: Jarvis's own cards (forwardNotification)
    /// and the iPhone's notifications over ANCS. The ANCS requirement on the link
    /// applies from the next connect; the firmware switch and app list go now.
    func setNotificationsEnabled(_ on: Bool) {
        Self.notificationsEnabled = on
        guard isReady else { return }
        Task { await sendNotificationSetup(on) }
    }
    /// Put the caller's name on the lens: look the relayed number up in Contacts and
    /// answer once per number and state (the glasses repeat each state several
    /// times). Only when Contacts access is already granted — never prompt mid-call.
    private func answerCall(_ call: InmoCallInfo) {
        let key = "\(call.number)|\(call.state)"
        if let last = lastCallReply, last.key == key, Date().timeIntervalSince(last.at) < 5 { return }
        lastCallReply = (key, Date())
        #if os(iOS)
        let status = CNContactStore.authorizationStatus(for: .contacts)
        var allowed = status == .authorized
        if #available(iOS 18.0, *), status == .limited { allowed = true }
        guard allowed else { return }
        Task {
            guard let book = try? await DefaultContactsStore().contacts(),
                  let name = ContactLookup.nameForNumber(book, number: call.number) else { return }
            do {
                try await send(InmoCommand.callInfo(name: name, number: call.number, state: call.state))
                InmoRuntimeDiagnostics.note("call name sent state=\(call.state)")
            } catch { InmoRuntimeDiagnostics.note("call name failed: \(error.localizedDescription)") }
        }
        #endif
    }
    /// Tell the firmware to consume iOS ANCS (IOS_ANCS_ENABLE) and, when on, list
    /// the apps it may show. The official app refuses this on iOS 27, so whether the
    /// lens then shows iPhone notifications is what the diagnostics are for.
    private func sendNotificationSetup(_ on: Bool) async {
        do {
            try await send(InmoCommand.iosAncsEnable(on))
            if on { for name in Self.notificationApps { try await send(InmoCommand.notificationApp(name, enabled: true)) } }
            #if os(iOS)
            InmoRuntimeDiagnostics.note("ANCS setup sent enabled=\(on) apps=\(on ? Self.notificationApps.count : 0) authorized=\(ancsAuthorized.map(String.init) ?? "nil")")
            #endif
        } catch {
            InmoRuntimeDiagnostics.note("ANCS setup failed: \(error.localizedDescription)")
        }
    }
    /// Push a sample notification card to the lens, over the vendor MESSAGE_REMINDER
    /// path the glasses actually render. Backs the "Send test notification" button.
    func sendTestNotification() {
        guard isReady else { return }
        Task { try? await send(InmoCommand.appNotification(title: "Jarvis", content: "Test notification from Jarvis")) }
    }
    /// Forward a notification the app received onto the lens, when the user has
    /// glasses notifications enabled and the glasses are connected. Best-effort:
    /// silently does nothing when disabled or disconnected.
    func forwardNotification(title: String, body: String) {
        guard Self.notificationsEnabled else { return }
        let cardTitle = title.isEmpty ? "Jarvis" : title
        let cardBody = body.isEmpty ? title : body
        guard !cardBody.isEmpty, cardDeduper.shouldSend(title: cardTitle, body: cardBody) else { return }
        guard isReady else {
            // A push that woke the app usually lands before the link is back: hold the
            // card and reconnect; it goes out when the link reaches ready.
            pendingCards.add(title: cardTitle, body: cardBody)
            InmoRuntimeDiagnostics.note("card held until the glasses reconnect")
            Task { try? await ensureConnected() }
            return
        }
        Task { try? await send(InmoCommand.appNotification(title: cardTitle, content: cardBody)) }
    }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifications: [CBCharacteristic] = []
    private var subscribed: Set<CBUUID> = []
    private let codec = InmoBluetoothFrameCodec()
    private var generation = UUID()
    private var frameID: UInt16 = 0
    private var observers: [UUID: (InmoEvent) -> Void] = [:]
    private var connectionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var deadline: Task<Void, Never>?
    private struct Write { let id: UUID; var frames: [Data]; let continuation: CheckedContinuation<Void, Error> }
    private var writes: [Write] = []
    private var awaitingResponse = false
    private var candidatesPending = 0
    private var scannedFallback = false
    private var restoredPeripheralPending = false
    private var waitingForBluetooth = false
    private var unlockObservation: AnyCancellable?
    private let identityStore = InmoOwnerIdentityStore()
    private var owner: Data? { identityStore.read() }
    override private init() {
        super.init()
        // Upgrade a legacy identity while its old WhenUnlocked protection allows it.
        _ = owner
        #if os(iOS)
        unlockObservation = NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .sink { [weak self] _ in Task { @MainActor in _ = self?.owner } }
        #endif
        central = makeCentral()
    }
    private func makeCentral(retiringPrevious: Bool = false) -> CBCentralManager {
        let key = "inmoGO3.centralRestorationIdentifier"
        // Never reuse a retired manager's identifier in the same process: its
        // cancelled connection and callbacks belong to the previous generation.
        let identifier = retiringPrevious ? UUID().uuidString : (UserDefaults.standard.string(forKey: key) ?? UUID().uuidString)
        UserDefaults.standard.set(identifier, forKey: key)
        return CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: identifier])
    }
    @discardableResult func addEventObserver(_ observer: @escaping (InmoEvent) -> Void) -> UUID { let id = UUID(); observers[id] = observer; return id }
    func removeEventObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func setOwnerIdentity(_ identity: Data) throws {
        try identityStore.save(identity)
    }
    func ensureConnected() async throws {
        if isReady { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectionWaiters[id] = continuation
                if connectionWaiters.count == 1 && !connectionInProgress { beginConnection() }
            }
        }, onCancel: { Task { @MainActor in self.connectionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) } })
    }
    private var connectionInProgress: Bool {
        switch state {
        case .discovering, .connecting, .discoveringServices, .subscribing, .authenticating, .ready: return true
        default: return false
        }
    }
    private func beginConnection() {
        guard owner != nil else { fail("Enter the existing INMO owner identity in local setup before connecting.", state: .setupRequired); return }
        guard central.state == .poweredOn else {
            if central.state == .unknown || central.state == .resetting { waitingForBluetooth = true; state = .discovering; scheduleDeadline(); return }
            fail("Enable Bluetooth and grant Jarvis Bluetooth access.", state: .unavailable); return
        }
        waitingForBluetooth = false
        generation = UUID(); codec.reset(); lastError = nil; scannedFallback = false; state = .discovering; scheduleDeadline()
        #if os(iOS)
        central.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: [CBUUID(string: "2020")]])
        #endif
        if let uuidText = UserDefaults.standard.string(forKey: "inmoGO3.controlPeripheral"), let id = UUID(uuidString: uuidText), let remembered = central.retrievePeripherals(withIdentifiers: [id]).first { connect(remembered); return }
        if let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "2020")]).first { connect(connected); return }
        central.scanForPeripherals(withServices: [CBUUID(string: "2020")], options: nil)
        let current = generation
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard generation == current, state == .discovering else { return }
            #if os(iOS)
            // Background discovery requires a service filter. Keep that scan
            // alive instead of replacing it with an ineffective wildcard scan.
            guard UIApplication.shared.applicationState == .active else { return }
            #endif
            scannedFallback = true; central.stopScan(); central.scanForPeripherals(withServices: nil, options: nil)
        }
    }
    private func scheduleDeadline() {
        deadline?.cancel(); let current = generation
        deadline = Task { try? await Task.sleep(nanoseconds: 20_000_000_000); guard !Task.isCancelled, generation == current, !isReady else { return }; fail("GO3 control connection timed out. Close INMO, keep glasses nearby and retry.") }
    }
    private func connect(_ device: CBPeripheral) {
        guard state == .discovering else { return }; central.stopScan(); peripheral = device; device.delegate = self; state = .connecting; central.connect(device, options: connectOptions)
    }
    func disconnect() { fail("Disconnected", state: .disconnected) }
    private func fail(_ message: String, state next: InmoConnectionState = .failed) {
        InmoRuntimeDiagnostics.note("connection failure: " + message)
        generation = UUID(); deadline?.cancel(); central.stopScan(); waitingForBluetooth = false; restoredPeripheralPending = false
        let old = peripheral; peripheral = nil
        if let old {
            // A CBPeripheral callback has no operation token. Retire the manager
            // and its peripheral objects so an old disconnect/write callback
            // cannot be mistaken for the next connection to the same UUID.
            old.delegate = nil
            central.delegate = nil
            central.cancelPeripheralConnection(old)
            central = makeCentral(retiringPrevious: true)
        }
        state = next; lastError = message; writeCharacteristic = nil; notifications = []; subscribed = []; awaitingResponse = false; codec.reset()
        let waiters = connectionWaiters; connectionWaiters.removeAll(); for c in waiters.values { c.resume(throwing: InmoProtocolError.unavailable(message)) }
        let pending = writes; writes.removeAll(); for w in pending { w.continuation.resume(throwing: InmoProtocolError.unavailable(message)) }
    }
    func send(_ protobuf: Data) async throws {
        guard isReady else { throw InmoProtocolError.unavailable("Connect GO3 controls before sending commands") }
        try await enqueue(protobuf)
    }
    private func enqueue(_ protobuf: Data) async throws {
        guard let p = peripheral, let characteristic = writeCharacteristic else { throw InmoProtocolError.unavailable("GO3 write channel unavailable") }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        frameID &+= 1
        // Over GATT-over-Classic iOS allows 512-byte writes, and the GO3 hangs on one (link
        // lost with an LMP timeout, 2026-09-27); 244 is proven safe (the official app stays ≤178).
        let frames = try InmoBluetoothFrameCodec.frames(payload: protobuf, id: frameID, maximumFrameLength: min(p.maximumWriteValueLength(for: type), Self.maximumFrameLength))
        let id = UUID(); let current = generation
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                guard writes.count < 64 else { c.resume(throwing: InmoProtocolError.unavailable("GO3 command queue is full")); return }
                writes.append(Write(id: id, frames: frames, continuation: c)); pump()
                Task { try? await Task.sleep(nanoseconds: 10_000_000_000); guard generation == current, let index = writes.firstIndex(where: { $0.id == id }) else { return }; let item = writes.remove(at: index); item.continuation.resume(throwing: InmoProtocolError.timedOut); if index == 0 { fail("GO3 write deadline expired; reconnect to clear the channel.") } }
            }
        }, onCancel: { Task { @MainActor in guard let index = self.writes.firstIndex(where: { $0.id == id }) else { return }; self.writes.remove(at: index).continuation.resume(throwing: CancellationError()); if index == 0 { self.fail("Cancelled active GO3 message; reconnect before retrying.") } } })
    }
    private func pump() {
        guard let p = peripheral, let c = writeCharacteristic, !awaitingResponse else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        while !writes.isEmpty {
            if writes[0].frames.isEmpty { writes.removeFirst().continuation.resume(); continue }
            if type == .withoutResponse && !p.canSendWriteWithoutResponse { return }
            let frame = writes[0].frames.removeFirst(); awaitingResponse = type == .withResponse; p.writeValue(frame, for: c, type: type)
            if awaitingResponse { return }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        if central.state == .poweredOn {
            if restoredPeripheralPending { resumeRestoredPeripheral() }
            else if waitingForBluetooth { beginConnection() }
            else if !connectionWaiters.isEmpty && !connectionInProgress { beginConnection() }
        }
        else if central.state != .unknown && central.state != .resetting && central.state != .poweredOn { fail("Bluetooth is unavailable. Enable Bluetooth and allow Jarvis access.", state: .unavailable) }
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard central === self.central, peripheral == nil else { return }
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let remembered = UserDefaults.standard.string(forKey: "inmoGO3.controlPeripheral")
        // This manager is exclusive to GO3; prefer the authenticated device if
        // the system supplies more than one previously pending peripheral.
        guard let device = restored.first(where: { $0.identifier.uuidString == remembered }) ?? restored.first else {
            if dict[CBCentralManagerRestoredStateScanServicesKey] != nil {
                waitingForBluetooth = true; state = .discovering; scheduleDeadline()
            }
            return
        }
        generation = UUID(); codec.reset(); lastError = nil
        peripheral = device; device.delegate = self
        state = .connecting; restoredPeripheralPending = true; waitingForBluetooth = false
        scheduleDeadline()
        if central.state == .poweredOn { resumeRestoredPeripheral() }
    }
    private func resumeRestoredPeripheral() {
        guard restoredPeripheralPending, let peripheral else { return }
        restoredPeripheralPending = false
        guard owner != nil else { fail("Unlock iPhone once and open Jarvis to enable the saved GO3 identity for background reconnect.", state: .setupRequired); return }
        switch peripheral.state {
        case .connected:
            state = .discoveringServices; peripheral.discoverServices(nil)
        case .connecting: break // CoreBluetooth already owns the pending request.
        case .disconnected: central.connect(peripheral, options: connectOptions)
        case .disconnecting: fail("The restored GO3 connection is disconnecting; retry when it has closed.")
        @unknown default: fail("The restored GO3 connection state is unavailable.")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "").lowercased()
        if !scannedFallback || name.contains("go3") || name.contains("inmo") { rssi = RSSI.intValue; connect(peripheral) }
    }
    #if os(iOS)
    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) { if central === self.central && event == .peerConnected && state == .discovering { connect(peripheral) } }
    #endif
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { guard central === self.central, peripheral === self.peripheral, state == .connecting else { return }; restoredPeripheralPending = false; state = .discoveringServices; peripheral.discoverServices(nil) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { guard central === self.central, peripheral === self.peripheral else { return }; fail(error?.localizedDescription ?? "GO3 connection failed") }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { guard central === self.central, peripheral === self.peripheral else { return }; fail(error?.localizedDescription ?? "GO3 disconnected", state: .disconnected) }
    #if os(iOS)
    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral else { return }
        InmoRuntimeDiagnostics.note("ANCS authorization changed: \(peripheral.ancsAuthorized)")
    }
    #endif
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }; if let error { fail(error.localizedDescription); return }
        let services = peripheral.services ?? []; discoveredServices = services.map { $0.uuid.uuidString }; candidatesPending = services.count
        guard !services.isEmpty else { fail("GO3 exposes no discoverable control services"); return }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }; if let error { fail(error.localizedDescription); return }
        discoveredServices.append(contentsOf: (service.characteristics ?? []).map { "\(service.uuid.uuidString)/\($0.uuid.uuidString):\($0.properties.rawValue)" })
        // Candidate UUIDs are deliberately property-checked; unrelated services are never written.
        if service.uuid == CBUUID(string: "2020") {
            for c in service.characteristics ?? [] {
                if ["2021", "2022", "2023"].map({ CBUUID(string: $0) }).contains(c.uuid) {
                    if writeCharacteristic == nil && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) { writeCharacteristic = c }
                    if c.properties.contains(.notify) || c.properties.contains(.indicate) { notifications.append(c) }
                }
            }
        }
        candidatesPending -= 1
        guard candidatesPending == 0 else { return }
        guard writeCharacteristic != nil, !notifications.isEmpty else { fail("GO3 candidate control characteristics were not found. Verify service UUIDs in Research."); return }
        state = .subscribing
        for c in notifications {
            if c.isNotifying { subscribed.insert(c.uuid) }
            else { peripheral.setNotifyValue(true, for: c) }
        }
        authenticateWhenSubscribed()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { fail("GO3 notifications failed: \(error.localizedDescription)"); return }
        guard characteristic.isNotifying else { fail("GO3 notifications were not enabled"); return }
        subscribed.insert(characteristic.uuid)
        authenticateWhenSubscribed()
    }
    private func authenticateWhenSubscribed() {
        if subscribed.count == notifications.count && state == .subscribing {
            state = .authenticating
            guard let owner else { fail("Existing owner identity is required", state: .setupRequired); return }
            let current = generation
            Task {
                guard generation == current else { return }
                do { try await enqueue(InmoCommand.reconnect(owner: owner)) }
                catch { if generation == current { fail(error.localizedDescription) } }
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === writeCharacteristic else { return }
        if let error { fail(error.localizedDescription); return }; awaitingResponse = false; pump()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { guard peripheral === self.peripheral else { return }; pump() }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }; if let error { lastError = error.localizedDescription; return }; guard let data = characteristic.value else { return }
        for raw in codec.consume(data, session: generation, channel: characteristic.uuid.uuidString) {
            do {
                let fields = try InmoWireCodec.decode(raw)
                guard let type = Int(exactly: fields.firstField(2)?.varint ?? 0) else { throw InmoProtocolError.malformed("Invalid message type") }
                if type == 0 { audioMessageCount += 1; if audioMessageCount % 25 == 1 { InmoRuntimeDiagnostics.note("incoming audio message count=\(audioMessageCount) bytes=\(raw.count) channel=\(characteristic.uuid.uuidString)") } }
                if type == 15 { let app = try fields.firstField(18)?.nested(); InmoRuntimeDiagnostics.note("module=\(app?.firstField(1)?.varint ?? 0) action=\(app?.firstField(2)?.varint ?? 0)") }
                // Notifications/calls the glasses pass to the phone (the official app answers
                // these); everything else non-audio is logged, capped, to spot new traffic.
                if type == 4 {
                    InmoRuntimeDiagnostics.note(InmoReminderSummary.describe(fields))
                    if let call = InmoCallInfo.parse(fields), call.name == nil { answerCall(call) }
                }
                else if type != 0, type != 15, incomingLogBudget > 0 { incomingLogBudget -= 1; InmoRuntimeDiagnostics.note("incoming type=\(type) bytes=\(raw.count)") }
                try status.apply(type: type, fields: fields)
                if state == .authenticating, type == 24, let bind = fields.firstField(27) {
                    let response = try bind.nested()
                    if response.firstField(1)?.varint == 3, let result = response.firstField(4) {
                        let resultFields = try result.nested()
                        guard resultFields.firstField(1)?.varint == 1, (resultFields.firstField(3)?.varint ?? 0) == 0 else { fail("GO3 rejected the existing-owner reconnect identity.", state: .setupRequired); return }
                        state = .ready; lastError = nil; deadline?.cancel(); incomingLogBudget = 80; UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "inmoGO3.controlPeripheral")
                        let waiters = connectionWaiters; connectionWaiters.removeAll(); for c in waiters.values { c.resume() }
                        let current = generation
                        Task {
                            guard generation == current else { return }
                            do {
                                try await send(InmoCommand.enableClassicGATT())
                                for query in [27, 31, 32, 33, 35, 38, 28] {
                                    guard generation == current else { return }
                                    try await send(InmoCommand.control(query))
                                }
                                for card in pendingCards.drain() where generation == current {
                                    try await send(InmoCommand.appNotification(title: card.title, content: card.body))
                                }
                                if Self.notificationsEnabled, generation == current { await sendNotificationSetup(true) }
                            } catch { if generation == current { lastError = error.localizedDescription } }
                        }
                    }
                }
                for observer in Array(observers.values) { observer(.message(type: type, fields: fields, raw: raw)) }
            } catch { lastError = "Malformed GO3 response: \(error.localizedDescription)" }
        }
    }
}
