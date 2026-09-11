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
    /// Stable per-device keys. These are the wearables that have their own
    /// settings screen, which is where the toggle lives.
    static let bottle = "bottle"
    static let scale = "scale"
    static let esp32 = "esp32"
    static let ring = "ring"

    private static func key(_ device: String) -> String { "jc.keepAlive.\(device)" }

    /// Defaults to ON so an existing install behaves exactly as before.
    static func isOn(_ device: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(device)) as? Bool ?? true
    }

    static func set(_ on: Bool, for device: String, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key(device))
    }

    /// How long an on-demand link is held after the work finishes, so a burst
    /// of commands doesn't reconnect (and buzz) between each one.
    static let idleGraceSeconds: TimeInterval = 25
}

import SwiftUI

/// The "Connection Keep Alive" row, identical on every wearable's settings
/// screen. `onChange` lets a manager act immediately (drop a held link, or
/// bring one back) instead of waiting for the next event.
struct WearableKeepAliveToggle: View {
    let device: String
    var onChange: ((Bool) -> Void)? = nil
    @State private var isOn: Bool

    init(device: String, onChange: ((Bool) -> Void)? = nil) {
        self.device = device
        self.onChange = onChange
        _isOn = State(initialValue: WearableKeepAlive.isOn(device))
    }

    var body: some View {
        Toggle("Connection Keep Alive", isOn: $isOn)
            .onChange(of: isOn) { _, on in
                WearableKeepAlive.set(on, for: device)
                onChange?(on)
            }
    }

    static let footer = "On, the connection is held open and restored on its own, "
        + "so Jarvis can always reach this device. Off, it connects only when "
        + "something needs it — a command, an automation, or this screen — which "
        + "avoids the repeated reconnects and saves battery on both sides."
}
