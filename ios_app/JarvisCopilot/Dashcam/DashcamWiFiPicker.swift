import AccessorySetupKit
import Foundation
import UIKit

/// Camera networks the phone has used, and the name prefixes learned from them — so the
/// accessory picker matches *this* camera exactly from the second time on.
enum DashcamKnownNetworks {
    static let ssidsKey = "jc.dashcam.knownSSIDs"
    static let prefixesKey = "jc.dashcam.learnedSSIDPrefixes"

    /// Dashcam Wi‑Fi name prefixes. The A4 calls itself `Peztio-A4_<6 hex>` (seen in the Peztio app's
    /// listing photo); the rest are common dashcam names, until the camera's real name is learned.
    static let commonPrefixes = ["Peztio-A4_", "Peztio-", "Affver", "AFFVER", "PEZTIO", "Peztio", "A4_", "A4-", "Viidure", "VIIDURE",
                                 "DashCam", "Dashcam", "DASHCAM", "CARDV", "NVT_", "4K_", "WiFi_Cam"]

    static func ssids(_ d: UserDefaults = .standard) -> [String] { d.stringArray(forKey: ssidsKey) ?? [] }
    static func prefixes(_ d: UserDefaults = .standard) -> [String] { d.stringArray(forKey: prefixesKey) ?? [] }

    static func learn(ssid: String, defaults d: UserDefaults = .standard) {
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        d.set([name] + ssids(d).filter { $0 != name }, forKey: ssidsKey)
        if let p = prefix(of: name), !prefixes(d).contains(p) { d.set(prefixes(d) + [p], forKey: prefixesKey) }
    }

    /// "Affver_A4_9F2C" → "Affver_A4_", "PEZTIO-1A2B3C" → "PEZTIO-": the name minus its trailing
    /// per-unit id (hex/digits after the last separator). Nil when there is no such tail.
    static func prefix(of ssid: String) -> String? {
        guard let sep = ssid.lastIndex(where: { $0 == "_" || $0 == "-" || $0 == " " }) else { return nil }
        let tail = ssid[ssid.index(after: sep)...]
        guard !tail.isEmpty, tail.allSatisfy({ $0.isHexDigit }) else { return nil }
        let head = String(ssid[...sep])
        return head.count >= 2 ? head : nil
    }
}

/// Apple's accessory picker for the camera's Wi‑Fi: a system sheet that keeps scanning and lists
/// nearby networks matching known dashcam names (iOS doesn't let apps list Wi‑Fi themselves).
@available(iOS 18.0, *)
@MainActor
final class DashcamAccessoryPicker {
    private let session = ASAccessorySession()
    private var activated = false
    private var continuation: CheckedContinuation<String?, Never>?
    private var picked: String?

    /// Shows the picker; returns the chosen network's name, or nil when dismissed or unavailable.
    func pick() async -> String? {
        if !activated {
            session.activate(on: .main) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            activated = true
        }
        picked = nil
        return await withCheckedContinuation { cont in
            continuation = cont
            session.showPicker(for: Self.items()) { [weak self] error in
                guard error != nil else { return }
                MainActor.assumeIsolated { self?.finish(nil) }
            }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .accessoryAdded, .accessoryChanged:
            if let ssid = event.accessory?.ssid { picked = ssid }
        case .pickerDidDismiss:
            finish(picked)
        default:
            break
        }
    }

    private func finish(_ value: String?) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    /// One picker entry per exact known network and per prefix (learned first, then the common ones).
    static func items(defaults: UserDefaults = .standard) -> [ASPickerDisplayItem] {
        let image = UIImage(systemName: "video.fill") ?? UIImage()
        var out: [ASPickerDisplayItem] = []
        for ssid in DashcamKnownNetworks.ssids(defaults) {
            let d = ASDiscoveryDescriptor()
            d.ssid = ssid
            out.append(ASPickerDisplayItem(name: ssid, productImage: image, descriptor: d))
        }
        var seen = Set<String>()
        for prefix in DashcamKnownNetworks.prefixes(defaults) + DashcamKnownNetworks.commonPrefixes where seen.insert(prefix).inserted {
            let d = ASDiscoveryDescriptor()
            d.ssidPrefix = prefix
            out.append(ASPickerDisplayItem(name: "Dashcam", productImage: image, descriptor: d))
        }
        return out
    }
}
