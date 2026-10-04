import Foundation

/// Every CarPlay screen as a pure function of plain inputs. Nothing here reads a
/// store or touches CarPlay; `CarPlayCoordinator` snapshots the stores and
/// renders the result. Dashcam screens are in `CarPlayDashcamScreens.swift`.
///
/// Two tabs: Voice (talk to Jarvis) and Wearables (only device types that set
/// `WearableDevice.carEnabled` — the dashcam today).
@MainActor
enum CarPlayScreens {

    static let notPaired = [CarPlaySection(title: nil, rows: [
        CarPlayRow(id: "pair", title: "Pair Jarvis on your iPhone",
                   detail: "Open JarvisCopilot on the phone to sign in", symbol: "iphone"),
    ])]

    // MARK: Voice tab

    static func voiceTab(stateText: String) -> [CarPlaySection] {
        [CarPlaySection(title: nil, rows: [
            CarPlayRow(id: "talk", title: "Talk to Jarvis", detail: stateText, orb: true, action: .startVoice),
        ])]
    }

    // MARK: Wearables tab

    static func wearablesTab(_ devices: [CarPlayCarDevice]) -> [CarPlaySection] {
        guard !devices.isEmpty else {
            return [CarPlaySection(title: nil, rows: [
                CarPlayRow(id: "nodevices", title: "No car wearables yet",
                           detail: "Set up the dashcam on your iPhone and share it with Jarvis", symbol: "car"),
            ])]
        }
        return [CarPlaySection(title: nil, rows: devices.map { d in
            CarPlayRow(id: "car:\(d.id)", title: d.name, detail: d.status,
                       symbol: d.isDashcam ? "video" : "dot.radiowaves.left.and.right",
                       tint: d.connected ? .success : .muted,
                       action: .push(d.isDashcam ? .dashcam : .device(id: d.id)))
        })]
    }

    /// A car-enabled wearable with no screen of its own: whether it's reachable,
    /// then the plain values it reports (nested state is left to the phone).
    static func carDevice(name: String, connected: Bool, snapshot: [String: Any]) -> CarPlayInfo {
        var items = [CarPlayInfoItem(title: "Status", detail: connected ? "Connected" : "Not connected")]
        for (key, value) in snapshot.sorted(by: { $0.key < $1.key }) {
            let text: String
            switch value {
            case let b as Bool: text = b ? "Yes" : "No"
            case let n as NSNumber: text = n.stringValue
            case let s as String: text = s
            default: continue
            }
            items.append(CarPlayInfoItem(title: key.replacingOccurrences(of: "_", with: " ").capitalized, detail: text))
        }
        return CarPlayInfo(title: name, items: items)
    }
}
