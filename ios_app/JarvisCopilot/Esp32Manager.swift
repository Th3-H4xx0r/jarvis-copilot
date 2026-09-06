import Foundation
import CoreBluetooth
import Network
import UserNotifications

/// Which transport the user wants for a given board. Stored per board.
enum Esp32LinkPreference: String, CaseIterable, Identifiable {
    case auto, wifi, bluetooth
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:      return "Auto"
        case .wifi:      return "Wi‑Fi"
        case .bluetooth: return "Bluetooth"
        }
    }
}

enum Esp32Link: String {
    case bluetooth, wifi
    var label: String { self == .wifi ? "Wi‑Fi" : "Bluetooth" }
    var icon: String { self == .wifi ? "wifi" : "antenna.radiowaves.left.and.right" }
}

/// What the app remembers about a board it has handshaken with, so it can show the
/// card when the board isn't advertising and reach it over Wi‑Fi directly.
struct Esp32KnownBoard: Codable, Equatable {
    var deviceID: String
    var name: String
    var peripheralID: String?
    var hostname: String?
    var ip: String?
}

struct DiscoveredEsp32: Identifiable, Equatable {
    /// The stable device ID once the board is known, otherwise CoreBluetooth's UUID.
    let id: String
    let name: String
    /// 0 when the board is remembered but not currently advertising.
    let rssi: Int
    let peripheral: CBPeripheral?
    let record: Esp32KnownBoard?
    /// Set when the board was seen on the LAN via Bonjour (its mDNS host name).
    var wifiHostname: String? = nil
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    var canUseWifi: Bool { record?.hostname != nil || record?.ip != nil || wifiHostname != nil }
    /// Seen on Wi‑Fi right now, as opposed to merely remembered.
    var isOnWifi: Bool { wifiHostname != nil }
}

enum Esp32Error: LocalizedError {
    case notConnected, timeout, encoding, malformedReply
    case status(Esp32Protocol.Status)
    case protocolMismatch(UInt8)
    case pairingRefused
    case wifiNotSetUp
    case bluetoothOnly
    case notOwner
    case scriptFailed(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:        return "board is not connected"
        case .timeout:             return "board did not answer in time"
        case .encoding:            return "command too long for one frame"
        case .malformedReply:      return "board sent a reply the app could not parse"
        case .status(let s):       return s.label
        case .protocolMismatch(let v): return "board speaks protocol \(v); this app expects \(Esp32Protocol.version). Reflash the firmware."
        case .pairingRefused:      return "pairing was refused — tap Pair when iOS asks, or forget the board in Settings › Bluetooth and retry"
        case .wifiNotSetUp:        return "set up Wi‑Fi over Bluetooth first"
        case .bluetoothOnly:       return "that needs the Bluetooth link"
        case .notOwner:            return "paired to another phone"
        case .scriptFailed(let m): return "script: \(m)"
        case .message(let m):      return m
        }
    }
}

/// Drives one Jarvis ESP32 board over whichever link the user prefers. BLE is always
/// the first handshake: a fresh board is claimed there with a random owner key this
/// phone mints and keeps in the Keychain, and it is the only link that can hand over
/// Wi‑Fi credentials. After that the board is reachable over the LAN as well, and
/// every session on either link opens by presenting the key.
@MainActor
final class Esp32Manager: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var bluetoothReady = false
    @Published private(set) var discovered: [DiscoveredEsp32] = []
    @Published private(set) var connected: DiscoveredEsp32?
    @Published private(set) var activeLink: Esp32Link?
    @Published private(set) var info: Esp32Protocol.BoardInfo?
    @Published private(set) var pins: [Esp32Protocol.PinInfo] = []
    @Published private(set) var pinStates: [UInt8: Esp32Protocol.PinState] = [:]
    @Published private(set) var wifi: Esp32Protocol.WifiStatus?
    @Published private(set) var ledBlinking = false
    @Published private(set) var lastError: String?
    @Published private(set) var script: Esp32Protocol.ScriptStatus?
    @Published private(set) var cloud: Esp32Protocol.CloudStatus?
    /// What the app knows about the script it (or Jarvis, through it) last installed.
    @Published private(set) var scriptInfo: Esp32ScriptInfo?
    /// print() lines, errors and relayed Jarvis calls from the running script, newest last.
    @Published private(set) var scriptLog: [String] = []
    /// Mirrors the scanner-wide "Only Jarvis devices" toggle.
    @Published var strictNameMatch = true {
        didSet { if oldValue != strictNameMatch, connected == nil { startScan() } }
    }

    var ledGPIO: UInt8? { pins.first { $0.capabilities.contains(.led) }?.gpio }
    var ledOn: Bool { (ledGPIO.flatMap { pinStates[$0]?.value } ?? 0) != 0 }
    var exposedDeviceID: String? { exposedDevice?.deviceID }

    // BLE
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var eventCharacteristic: CBCharacteristic?

    // Wi‑Fi
    private var browser: NWBrowser?
    private var bonjourHosts: Set<String> = []
    private var tcp: NWConnection?
    private var tcpParser = Esp32Protocol.StreamParser()
    private var wifiAttempt: Task<Void, Never>?

    // Request pipeline: one frame in flight, replies matched on opcode.
    private struct Pending {
        let seq: Int
        let op: Esp32Protocol.Op
        let frame: [UInt8]
        let timeout: UInt64
        let continuation: CheckedContinuation<[UInt8], Error>
    }
    private var queue: [Pending] = []
    private var inFlight: Pending?
    private var nextSeq = 0
    private var timeoutTask: Task<Void, Never>?

    private var exposedDevice: Esp32Board?
    private var handshakeTask: Task<Void, Never>?

    // Session persistence: once the user connects, the manager keeps the board linked —
    // across screens, app backgrounding and link drops — until Disconnect is tapped.
    private var sessionWanted = false
    private var reconnectTask: Task<Void, Never>?
    private var wifiRetryTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// After a drop, which link to try first on the next attempt.
    private var linkHint: Esp32Link?

    private static let knownBoardsKey = "esp32KnownBoards"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.jarviscopilot.jarviscopilotMobileAndIOS.esp32Central"])
        startBonjour()
    }

    // MARK: - Wi‑Fi discovery

    /// Boards on the LAN announce `_jarvis-esp32._tcp` with their host name as the
    /// instance name, so they show up in the list even with Bluetooth off or out of
    /// range. The browser runs for the life of the manager.
    private func startBonjour() {
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        let b = NWBrowser(for: .bonjour(type: Esp32Protocol.bonjourType, domain: nil), using: params)
        b.stateUpdateHandler = { st in
            if case .failed(let e) = st { print("[ESP32] bonjour failed \(e)") }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let names = Set(results.compactMap { r -> String? in
                if case .service(let name, _, _, _) = r.endpoint { return name.lowercased() }
                return nil
            })
            Task { @MainActor in self?.applyBonjour(names) }
        }
        b.start(queue: .main)
        browser = b
    }

    private func applyBonjour(_ names: Set<String>) {
        bonjourHosts = names
        mergeBonjourIntoDiscovered()
    }

    private func mergeBonjourIntoDiscovered() {
        // Clear stale Wi‑Fi marks, then re-apply the current set.
        for i in discovered.indices where discovered[i].wifiHostname != nil && !bonjourHosts.contains(discovered[i].wifiHostname!) {
            let d = discovered[i]
            discovered[i] = DiscoveredEsp32(id: d.id, name: d.name, rssi: d.rssi, peripheral: d.peripheral, record: d.record, wifiHostname: nil)
        }
        discovered.removeAll { $0.record == nil && $0.peripheral == nil && $0.wifiHostname == nil }
        for host in bonjourHosts {
            let record = Self.knownBoards.first { $0.hostname?.lowercased() == host }
            let id = record?.deviceID ?? "wifi-\(host)"
            // Display name matches the BLE advertisement ("Jarvis-ESP32-33DA").
            let name = record?.name ?? host.replacingOccurrences(of: "jarvis-esp32-", with: "Jarvis-ESP32-").uppercasedSuffix()
            if let i = discovered.firstIndex(where: { $0.id == id }) {
                let d = discovered[i]
                discovered[i] = DiscoveredEsp32(id: d.id, name: d.name, rssi: d.rssi, peripheral: d.peripheral, record: d.record ?? record, wifiHostname: host)
            } else {
                let peripheral = record?.peripheralID.flatMap(UUID.init(uuidString:))
                    .flatMap { central.retrievePeripherals(withIdentifiers: [$0]).first }
                discovered.append(DiscoveredEsp32(id: id, name: name, rssi: 0, peripheral: peripheral, record: record, wifiHostname: host))
            }
        }
    }

    // MARK: - Preferences and records

    static func linkPreference(for deviceID: String) -> Esp32LinkPreference {
        Esp32LinkPreference(rawValue: UserDefaults.standard.string(forKey: "esp32Link.\(deviceID)") ?? "") ?? .auto
    }

    static func setLinkPreference(_ p: Esp32LinkPreference, for deviceID: String) {
        UserDefaults.standard.set(p.rawValue, forKey: "esp32Link.\(deviceID)")
    }

    static var knownBoards: [Esp32KnownBoard] {
        get {
            guard let data = UserDefaults.standard.data(forKey: knownBoardsKey) else { return [] }
            return (try? JSONDecoder().decode([Esp32KnownBoard].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: knownBoardsKey)
        }
    }

    static func forgetBoard(_ deviceID: String) {
        knownBoards.removeAll { $0.deviceID == deviceID }
        Keychain.write("esp32Token.\(deviceID)", nil)
        UserDefaults.standard.removeObject(forKey: "esp32Link.\(deviceID)")
    }

    private static func storeToken(_ token: [UInt8], for deviceID: String) {
        Keychain.write("esp32Token.\(deviceID)", token.map { String(format: "%02x", $0) }.joined())
    }

    private static func mintToken() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Esp32Protocol.tokenLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }

    private static func token(for deviceID: String) -> [UInt8]? {
        guard let hex = Keychain.read("esp32Token.\(deviceID)"), hex.count == Esp32Protocol.tokenLength * 2 else { return nil }
        var out: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b); idx = next
        }
        return out
    }

    private func remember(_ update: (inout Esp32KnownBoard) -> Void, deviceID: String, name: String) {
        var boards = Self.knownBoards
        var record = boards.first { $0.deviceID == deviceID } ?? Esp32KnownBoard(deviceID: deviceID, name: name)
        record.name = name
        update(&record)
        boards.removeAll { $0.deviceID == deviceID }
        boards.append(record)
        Self.knownBoards = boards
        if let c = connected, c.id == deviceID || c.record?.deviceID == deviceID || c.id == record.peripheralID {
            connected = DiscoveredEsp32(id: deviceID, name: name, rssi: c.rssi, peripheral: c.peripheral, record: record)
        }
    }

    // MARK: - Scanning

    func startScan() {
        guard bluetoothReady else { return }
        discovered.removeAll()
        state = .scanning
        surfaceKnownBoards()
        mergeBonjourIntoDiscovered()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Boards we've handshaken with show even when they aren't advertising — a board
    /// on Wi‑Fi across the house, or one already connected, never leaves the list.
    private func surfaceKnownBoards() {
        for record in Self.knownBoards where !discovered.contains(where: { $0.id == record.deviceID }) {
            let peripheral = record.peripheralID.flatMap(UUID.init(uuidString:))
                .flatMap { central.retrievePeripherals(withIdentifiers: [$0]).first }
            discovered.append(DiscoveredEsp32(id: record.deviceID, name: record.name, rssi: 0,
                                              peripheral: peripheral, record: record))
        }
    }

    private func accept(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if services.contains(Esp32Protocol.service) || name.hasPrefix(Esp32Protocol.namePrefix) { return true }
        return !strictNameMatch && name.lowercased().contains("esp32")
    }

    // MARK: - Connecting

    func connect(_ board: DiscoveredEsp32) {
        sessionWanted = true
        reconnectTask?.cancel(); reconnectTask = nil
        teardownLinks()
        connected = board
        if state != .connecting { lastError = nil }
        state = .connecting
        central.stopScan()

        let preference = Self.linkPreference(for: board.id)
        var record = board.record ?? Self.knownBoards.first { $0.deviceID == board.id }
        if let host = board.wifiHostname, record != nil, record?.hostname == nil { record?.hostname = host }
        let wifiReady = record.map { ($0.hostname != nil || $0.ip != nil) && Self.token(for: $0.deviceID) != nil } ?? false

        if record == nil && board.peripheral == nil {
            // Seen on the LAN only, never claimed by this phone: the owner key can only
            // be established over Bluetooth, so there is nothing to connect with yet.
            sessionWanted = false
            fail("This board is on Wi‑Fi but hasn't been set up with this phone. Bring it into Bluetooth range and connect once.")
            return
        }

        switch preference {
        case .bluetooth:
            connectBluetooth(board)
        case .wifi:
            if wifiReady, let record { connectWifi(record, fallbackToBluetooth: false) }
            else { lastError = Esp32Error.wifiNotSetUp.localizedDescription; connectBluetooth(board) }
        case .auto:
            // Wi‑Fi first unless the last thing that failed was Wi‑Fi; Bluetooth's connect
            // request is left pending so iOS reattaches the moment the board is in range,
            // and a background probe keeps trying Wi‑Fi meanwhile.
            if wifiReady, let record, linkHint != .bluetooth {
                connectWifi(record, fallbackToBluetooth: true)
            } else {
                connectBluetooth(board)
            }
        }
        linkHint = nil
    }

    /// Re-run `connect` with the current preference — used after the switcher moves.
    func reconnect() {
        guard let board = connected else { return }
        connect(board)
    }

    /// Explicit user disconnect. The only thing that ends a session.
    func disconnect() {
        sessionWanted = false
        reconnectTask?.cancel(); reconnectTask = nil
        teardownLinks()
        unpublish()
        connected = nil
        info = nil; pins = []; pinStates = [:]; wifi = nil; ledBlinking = false
        activeLink = nil
        state = .idle
        startScan()
    }

    /// Called when the app returns to the foreground: iOS may have torn the socket down
    /// while we were suspended, and a reconnect scheduled then never got to run.
    func resumeIfNeeded() {
        guard sessionWanted, let board = connected, state != .ready else { return }
        if reconnectTask == nil && wifiAttempt == nil && peripheral == nil { connect(board) }
    }

    var isSessionActive: Bool { sessionWanted }

    private func scheduleReconnect(_ message: String) {
        guard sessionWanted, connected != nil else { return }
        lastError = message
        state = .connecting
        reconnectAttempt += 1
        let delay = min(15.0, pow(2.0, Double(min(reconnectAttempt, 4))) * 0.5)  // 1, 2, 4, 8, 8…
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.sessionWanted, let board = self.connected else { return }
            self.reconnectTask = nil
            self.connect(board)
        }
    }

    private func teardownLinks() {
        handshakeTask?.cancel(); handshakeTask = nil
        wifiAttempt?.cancel(); wifiAttempt = nil
        wifiRetryTask?.cancel(); wifiRetryTask = nil
        keepaliveTask?.cancel(); keepaliveTask = nil
        failAll(Esp32Error.notConnected)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil; commandCharacteristic = nil; eventCharacteristic = nil
        tcp?.cancel(); tcp = nil
        tcpParser.reset()
    }

    private func fail(_ message: String) {
        lastError = message
        state = .failed(message)
    }

    // MARK: Bluetooth link

    private func connectBluetooth(_ board: DiscoveredEsp32) {
        guard let p = board.peripheral else {
            fail("This board is not in Bluetooth range right now")
            return
        }
        activeLink = .bluetooth
        peripheral = p
        p.delegate = self
        state = .connecting
        print("[ESP32] BLE connecting \(board.name)")
        // No timeout on purpose: iOS keeps this pending and completes it whenever the
        // board comes back into range, which is exactly the "retain the link" behaviour.
        central.connect(p)

        let record = board.record ?? Self.knownBoards.first { $0.deviceID == board.id }
        if Self.linkPreference(for: board.id) == .auto,
           let record, record.hostname != nil || record.ip != nil, Self.token(for: record.deviceID) != nil {
            startWifiProbe(record)
        }
    }

    /// While a Bluetooth connect is pending (board out of BLE range), keep probing the
    /// LAN every 20 s; if the board answers there, switch to Wi‑Fi.
    private func startWifiProbe(_ record: Esp32KnownBoard) {
        wifiRetryTask?.cancel()
        wifiRetryTask = Task { [weak self] in
            let port = NWEndpoint.Port(rawValue: Esp32Protocol.tcpPort)!
            var hosts: [NWEndpoint.Host] = []
            if let h = record.hostname { hosts.append(NWEndpoint.Host("\(h).local")) }
            if let ip = record.ip { hosts.append(NWEndpoint.Host(ip)) }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.sessionWanted, self.state != .ready, self.activeLink == .bluetooth else { return }
                for host in hosts where !Task.isCancelled {
                    if await self.openTCP(host: host, port: port) {
                        print("[ESP32] board reachable over Wi‑Fi, switching")
                        if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
                        self.peripheral = nil; self.commandCharacteristic = nil; self.eventCharacteristic = nil
                        self.activeLink = .wifi
                        self.state = .discovering
                        self.beginHandshake()
                        return
                    }
                }
            }
        }
    }

    // MARK: Wi‑Fi link

    private func connectWifi(_ record: Esp32KnownBoard, fallbackToBluetooth: Bool) {
        activeLink = .wifi
        state = .connecting
        // The .local name survives DHCP renewals; the raw IP is the backup when mDNS
        // isn't answering on this network.
        var hosts: [NWEndpoint.Host] = []
        if let h = record.hostname { hosts.append(NWEndpoint.Host("\(h).local")) }
        if let ip = record.ip { hosts.append(NWEndpoint.Host(ip)) }
        let port = NWEndpoint.Port(rawValue: Esp32Protocol.tcpPort)!

        wifiAttempt = Task { [weak self] in
            for host in hosts {
                guard let self, !Task.isCancelled else { return }
                if await self.openTCP(host: host, port: port) {
                    self.state = .discovering
                    self.beginHandshake()
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            if fallbackToBluetooth, let board = self.connected {
                print("[ESP32] Wi‑Fi unreachable, falling back to Bluetooth")
                self.lastError = "Wi‑Fi unreachable, using Bluetooth"
                self.connectBluetooth(board)
            } else {
                self.fail("Could not reach the board over Wi‑Fi")
            }
        }
    }

    /// Opens a socket and waits up to a few seconds for it to become ready.
    private func openTCP(host: NWEndpoint.Host, port: NWEndpoint.Port) async -> Bool {
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = 4
        }
        let conn = NWConnection(host: host, port: port, using: params)
        tcp = conn
        tcpParser.reset()
        print("[ESP32] TCP connecting \(host)")

        let ready: Bool = await withCheckedContinuation { cont in
            var settled = false
            conn.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    guard let self, self.tcp === conn else { return }
                    switch st {
                    case .ready:
                        if !settled { settled = true; cont.resume(returning: true) }
                        self.receiveTCP(conn)
                    case .failed(let e):
                        print("[ESP32] TCP failed \(e)")
                        if !settled { settled = true; cont.resume(returning: false) }
                        else { self.linkDropped("Wi‑Fi link dropped") }
                    case .cancelled:
                        if !settled { settled = true; cont.resume(returning: false) }
                    case .waiting(let e):
                        // No route yet (wrong network, board offline). Treat as a miss.
                        print("[ESP32] TCP waiting \(e)")
                        if !settled { settled = true; conn.cancel(); cont.resume(returning: false) }
                    default: break
                    }
                }
            }
            conn.start(queue: .main)
        }
        if !ready, tcp === conn { tcp = nil }
        return ready
    }

    private func receiveTCP(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.tcp === conn else { return }
                if let data {
                    for frame in self.tcpParser.feed(data) { self.handle(frame) }
                }
                if isComplete || error != nil {
                    self.linkDropped("Board closed the Wi‑Fi link")
                    return
                }
                self.receiveTCP(conn)
            }
        }
    }

    /// The active link went away underneath a live session. The session stays wanted,
    /// so schedule a reconnect; in Auto mode the other link is tried first. The board
    /// stays registered with Jarvis (its `connected` flag just reads false meanwhile).
    private func linkDropped(_ message: String) {
        guard sessionWanted, connected != nil else { return }
        let dropped = activeLink
        teardownLinks()
        linkHint = dropped == .bluetooth ? .wifi : .bluetooth
        scheduleReconnect(message + ", reconnecting…")
    }

    // MARK: - Handshake

    private func beginHandshake() {
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in await self?.handshake() }
    }

    private func handshake() async {
        do {
            let info: Esp32Protocol.BoardInfo
            if activeLink == .wifi {
                // Over the LAN nothing is answered before AUTH, so the key comes first.
                guard let id = connected?.record?.deviceID ?? connected?.id,
                      let token = Self.token(for: id) else { throw Esp32Error.wifiNotSetUp }
                _ = try await request(.auth, payload: token)
                guard let parsed = Esp32Protocol.parsePing(try await request(.ping)) else { throw Esp32Error.malformedReply }
                info = parsed
            } else {
                // PING is the one command an unclaimed or unauthorised BLE session may
                // send; it tells us whether to claim the board or prove ownership.
                guard let parsed = Esp32Protocol.parsePing(try await request(.ping)) else { throw Esp32Error.malformedReply }
                info = parsed
                guard info.protocolVersion == Esp32Protocol.version else { throw Esp32Error.protocolMismatch(info.protocolVersion) }
                if info.claimed {
                    guard let token = Self.token(for: info.deviceID) else { throw Esp32Error.notOwner }
                    do { _ = try await request(.auth, payload: token) }
                    catch Esp32Error.status(.unauthorized) { throw Esp32Error.notOwner }
                } else {
                    let token = Self.mintToken()
                    _ = try await request(.claim, payload: token)
                    Self.storeToken(token, for: info.deviceID)
                    print("[ESP32] claimed \(info.deviceID)")
                }
            }
            guard info.protocolVersion == Esp32Protocol.version else { throw Esp32Error.protocolMismatch(info.protocolVersion) }
            self.info = info
            guard let pins = Esp32Protocol.parseInfo(try await request(.getInfo)) else { throw Esp32Error.malformedReply }
            self.pins = pins
            try await refreshState()
            try await refreshWifi()
            try? await refreshScript()
            try? await refreshCloud()
            scriptInfo = Esp32ScriptInfo.load(for: info.deviceID)
            let name = connected?.name ?? info.deviceID
            let peripheralID = peripheral?.identifier.uuidString
            let wifiNow = wifi
            remember({ r in
                if let peripheralID { r.peripheralID = peripheralID }
                if let w = wifiNow {
                    if !w.hostname.isEmpty { r.hostname = w.hostname }
                    if let ip = w.ip { r.ip = ip }
                }
            }, deviceID: info.deviceID, name: name)
            state = .ready
            lastError = nil
            reconnectAttempt = 0
            publish()
            if activeLink == .wifi { startKeepalive() }
            print("[ESP32] ready over \(activeLink?.label ?? "?") as \(info.deviceID)")
        } catch is CancellationError {
        } catch {
            print("[ESP32] handshake failed: \(error)")
            let message = error.localizedDescription
            let overWifi = activeLink == .wifi
            teardownLinks()
            switch error {
            case Esp32Error.notOwner, Esp32Error.protocolMismatch, Esp32Error.pairingRefused:
                // Permanent: retrying won't help, and we shouldn't keep a session open.
                sessionWanted = false
                fail(message)
            default:
                if overWifi, let board = connected, Self.linkPreference(for: board.id) == .auto, board.peripheral != nil {
                    lastError = "Wi‑Fi: \(message). Using Bluetooth."
                    connectBluetooth(board)
                } else {
                    scheduleReconnect(message)
                }
            }
        }
    }

    /// The board drops a TCP client that has been silent for two minutes; a ping every
    /// 30 s keeps the socket, and doubles as liveness detection.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self, self.state == .ready, self.activeLink == .wifi else { return }
                do { _ = try await self.request(.ping) }
                catch { self.linkDropped("Wi‑Fi keepalive failed") }
            }
        }
    }

    // MARK: - Request pipeline

    func request(_ op: Esp32Protocol.Op, payload: [UInt8] = [], timeoutSeconds: Double = 3) async throws -> [UInt8] {
        guard let frame = Esp32Protocol.encode(op, payload: payload) else { throw Esp32Error.encoding }
        return try await withCheckedThrowingContinuation { cont in
            nextSeq += 1
            queue.append(Pending(seq: nextSeq, op: op, frame: frame,
                                 timeout: UInt64(timeoutSeconds * 1_000_000_000), continuation: cont))
            pump()
        }
    }

    private var linkIsUp: Bool {
        switch activeLink {
        case .bluetooth: return commandCharacteristic != nil && peripheral?.state == .connected
        case .wifi:      return tcp?.state == .ready
        case nil:        return false
        }
    }

    private func pump() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        guard linkIsUp else {
            next.continuation.resume(throwing: Esp32Error.notConnected)
            pump()
            return
        }
        inFlight = next
        write(next.frame)
        let seq = next.seq
        let timeout = next.timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled, let self, self.inFlight?.seq == seq else { return }
            self.finish(.failure(Esp32Error.timeout))
        }
    }

    private func finish(_ result: Result<[UInt8], Error>) {
        timeoutTask?.cancel(); timeoutTask = nil
        guard let p = inFlight else { return }
        inFlight = nil
        p.continuation.resume(with: result)
        pump()
    }

    private func failAll(_ error: Error) {
        timeoutTask?.cancel(); timeoutTask = nil
        if let p = inFlight { inFlight = nil; p.continuation.resume(throwing: error) }
        let rest = queue; queue.removeAll()
        rest.forEach { $0.continuation.resume(throwing: error) }
    }

    private func write(_ frame: [UInt8]) {
        switch activeLink {
        case .bluetooth:
            guard let peripheral, let c = commandCharacteristic else { return }
            // Without-response saves a full ATT round trip per command; the reply
            // notification is the acknowledgement anyway.
            let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            peripheral.writeValue(Data(frame), for: c, type: type)
        case .wifi:
            tcp?.send(content: Data(frame), completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.linkDropped("Wi‑Fi send failed: \(error.localizedDescription)") }
            })
        case nil:
            break
        }
    }

    private func handle(_ inbound: Esp32Protocol.Inbound) {
        switch inbound {
        case .response(let op, let status, let payload):
            // op 0 is the board's "could not parse that frame" reply.
            guard let p = inFlight, op == p.op.rawValue || op == 0 else { return }
            switch status {
            case .ok:          finish(.success(payload))
            case .scriptError: finish(.failure(Esp32Error.scriptFailed(String(decoding: payload, as: UTF8.self))))
            default:           finish(.failure(Esp32Error.status(status)))
            }
        case .event(let event, let payload):
            apply(event, payload)
        }
    }

    private func apply(_ event: Esp32Protocol.Event, _ p: [UInt8]) {
        switch event {
        case .inputChanged, .pulseDone:
            guard p.count >= 2 else { return }
            pinStates[p[0]]?.value = p[1]
        case .blinkDone:
            ledBlinking = false
            Task { try? await refreshState() }
        case .wifiChanged:
            guard let (state, ip) = Esp32Protocol.parseWifiChanged(p) else { return }
            if let w = wifi {
                wifi = Esp32Protocol.WifiStatus(state: state, ip: ip, rssi: w.rssi, port: w.port, hostname: w.hostname, ssid: w.ssid)
            }
            if state == .connected, let ip, let id = info?.deviceID, let name = connected?.name {
                remember({ $0.ip = ip }, deviceID: id, name: name)
            }
            Task { try? await refreshWifi() }
        case .scriptOutput:
            appendLog(String(decoding: p, as: UTF8.self))
        case .scriptState:
            Task { try? await refreshScript() }
        case .jarvisCall:
            guard let call = Esp32Protocol.parseJarvisCall(p) else { return }
            handleJarvisCall(id: call.id, name: call.name, json: call.json)
        case .cloudChanged:
            Task { try? await refreshCloud() }
        }
    }

    // MARK: - Direct Jarvis link

    func refreshCloud() async throws {
        guard let c = Esp32Protocol.parseCloudStatus(try await request(.cloudStatus)) else { throw Esp32Error.malformedReply }
        cloud = c
        refreshRegistryMembership()
    }

    /// Hands the board its own pairing with the Jarvis server. The app asks the server
    /// for a one-time code, passes it (and the tunnel token) to the board, and the
    /// board claims it over Wi‑Fi, then reboots without Bluetooth to hold the bridge.
    func linkBoardToJarvis() async throws {
        guard state == .ready else { throw Esp32Error.notConnected }
        guard BridgeClient.shared.isPaired else { throw JarvisChatClient.ChatError.notPaired }
        try? await refreshWifi()
        guard wifi?.state == .connected else {
            throw DeviceError.badArgument("the board is not on Wi‑Fi yet — set up its network first (current: \(wifi?.state.label ?? "unknown"))")
        }
        guard var req = BridgeClient.shared.authorizedRequest(path: "api/devices/pair/start", timeout: 30) else {
            throw JarvisChatClient.ChatError.noServer
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["label": "ESP32 \(connected?.name ?? "board")", "ttl": 300])
        let (data, response) = try await BridgeClient.shared.urlSession.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["code"] as? String, !code.isEmpty else {
            throw JarvisChatClient.ChatError.badReply
        }
        // Every request the board makes must clear the Cloudflare tunnel with the Access
        // service token: prefer the one the server hands out for pairing, else the app's own.
        let cf = obj["cf_access"] as? [String: Any]
        let cfID = (cf?["client_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? BridgeClient.shared.cfAccessToken?.id ?? ""
        let cfSecret = (cf?["client_secret"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? BridgeClient.shared.cfAccessToken?.secret ?? ""
        guard let payload = Esp32Protocol.cloudSetPayload(server: BridgeClient.shared.serverURL, code: code,
                                                          cfID: cfID, cfSecret: cfSecret) else {
            throw DeviceError.badArgument("server address too long")
        }
        appendLog("— linking the board to Jarvis…")
        // The board claims the code over HTTPS itself; give it time for the TLS handshake.
        _ = try await request(.cloudSet, payload: payload, timeoutSeconds: 25)
        try? await refreshCloud()
        // The board reboots into cloud mode now; Bluetooth goes away and the session
        // machinery brings the link back over Wi‑Fi on the LAN.
        if let id = info?.deviceID { Self.setLinkPreference(.auto, for: id) }
        lastError = "Board is restarting into its direct Jarvis link…"
    }

    /// Asks a board on its own link to come back over Bluetooth (keeps the session).
    func pauseBoardCloudMode() async throws {
        _ = try await request(.cloudPause)
        lastError = "Board is restarting on Bluetooth…"
    }

    func unlinkBoardFromJarvis() async throws {
        _ = try await request(.cloudForget)
        try? await refreshCloud()
    }

    /// Remembers what was installed so the board screen can summarise it.
    func rememberScript(name: String, source: String) {
        guard let id = info?.deviceID else { return }
        let info = Esp32ScriptInfo(name: name, summary: Esp32ScriptInfo.summary(of: source), source: source, installedAt: Date())
        info.save(for: id)
        scriptInfo = info
    }

    func clearScriptInfo() {
        guard let id = info?.deviceID else { return }
        Esp32ScriptInfo.clear(for: id)
        scriptInfo = nil
    }

    private func appendLog(_ line: String) {
        scriptLog.append(line)
        if scriptLog.count > 300 { scriptLog.removeFirst(scriptLog.count - 300) }
    }

    // MARK: - Scripts

    func refreshScript() async throws {
        guard let st = Esp32Protocol.parseScriptStatus(try await request(.scriptStatus)) else { throw Esp32Error.malformedReply }
        script = st
    }

    /// Streams a Lua script to the board, which stores it, compiles it and starts it.
    /// A compile error comes back as `Esp32Error.scriptFailed` with Lua's message.
    func uploadScript(_ source: String, name: String, autostart: Bool = true) async throws {
        let bytes = Array(source.utf8)
        guard let begin = Esp32Protocol.scriptBeginPayload(total: bytes.count, autostart: autostart, name: name) else {
            throw DeviceError.badArgument("script must be 1–\(Esp32Protocol.maxScriptBytes) bytes")
        }
        _ = try await request(.scriptBegin, payload: begin)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + Esp32Protocol.scriptChunkSize, bytes.count)
            _ = try await request(.scriptChunk, payload: Esp32Protocol.u16(UInt16(offset)) + Array(bytes[offset..<end]))
            offset = end
        }
        appendLog("— uploading '\(name)' (\(bytes.count) bytes)")
        _ = try await request(.scriptCommit, payload: [Esp32Protocol.crc8(bytes)], timeoutSeconds: 8)
        try await refreshScript()
        rememberScript(name: name, source: source)
    }

    func startScript() async throws { _ = try await request(.scriptStart); try await refreshScript() }
    func stopScript() async throws { _ = try await request(.scriptStop); try await refreshScript() }
    func deleteScript() async throws { _ = try await request(.scriptDelete); try await refreshScript(); clearScriptInfo() }
    func clearScriptLog() { scriptLog.removeAll() }

    // MARK: - Jarvis relay

    /// A script asked for something outside the board. `notify` is delivered right here
    /// as an iPhone notification; anything else becomes a background turn for the
    /// Jarvis agent, which has all its tools, and the agent's one-line result goes back
    /// to the script's callback.
    private func handleJarvisCall(id: UInt16, name: String, json: String) {
        appendLog("→ jarvis.\(name) \(json)")
        // One at a time, so a chatty script can't fan out into parallel agent turns.
        let previous = relayChain
        relayChain = Task {
            await previous?.value
            let (ok, text) = await runJarvisCall(name: name, json: json)
            appendLog("← \(ok ? "ok" : "failed"): \(text)")
            let body = Array(text.utf8.prefix(Esp32Protocol.maxBody - 5))
            _ = try? await request(.jarvisResult, payload: Esp32Protocol.u16(id) + [ok ? 1 : 0] + body)
        }
    }
    private var relayChain: Task<Void, Never>?

    /// Tries the named action as a device skill on the server — silent, no model — and
    /// only falls back to an agent turn when no such skill exists.
    private func invokeSkillDirect(name: String, args: [String: Any]) async -> (handled: Bool, ok: Bool, text: String) {
        guard var req = BridgeClient.shared.authorizedRequest(path: "api/devices/skills/invoke", timeout: 60) else {
            return (false, false, "")
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["skill": name, "args": args, "timeout": 30])
        guard let (data, response) = try? await BridgeClient.shared.urlSession.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, false, "") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, obj["ok"] as? Bool == true {
            let result = obj["result"].map { r -> String in
                if let s = r as? String { return s }
                if let d = try? JSONSerialization.data(withJSONObject: r), let s = String(data: d, encoding: .utf8) { return s }
                return "\(r)"
            } ?? "done"
            return (true, true, String(result.prefix(200)))
        }
        let error = (obj["error"] as? String ?? "").lowercased()
        // "No device offers that skill" style errors mean it wasn't a skill: let the agent decide.
        if code == 404 || error.contains("unknown") || error.contains("no device") || error.contains("not found") || error.contains("no such") {
            return (false, false, error)
        }
        return (true, false, obj["error"] as? String ?? "skill failed (\(code))")
    }

    private func runJarvisCall(name: String, json: String) async -> (Bool, String) {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        if name == "notify" {
            let title = args["title"] as? String ?? "Jarvis ESP32"
            let body = args["body"] as? String ?? ""
            await Esp32Notifier.post(title: title, body: body, boardName: connected?.name ?? "ESP32")
            return (true, "notification shown")
        }
        guard BridgeClient.shared.isPaired else { return (false, "Jarvis is not paired in this app") }
        let direct = await invokeSkillDirect(name: name, args: args)
        if direct.handled { return (direct.ok, direct.text) }

        // Not a skill: a short agent turn in one consolidated per-board conversation.
        let boardName = connected?.name ?? "ESP32"
        let scriptName = script?.name ?? "script"
        let prompt = "[board event] \(boardName) · script \"\(scriptName)\" asks: `\(name)` \(json). Do it with your tools; reply in one line."
        do {
            let chat = JarvisChatClient.shared
            let session = try await chat.sessionID(for: (info?.deviceID ?? boardName) + ".events", title: "ESP32 \(boardName) events")
            var reply = ""
            do {
                reply = try await chat.send(sessionID: session, message: prompt, onEvent: { _ in })
            } catch JarvisChatClient.ChatError.busy {
                // Previous event still running; wait for it, then send ours.
                if let stream = try? await chat.snapshot(sessionID: session).activeStreamID {
                    _ = try? await chat.attach(streamID: stream) { _ in }
                }
                reply = try await chat.send(sessionID: session, message: prompt, onEvent: { _ in })
            }
            let line = reply.split(whereSeparator: \.isNewline).last.map(String.init) ?? reply
            return (true, line.isEmpty ? "done" : line)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Commands

    func refreshState() async throws {
        guard let states = Esp32Protocol.parseState(try await request(.getState)) else { throw Esp32Error.malformedReply }
        pinStates = Dictionary(uniqueKeysWithValues: states.map { ($0.gpio, $0) })
    }

    func refreshWifi() async throws {
        guard let w = Esp32Protocol.parseWifiStatus(try await request(.wifiStatus)) else { throw Esp32Error.malformedReply }
        wifi = w
        if let id = info?.deviceID, let name = connected?.name, w.state == .connected {
            remember({ r in r.hostname = w.hostname; r.ip = w.ip ?? r.ip }, deviceID: id, name: name)
        }
    }

    func setLED(_ on: Bool) async throws {
        let reply = try await request(.ledSet, payload: [on ? 1 : 0])
        ledBlinking = false
        if let gpio = ledGPIO, let level = reply.first {
            pinStates[gpio] = .init(gpio: gpio, mode: .output, value: level)
        }
    }

    func blinkLED(count: Int, periodMs: Int) async throws {
        guard (1...255).contains(count), (50...5000).contains(periodMs) else { throw DeviceError.badArgument("count 1–255, period 50–5000 ms") }
        _ = try await request(.ledBlink, payload: [UInt8(count)] + Esp32Protocol.u16(UInt16(periodMs)))
        ledBlinking = true
    }

    func stopBlink() async throws {
        _ = try await request(.ledBlink, payload: [0, 0, 0])
        ledBlinking = false
        try await refreshState()
    }

    func setPinMode(_ gpio: UInt8, _ mode: Esp32Protocol.PinMode) async throws {
        guard mode != .unset else { throw DeviceError.badArgument("mode") }
        _ = try await request(.pinMode, payload: [gpio, mode.rawValue])
        try await refreshState()
    }

    func writePin(_ gpio: UInt8, high: Bool) async throws {
        let reply = try await request(.pinWrite, payload: [gpio, high ? 1 : 0])
        if let level = reply.first { pinStates[gpio] = .init(gpio: gpio, mode: .output, value: level) }
        if gpio == ledGPIO { ledBlinking = false }
    }

    func readPin(_ gpio: UInt8) async throws -> Bool {
        let reply = try await request(.pinRead, payload: [gpio])
        guard let level = reply.first else { throw Esp32Error.malformedReply }
        if pinStates[gpio]?.mode != .pwm { pinStates[gpio]?.value = level }
        return level != 0
    }

    func setPWM(_ gpio: UInt8, duty: Int) async throws {
        guard (0...255).contains(duty) else { throw DeviceError.badArgument("duty 0–255") }
        _ = try await request(.pinPWM, payload: [gpio, UInt8(duty)])
        pinStates[gpio] = .init(gpio: gpio, mode: .pwm, value: UInt8(duty))
        if gpio == ledGPIO { ledBlinking = false }
    }

    func pulsePin(_ gpio: UInt8, high: Bool, durationMs: Int) async throws {
        guard (1...10000).contains(durationMs) else { throw DeviceError.badArgument("duration 1–10000 ms") }
        _ = try await request(.pinPulse, payload: [gpio, high ? 1 : 0] + Esp32Protocol.u16(UInt16(durationMs)))
        pinStates[gpio] = .init(gpio: gpio, mode: .output, value: high ? 1 : 0)
    }

    func allOff() async throws {
        _ = try await request(.allOff)
        ledBlinking = false
        try await refreshState()
    }

    /// Hands the board a network. Bluetooth-only by design: the credentials ride the
    /// bonded, encrypted link and never the LAN.
    func setWifi(ssid: String, password: String) async throws {
        guard activeLink == .bluetooth else { throw Esp32Error.bluetoothOnly }
        guard let payload = Esp32Protocol.wifiSetPayload(ssid: ssid, password: password) else {
            throw DeviceError.badArgument("SSID 1–32 bytes, password up to 64")
        }
        _ = try await request(.wifiSet, payload: payload)
        try await refreshWifi()
    }

    /// Asks the board for the 2.4 GHz networks it can see, strongest first, one entry
    /// per SSID. The board scans asynchronously, so page 0 is polled until it's ready.
    func scanWifi() async throws -> [Esp32Protocol.WifiNetwork] {
        var page = 0
        var all: [Esp32Protocol.WifiNetwork] = []
        var attempts = 0
        while true {
            do {
                guard let result = Esp32Protocol.parseWifiScan(try await request(.wifiScan, payload: [UInt8(page)])) else {
                    throw Esp32Error.malformedReply
                }
                all += result.networks
                if (page + 1) * 3 >= result.total || result.networks.isEmpty { break }
                page += 1
            } catch Esp32Error.status(.scanning) {
                attempts += 1
                guard attempts < 20 else { throw Esp32Error.timeout }
                try await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        var best: [String: Esp32Protocol.WifiNetwork] = [:]
        for n in all where best[n.ssid].map({ n.rssi > $0.rssi }) ?? true { best[n.ssid] = n }
        return best.values.sorted { $0.rssi > $1.rssi }
    }

    /// Reset the board's owner key while the user holds its BOOT button, then
    /// forget our own copy so the next handshake claims it afresh. The firmware
    /// refuses without the button (`unauthorized`), which we surface as guidance.
    func resetOwnership(deviceID: String) async throws {
        do {
            _ = try await request(.resetOwner, timeoutSeconds: 4)
        } catch Esp32Error.status(.unauthorized) {
            throw Esp32Error.message("Hold the BOOT button on the board while tapping Reset.")
        }
        Keychain.write("esp32Token.\(deviceID)", nil)
        lastError = nil
    }

    func forgetWifi() async throws {
        guard activeLink == .bluetooth else { throw Esp32Error.bluetoothOnly }
        _ = try await request(.wifiForget)
        if let id = info?.deviceID, let name = connected?.name {
            remember({ $0.hostname = nil; $0.ip = nil }, deviceID: id, name: name)
        }
        try await refreshWifi()
    }

    /// UI helper: run a command and surface its failure in `lastError`.
    func perform(_ body: @escaping () async throws -> Void) {
        Task {
            do { try await body(); lastError = nil }
            catch { lastError = error.localizedDescription }
        }
    }

    // MARK: - Jarvis registry

    private func publish() {
        if exposedDevice == nil { exposedDevice = Esp32Board(manager: self) }
        refreshRegistryMembership()
    }

    func refreshRegistryMembership() {
        guard let device = exposedDevice else { return }
        // A board on its own Jarvis link registers its skills itself; advertising them
        // from the phone too would give Jarvis two copies of every command.
        let boardHoldsBridge = cloud?.cloudMode == true && (cloud?.state == .connected || cloud?.state == .connecting)
        let shouldShare = BridgeClient.isExposed(device.deviceID) && !boardHoldsBridge
        let isShared = DeviceRegistry.shared.device(id: device.deviceID) != nil
        guard shouldShare != isShared else { return }
        if shouldShare {
            DeviceRegistry.shared.register(device)
            BridgeClient.remember(deviceID: device.deviceID, model: Esp32Board.model)
        } else {
            DeviceRegistry.shared.remove(deviceID: device.deviceID)
            BridgeClient.forget(deviceID: device.deviceID)
        }
        BridgeClient.shared.sendRegistration()
    }

    private func unpublish() {
        guard let exposedDevice else { return }
        DeviceRegistry.shared.remove(deviceID: exposedDevice.deviceID)
        self.exposedDevice = nil
        BridgeClient.shared.sendRegistration()
    }
}

// MARK: - CoreBluetooth

extension Esp32Manager: CBCentralManagerDelegate {
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            guard let p = restored.first(where: { $0.state == .connected || $0.state == .connecting }) else { return }
            peripheral = p
            p.delegate = self
            activeLink = .bluetooth
            let record = Self.knownBoards.first { $0.peripheralID == p.identifier.uuidString }
            connected = DiscoveredEsp32(id: record?.deviceID ?? p.identifier.uuidString,
                                        name: p.name ?? record?.name ?? Esp32Protocol.namePrefix,
                                        rssi: 0, peripheral: p, record: record)
            state = p.state == .connected ? .discovering : .connecting
            if p.state == .connected { p.discoverServices([Esp32Protocol.service]) }
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
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? Esp32Protocol.namePrefix
            let record = Self.knownBoards.first { $0.peripheralID == peripheral.identifier.uuidString }
            var board = DiscoveredEsp32(id: record?.deviceID ?? peripheral.identifier.uuidString,
                                        name: name, rssi: RSSI.intValue, peripheral: peripheral, record: record)
            if let i = discovered.firstIndex(where: { $0.id == board.id }) {
                board.wifiHostname = discovered[i].wifiHostname
                discovered[i] = board
            } else {
                // An unclaimed board seen over Bonjour has a placeholder id; fold it in.
                if let host = record?.hostname?.lowercased() ?? Optional(name.lowercased()),
                   let j = discovered.firstIndex(where: { $0.id == "wifi-\(host)" }) {
                    board.wifiHostname = discovered[j].wifiHostname
                    discovered.remove(at: j)
                }
                discovered.append(board)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            state = .discovering
            peripheral.discoverServices([Esp32Protocol.service])
        }
    }

    /// iOS keeps Bluetooth keys for a board it once bonded with; if the board no longer
    /// has them, iOS refuses every connection until the user forgets the device.
    private func describe(_ error: Error?) -> String {
        guard let error else { return "Bluetooth disconnected" }
        if let cb = error as? CBError, cb.code == .peerRemovedPairingInformation {
            return "iOS still holds old pairing keys for this board. Open Settings › Bluetooth, forget \(connected?.name ?? "the board"), then reconnect."
        }
        return error.localizedDescription
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            self.peripheral = nil
            if let cb = error as? CBError, cb.code == .peerRemovedPairingInformation {
                sessionWanted = false   // retrying can't help until the user forgets the device
                fail(describe(error))
            } else {
                linkDropped(describe(error))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            if activeLink == .bluetooth {
                self.peripheral = nil
                if let cb = error as? CBError, cb.code == .peerRemovedPairingInformation {
                    sessionWanted = false
                    fail(describe(error))
                } else {
                    linkDropped(error.map { "Bluetooth dropped: \($0.localizedDescription)" } ?? "Bluetooth disconnected")
                }
            }
        }
    }
}

extension Esp32Manager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = peripheral.services?.first(where: { $0.uuid == Esp32Protocol.service }) else {
                fail("Board does not expose the Jarvis service")
                return
            }
            peripheral.discoverCharacteristics([Esp32Protocol.commandCharacteristic, Esp32Protocol.eventCharacteristic], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            let chars = service.characteristics ?? []
            commandCharacteristic = chars.first { $0.uuid == Esp32Protocol.commandCharacteristic }
            eventCharacteristic = chars.first { $0.uuid == Esp32Protocol.eventCharacteristic }
            guard let eventCharacteristic, commandCharacteristic != nil else {
                fail("Board is missing the command or event characteristic")
                return
            }
            // Subscribing to the encrypted CCCD is what triggers the iOS passkey prompt
            // on first contact; afterwards the bond makes it silent.
            peripheral.setNotifyValue(true, for: eventCharacteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                let code = (error as? CBATTError)?.code
                if code == .insufficientAuthentication || code == .insufficientEncryption {
                    fail(Esp32Error.pairingRefused.localizedDescription)
                } else {
                    fail("Subscribe failed: \(error.localizedDescription)")
                }
                return
            }
            guard characteristic.isNotifying else { return }
            beginHandshake()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            print("[ESP32] write failed: \(error)")
            finish(.failure(error))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        Task { @MainActor in
            guard let frame = Esp32Protocol.decode(Array(value)) else {
                print("[ESP32] dropped undecodable notify \(value.map { String(format: "%02X", $0) }.joined())")
                return
            }
            handle(frame)
        }
    }
}


private extension String {
    /// "jarvis-esp32-33da" → "Jarvis-ESP32-33DA": upper-case the MAC suffix only.
    func uppercasedSuffix() -> String {
        guard let dash = lastIndex(of: "-") else { return self }
        return String(self[...dash]) + self[index(after: dash)...].uppercased()
    }
}


/// Local iPhone notifications for `jarvis.notify` from a board script. Asks for
/// permission the first time a script needs it.
enum Esp32Notifier {
    static func post(title: String, body: String, boardName: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? "from \(boardName)" : body
        content.sound = .default
        content.threadIdentifier = "esp32.\(boardName)"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}


/// The app's record of the script it last installed on a board.
struct Esp32ScriptInfo: Codable, Equatable {
    var name: String
    var summary: String
    var source: String
    var installedAt: Date

    private static func key(_ id: String) -> String { "esp32ScriptInfo.\(id)" }

    static func load(for id: String) -> Esp32ScriptInfo? {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(Esp32ScriptInfo.self, from: data)
    }
    func save(for id: String) { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(id)) }
    static func clear(for id: String) { UserDefaults.standard.removeObject(forKey: key(id)) }

    /// Leading `--` comment lines, which is where Jarvis is told to describe the wiring
    /// and purpose; falls back to the first few lines of code.
    static func summary(of source: String) -> String {
        var lines: [String] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("--") {
                let text = line.drop(while: { $0 == "-" }).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { lines.append(text) }
                if lines.count >= 4 { break }
            } else if !lines.isEmpty {
                break
            }
        }
        if !lines.isEmpty { return lines.joined(separator: " ") }
        return source.split(whereSeparator: \.isNewline).prefix(3).joined(separator: "\n")
    }
}
