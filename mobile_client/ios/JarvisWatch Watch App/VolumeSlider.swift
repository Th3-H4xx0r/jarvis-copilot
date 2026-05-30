import SwiftUI
import WatchKit

/// Bridges the WatchKit `WKInterfaceVolumeControl` (the only sanctioned way to
/// adjust the system volume on watchOS — it can't be set programmatically) into
/// SwiftUI. The user drags / crown-scrolls it once; the system volume persists.
struct VolumeSlider: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }
    func updateWKInterfaceObject(_ object: WKInterfaceVolumeControl, context: Context) {}
}
