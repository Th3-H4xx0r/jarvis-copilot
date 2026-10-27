import SwiftUI

/// The one answer to "are the glasses connected?", for the Devices card, the page's hero and
/// the model's lens glow. The GO3 has two links: the control link (INMO's Bluetooth service —
/// lens, touchpad, camera, battery) and the plain Bluetooth audio route iOS reports. The control
/// link is what makes the glasses do anything, so it decides "Connected"; audio alone is said so.
enum GlassesConnectionStatus: Equatable {
    case connected, connecting, setupNeeded, audioOnly, offline

    static func of(control: InmoConnectionState, audio: Bool) -> Self {
        switch control {
        case .ready: return .connected
        case .discovering, .connecting, .discoveringServices, .subscribing, .authenticating: return .connecting
        case .setupRequired: return .setupNeeded
        case .idle, .unavailable, .failed, .disconnected: return audio ? .audioOnly : .offline
        }
    }

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .setupNeeded: return "Finish setup"
        case .audioOnly: return "Audio only"
        case .offline: return "Not connected"
        }
    }

    var symbol: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .setupNeeded: return "key.fill"
        case .audioOnly: return "headphones"
        case .offline: return "circle.slash"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return JcTheme.success
        case .connecting: return JcTheme.accent
        case .setupNeeded: return JcTheme.amber
        case .audioOnly, .offline: return JcTheme.muted
        }
    }

    /// The lens glows once the glasses would show something.
    var lit: Bool { self == .connected }
}
