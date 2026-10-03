import ActivityKit
import Foundation

/// The dashcam syncing, on the Lock Screen and in the Dynamic Island — its own activity, apart from
/// JARVIS's. It exists only while clips come off the dashcam or go up to the cloud.
struct DashcamSyncAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Camera → phone: the clip coming down and how far (0…1); "" = nothing downloading.
        var downloadName: String = ""
        var downloadFraction: Double = 0
        var toDownload: Int = 0
        /// Phone → cloud: how far the clip going up is (0…1) and how many wait; uploading=false = none.
        var uploading: Bool = false
        var uploadFraction: Double = 0
        var toUpload: Int = 0
    }

    /// "HUAXIN A4".
    var cameraName: String

    /// Clamped before it goes on the wire: the ~4 KB ContentState budget fails silently.
    static let maxTextChars = 48
}
