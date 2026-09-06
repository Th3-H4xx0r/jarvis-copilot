import Foundation
import Combine

/// App-lifetime owner of the Bluetooth wearables: the water bottle, the scale
/// and the ESP32 boards.
///
/// In the legacy JarvisWearables app these managers lived in `ScanView`, which
/// WAS the Devices tab and therefore existed for the life of the app. In the
/// Copilot shell `ScanView` is one segment of the Devices page and is only
/// built while that segment is selected — so the managers only existed while
/// the user was looking at the Wearables list, the bottle never reconnected
/// on its own, and its skills never reached the server ("start sterilisation"
/// fell through to Shortcuts). The hub restores the legacy behaviour: created
/// at launch, driven by the app's scene phase, reconnecting the known bottle
/// so its skills are registered whether or not any device screen is open.
@MainActor
final class WearablesHub: ObservableObject {
    static let shared = WearablesHub()

    let bottle = BottleManager()
    let scale = ScaleManager()
    let esp32 = Esp32Manager()

    private var reconnectTask: Task<Void, Never>?

    private init() {}

    /// Foreground: resume links, reconnect the remembered bottle, re-register.
    func appDidBecomeActive() {
        bottle.enterForeground()
        esp32.resumeIfNeeded()
        reconnectKnownDevices()
    }

    /// Background: the managers drop idle links (or hold them in bridge mode),
    /// exactly as the legacy `ScanView` did on `.background`.
    func appDidEnterBackground() {
        reconnectTask?.cancel()
        bottle.enterBackground()
    }

    /// Bring the last-used bottle back without anyone opening the Devices tab,
    /// so `bottle_*` skills are advertised to the server. Best effort and
    /// bounded: Bluetooth may be off, or the bottle out of range.
    func reconnectKnownDevices() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            // Give CoreBluetooth a moment to report its power state after launch.
            for _ in 0..<20 where !self.bottle.bluetoothReady {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard self.bottle.bluetoothReady, !Task.isCancelled else { return }
            if await self.bottle.ensureConnected(timeout: 15) == false {
                JcLog.services.notice("wearables: bottle not reachable at launch")
            }
            self.scale.startScan()
        }
    }

    /// The Devices tab's "Rescan".
    func rescanAll() {
        bottle.startScan()
        scale.startScan()
        esp32.startScan()
    }
}
