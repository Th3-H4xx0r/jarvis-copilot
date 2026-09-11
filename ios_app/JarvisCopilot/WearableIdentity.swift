import Foundation

/// The id a wearable is known by while its Bluetooth link is down.
///
/// Every `WearableDevice.deviceID` is derived from live state — the bottle's MAC,
/// or the CoreBluetooth identifier of the peripheral we're connected to. That is
/// fine while connected and useless when not: `VsitooS1Pro.deviceID` fell back to
/// the literal string "unpaired", so a device registered while offline would take
/// a placeholder identity, not match the user's shared-devices record, and then
/// register a SECOND time under its real id once the link came up.
///
/// So we remember the last real id each manager saw and hand it back as the
/// fallback. The identity is then stable across a drop, which is what lets the
/// catalogue stay registered while the device is out of range.
enum WearableIdentity {
    /// Ids that mean "we don't actually know yet". Never remembered.
    private static let placeholders: Set<String> = ["unpaired", "esf551", "esp32", "ring", "unknown", ""]

    private static func key(_ device: String) -> String { "jc.deviceID.\(device)" }

    static func remembered(_ device: String, defaults: UserDefaults = .standard) -> String? {
        guard let id = defaults.string(forKey: key(device)), !placeholders.contains(id) else { return nil }
        return id
    }

    static func remember(_ id: String, for device: String, defaults: UserDefaults = .standard) {
        guard !placeholders.contains(id) else { return }
        defaults.set(id, forKey: key(device))
    }

    // MARK: Last seen

    /// Recorded every time a scan turns the device up, so a card that is currently
    /// out of range can still say how strong it was and when — rather than vanishing
    /// from the list, which is what it used to do.
    static func noteSeen(_ device: String, rssi: Int, defaults: UserDefaults = .standard) {
        defaults.set(rssi, forKey: "jc.lastRSSI.\(device)")
        defaults.set(Date().timeIntervalSince1970, forKey: "jc.lastSeen.\(device)")
    }

    static func lastRSSI(_ device: String, defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: "jc.lastRSSI.\(device)") as? Int
    }

    static func lastSeen(_ device: String, defaults: UserDefaults = .standard) -> Date? {
        guard let t = defaults.object(forKey: "jc.lastSeen.\(device)") as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func forget(_ device: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(device))
    }

    /// Existing installs shared a device long before we started recording its id,
    /// so seed from `BridgeClient.sharedRecords` (`[deviceID: model]`) by model.
    /// Without this an upgrade would show no wearables until each one reconnected
    /// once — exactly the bug we're fixing.
    static func seedFromSharedRecords(_ records: [String: String], defaults: UserDefaults = .standard) {
        let byModel: [String: String] = [
            VsitooS1Pro.model: WearableKeepAlive.bottle,
            Esf551Scale.model: WearableKeepAlive.scale,
            Esp32Board.model: WearableKeepAlive.esp32,
            ColmiR12.model: WearableKeepAlive.ring,
        ]
        for (deviceID, model) in records {
            guard let kind = byModel[model], remembered(kind, defaults: defaults) == nil else { continue }
            remember(deviceID, for: kind, defaults: defaults)
        }
    }
}
