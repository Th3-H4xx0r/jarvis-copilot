import AppKit
import Observation
import SwiftUI

/// The island stage's orb, for Jarvis.app's orb flight: the app flies the
/// notch's small orb into the stage and hands off to this one. While the flight
/// is in the air the stage holds its orb hidden (`hidden`), and it reports where
/// its orb sits — in SwiftUI's global space, which for this panel nested in the
/// app's window is the window's — so the flight lands exactly on it. Reached through `JarvisVoicePanel.setIslandOrbHidden(_:)` and the
/// `islandOrbFrameNotificationName` notification.
@MainActor
@Observable
final class MacIslandOrbLink {
    static let shared = MacIslandOrbLink()

    var hidden = false {
        didSet {
            guard hidden else { return }
            // Never stuck out of sight: a flight hands back well inside this.
            let token = UUID()
            failsafe = token
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                if let self, self.failsafe == token { self.hidden = false }
            }
        }
    }
    @ObservationIgnored private var failsafe: UUID?

    /// What the app listens for; `userInfo["frame"]` is an `NSValue` rect.
    nonisolated static let frameNotificationName = "JarvisVoicePanelIslandOrbFrame"

    /// Every time it lays out — a panel made for each opening reports afresh.
    func report(_ frame: CGRect) {
        NotificationCenter.default.post(name: Notification.Name(Self.frameNotificationName), object: nil,
                                        userInfo: ["frame": NSValue(rect: frame)])
    }
}
