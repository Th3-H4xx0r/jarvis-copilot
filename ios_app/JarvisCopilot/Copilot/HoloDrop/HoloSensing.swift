import CoreBluetooth
import Foundation
import UIKit

/// Where Holo Drop's devices are, while the app's popup is open: UWB for iPhones/iPads, the
/// Mac by ear (chirp) or by eye (camera + screen flash), any device by pointing at it, the nearest
/// by Bluetooth. Readings become bearings on the server (so the share sheet knows them too) and
/// stay until he locates the device again.
@MainActor
final class HoloSensing: ObservableObject {
    static let shared = HoloSensing()

    @Published private(set) var live: [String: HoloLiveReading] = [:]
    @Published private(set) var nearest: String?
    @Published private(set) var busy: String?          // "Listening for MacBook…"
    private var heading: () -> Double? = { nil }
    private var devices: [HoloDevice] = []
    private let ble = HoloBLE()

    /// This phone's paired id (the bridge's hello): what it advertises over Bluetooth.
    var myDeviceID: String? {
        get { UserDefaults.standard.string(forKey: "holoDrop.deviceID") }
        set { UserDefaults.standard.set(newValue, forKey: "holoDrop.deviceID") }
    }

    var client: HoloDropClient? { HoloDropReceiver.shared.client }

    // MARK: the popup

    func begin(devices: [HoloDevice], heading: @escaping () -> Double?) {
        self.devices = devices
        self.heading = heading
        live = [:]
        nearest = nil
        HoloNearby.shared.onReading = { [weak self] device, distance, azimuth in
            self?.uwb(device, distance: distance, azimuth: azimuth)
        }
        for d in devices where (d.kind == "iphone" || d.kind == "ipad") && d.online {
            HoloNearby.shared.reach(d.id) { [weak self] to, nonce, token in
                await self?.sendToken(to, nonce: nonce, token: token)
            }
        }
        ble.onRSSI = { [weak self] tag, rssi in self?.rssi(tag: tag, value: rssi) }
        ble.scan()
    }

    func end() {
        devices = []
        HoloNearby.shared.stop()
        HoloUltrasonic.shared.stop()
        HoloLook.shared.stop()
        ble.stopScan()
        busy = nil
    }

    func stopAll() {
        end()
        ble.stopAdvertising()
    }

    /// "Hear it": the Mac chirps, the phone listens — distance, and left/right with stereo mics.
    func hear(_ mac: HoloDevice) async -> String {
        busy = "Listening for \(mac.name)…"
        defer { busy = nil }
        let nonce = HoloBeaconCode.newNonce()
        let reading = await HoloUltrasonic.shared.listen(nonce: nonce) { [weak self] in
            await self?.client?.beacon(mac.id, mode: "chirp", nonce: nonce)
        }
        guard let reading else { return "Couldn't hear \(mac.name) — is its sound on?" }
        let deg = reading.offsetDeg.flatMap { off in heading().map { HoloOrbitLayout.normalized($0 + off) } }
        record(mac.id, HoloLiveReading(deg: deg, confidence: reading.confidence, distance: reading.distance,
                                       source: "ultrasonic"))
        return deg == nil ? String(format: "%@ is about %.0f m away", mac.name, reading.distance)
                          : "Heard \(mac.name)"
    }

    /// "I'm pointing at it": any device (the Pod, glasses, a Mac) is where the phone points now.
    func point(_ device: HoloDevice) -> String {
        guard let r = Self.pointReading(heading: heading(), distance: live[device.id]?.distance) else {
            return "No compass reading yet — move the phone a little and try again"
        }
        record(device.id, r)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return "Saved — \(device.name) is where you're pointing. It stays until you set it again."
    }

    nonisolated static func pointReading(heading: Double?, distance: Double?) -> HoloLiveReading? {
        guard let heading else { return nil }
        return HoloLiveReading(deg: HoloOrbitLayout.normalized(heading), confidence: 0.85, distance: distance, source: "set")
    }

    /// Forget a device's saved spot (until he sets it again or a throw teaches it).
    func forget(_ device: HoloDevice) async -> String {
        live[device.id] = nil
        _ = try? await client?.json("DELETE", "/bearings/\(device.id)")
        return "Forgot where \(device.name) is"
    }

    /// "Look at it": point the phone at the Mac; its screen flashes a code the camera finds.
    func look(_ mac: HoloDevice) async -> String {
        busy = "Point at \(mac.name)…"
        defer { busy = nil }
        let nonce = HoloBeaconCode.newNonce()
        let before = heading()
        let reading = await HoloLook.shared.look(nonce: nonce) { [weak self] in
            await self?.client?.beacon(mac.id, mode: "flash", nonce: nonce)
        }
        await client?.beacon(mac.id, mode: "stop", nonce: nonce)
        guard let reading, let h = before ?? heading() else { return "Couldn't see \(mac.name)'s screen" }
        record(mac.id, HoloLiveReading(deg: HoloOrbitLayout.normalized(h + reading.offsetDeg),
                                       confidence: reading.confidence, distance: live[mac.id]?.distance, source: "look"))
        return "Found \(mac.name)"
    }

    // MARK: bridge beacons (another phone's NI token)

    func beacon(_ msg: [String: Any]) {
        guard (msg["mode"] as? String) == "ni_token", let from = msg["from"] as? String,
              let token = msg["token"] as? String else { return }
        HoloNearby.shared.peerToken(from: from, token: token, nonce: msg["nonce"] as? String ?? "ni") { [weak self] to, nonce, token in
            await self?.sendToken(to, nonce: nonce, token: token)
        }
        // Measuring for another phone's popup: stop after a minute unless our own popup is open.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.devices.isEmpty else { return }
            HoloNearby.shared.stop()
        }
    }

    private func sendToken(_ device: String, nonce: String, token: String) async {
        await client?.beacon(device, mode: "ni_token", nonce: nonce, token: token)
    }

    // MARK: Bluetooth presence (foreground)

    func startAdvertising() {
        guard let id = myDeviceID else { return }
        ble.advertise(tag: HoloBLE.tag(id))
    }

    func stopAdvertising() { ble.stopAdvertising() }

    // MARK: readings

    private func uwb(_ device: String, distance: Double?, azimuth: Double?) {
        let deg = azimuth.flatMap { a in heading().map { HoloOrbitLayout.normalized($0 + a) } }
        live[device] = HoloLiveReading(deg: deg, confidence: deg == nil ? 0 : 0.9, distance: distance, source: "uwb")
    }

    private func rssi(tag: String, value: Int) {
        guard value > -85, value < 0,
              let d = devices.first(where: { HoloBLE.tag($0.id) == tag }) else { return }
        ble.seen[d.id] = value
        nearest = ble.seen.max { $0.value < $1.value }?.key
    }

    /// Only a reading with a direction becomes a remembered bearing (a distance alone would land at 0°).
    nonisolated static func remembers(_ r: HoloLiveReading) -> Bool { r.deg != nil }

    private func record(_ device: String, _ r: HoloLiveReading) {
        live[device] = r
        guard Self.remembers(r) else { return }
        var row: [String: Any] = ["device": device, "confidence": r.confidence, "source": r.source,
                                  "at": Date().timeIntervalSince1970]
        if let deg = r.deg { row["deg"] = deg }
        if let m = r.distance { row["distance_m"] = m }
        Task { await client?.postBearings([row]) }
    }
}

/// Bluetooth presence: each Jarvis device advertises Holo Drop's service with a short tag of its
/// id while its app is open; the popup ranks them by signal strength to highlight the nearest.
final class HoloBLE: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate {
    /// The same UUID the Mac app advertises.
    static let service = CBUUID(string: "6F1D5A3E-9C2B-4E7A-8D11-3B6A2C9E0F42")

    var onRSSI: (String, Int) -> Void = { _, _ in }
    var seen: [String: Int] = [:]
    private var peripheral: CBPeripheralManager?
    private var central: CBCentralManager?
    private var tag: String?
    private var wantScan = false

    /// "HD" + FNV-1a of the device id: unique enough among his devices, says nothing about him.
    static func tag(_ deviceID: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in deviceID.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(format: "HD%08x", h)
    }

    func advertise(tag: String) {
        self.tag = tag
        if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: .main) } else { startAdvertising() }
    }

    func stopAdvertising() {
        peripheral?.stopAdvertising()
        tag = nil
    }

    func scan() {
        wantScan = true
        seen = [:]
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) } else { startScan() }
    }

    func stopScan() {
        wantScan = false
        central?.stopScan()
    }

    private func startAdvertising() {
        guard let tag, let p = peripheral, p.state == .poweredOn else { return }
        p.stopAdvertising()
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service], CBAdvertisementDataLocalNameKey: tag])
    }

    private func startScan() {
        guard wantScan, let c = central, c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { startAdvertising() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { startScan() }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String, name.hasPrefix("HD") else { return }
        onRSSI(name, RSSI.intValue)
    }
}

/// Holo Drop's temp files (downloads, direct receives, picked photos/videos, screenshots).
enum HoloTemp {
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("HoloDrop", isDirectory: true) }

    /// Remove entries older than `age` (videos of several GB must not pile up).
    static func sweep(_ dir: URL = HoloTemp.root, olderThan age: TimeInterval = 86400, now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in items {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(date) > age { try? fm.removeItem(at: url) }
        }
    }
}
