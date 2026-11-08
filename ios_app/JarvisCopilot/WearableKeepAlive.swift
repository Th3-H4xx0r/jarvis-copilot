import Foundation

/// Per-device "Connection Keep Alive".
///
/// ON (the default, and the historical behaviour): the app holds the BLE link
/// and brings it back on its own — at launch, on return to the foreground, and
/// whenever it drops. That keeps the device's skills registered with Jarvis at
/// all times, at the cost of a reconnect every time it wanders out of range.
///
/// OFF: nothing reconnects on its own. The link is opened only when something
/// actually needs it — a chat or voice command, an automation, a script, or
/// opening the device's screen — and dropped again once that work is done.
/// Fewer reconnects means no repeated buzz from the bottle, and less battery
/// burned on both sides.
enum WearableKeepAlive {
    /// Per-device keys (WearableKind holds the facts about each).
    static let bottle = WearableKind.bottle.rawValue
    static let scale = WearableKind.scale.rawValue
    static let esp32 = WearableKind.esp32.rawValue
    static let ring = WearableKind.ring.rawValue
    static let x5ring = WearableKind.x5ring.rawValue
    static let band = WearableKind.band.rawValue
    static let glasses = WearableKind.glasses.rawValue

    private static func key(_ device: String) -> String { "jc.keepAlive.\(device)" }

    /// The wearables with a "Connection Keep Alive" switch, by key, as a button or Jarvis names them.
    static let switchable: [(key: String, name: String)] =
        WearableKind.keepAliveSwitchable.map { ($0.rawValue, $0.keepAliveName ?? $0.rawValue) }

    /// Defaults to OFF, because holding a BLE link for a device nobody is using
    /// runs all day for the rare command that arrives — and with the background
    /// keepalive on, "all day" is literal. The on-demand path (`ensureConnected`)
    /// covers the same commands at the cost of a second or two of connect time,
    /// and ring gestures ride on it: off, they only arrive while something else has the ring up.
    ///
    /// Someone who toggled it on keeps it on: only an install that never touched
    /// the switch changes behaviour here.
    static func isOn(_ device: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(device)) as? Bool ?? false
    }

    static func set(_ on: Bool, for device: String, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key(device))
        NotificationCenter.default.post(name: .jcKeepAliveChanged, object: device)
    }

    /// How long an on-demand link is held after the work finishes, so a burst
    /// of commands doesn't reconnect (and buzz) between each one.
    static let idleGraceSeconds: TimeInterval = 25
}

import SwiftUI

/// The "Connection Keep Alive" row, identical on every wearable's settings screen. Flipping
/// it acts at once (WearablesHub.setKeepAlive): on brings the link back, off releases one
/// nothing is using.
struct WearableKeepAliveToggle: View {
    let device: String
    @State private var isOn: Bool

    init(device: String) {
        self.device = device
        _isOn = State(initialValue: WearableKeepAlive.isOn(device))
    }

    var body: some View {
        Toggle("Connection Keep Alive", isOn: $isOn)
            .onChange(of: isOn) { _, on in _ = WearablesHub.shared.setKeepAlive(on, for: device) }
    }

    static let footer = "On, the connection is held open and restored on its own, "
        + "so Jarvis can always reach this device. Off, it connects only when "
        + "something needs it — a command, an automation, or this screen — which "
        + "avoids the repeated reconnects and saves battery on both sides."
}

extension Notification.Name {
    /// A wearable's Keep Alive changed; `object` is its key.
    static let jcKeepAliveChanged = Notification.Name("jcKeepAliveChanged")
}

/// Per wearable: signal (buzz, light) when a strength rest runs out, for one that can. On
/// unless turned off.
enum WearableRestAlert {
    private static func key(_ kind: String) -> String { "restAlert.\(kind)" }

    static func isOn(_ kind: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(kind)) as? Bool ?? true
    }

    static func set(_ on: Bool, for kind: String, defaults: UserDefaults = .standard) {
        defaults.setValue(on, forKey: key(kind))
    }

    /// How long a buzz lasts, for a wearable whose signal has a length.
    static let defaultSeconds: Double = 6

    static func seconds(_ kind: String, defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: "\(key(kind)).seconds") as? Double ?? defaultSeconds
    }

    static func setSeconds(_ seconds: Double, for kind: String, defaults: UserDefaults = .standard) {
        defaults.setValue(seconds, forKey: "\(key(kind)).seconds")
    }
}
