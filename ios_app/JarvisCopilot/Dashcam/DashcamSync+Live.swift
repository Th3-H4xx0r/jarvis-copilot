import Foundation

/// While the live view is open the camera's Wi‑Fi and its little web server belong to the video
/// stream: sync passes (listings, playback mode, downloads) wait. `syncPass()` checks
/// `liveActive` first.
extension DashcamSync {
    /// Instances with a live view open (one in practice: `.shared`). Kept outside the class so this
    /// file needs no stored property in DashcamSync.
    private static var liveHolders = Set<ObjectIdentifier>()

    var liveActive: Bool { Self.liveHolders.contains(ObjectIdentifier(self)) }

    func pauseForLive(_ on: Bool) {
        if on {
            Self.liveHolders.insert(ObjectIdentifier(self))
        } else {
            Self.liveHolders.remove(ObjectIdentifier(self))
        }
    }
}
