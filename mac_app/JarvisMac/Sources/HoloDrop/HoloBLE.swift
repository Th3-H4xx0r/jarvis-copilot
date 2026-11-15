import CoreBluetooth
import Foundation

/// Holo Drop's Bluetooth beacon: while Holo Drop is on, the Mac advertises a fixed service and a
/// short name derived from its paired device id, so a phone's open popup can rank it by signal
/// strength ("nearest") without connecting. Nothing is served; it only advertises.
///
/// Name: "HD" + FNV-1a 32-bit of the paired device id's UTF-8, 8 lowercase hex digits — the
/// iPhone computes the same from `/devices` ids.
final class HoloBLEAdvertiser: NSObject, CBPeripheralManagerDelegate {
    static let service = CBUUID(string: "6F1D5A3E-9C2B-4E7A-8D11-3B6A2C9E0F42")

    private var manager: CBPeripheralManager?
    private var name: String?

    static func fnv1a(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }

    static func localName(deviceID: String) -> String { String(format: "HD%08x", fnv1a(deviceID)) }

    var advertising: Bool { manager?.isAdvertising ?? false }

    /// Start (or re-name) the advertisement. Bluetooth off: it starts when it comes on.
    func start(deviceID: String) {
        guard !deviceID.isEmpty else { return }
        let next = Self.localName(deviceID: deviceID)
        if next == name, manager != nil { return }
        name = next
        if let manager {
            manager.stopAdvertising()
            if manager.state == .poweredOn { advertise(manager) }
        } else {
            manager = CBPeripheralManager(delegate: self, queue: .main)
        }
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.delegate = nil
        manager = nil
        name = nil
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn { advertise(peripheral) }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { NSLog("Jarvis: Holo Drop Bluetooth beacon didn't start: \(error.localizedDescription)") }
    }

    private func advertise(_ peripheral: CBPeripheralManager) {
        guard let name else { return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service],
                                     CBAdvertisementDataLocalNameKey: name])
    }
}
