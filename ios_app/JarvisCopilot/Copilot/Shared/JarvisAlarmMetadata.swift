import Foundation
#if canImport(AlarmKit)
import AlarmKit

/// The one type the app (which schedules) and the widget extension (which
/// renders the countdown) must agree on. Compiled into both targets, like
/// `JarvisActivityAttributes`.
@available(iOS 26.0, *)
struct JarvisAlarmMetadata: AlarmMetadata {
    /// What the user called it: "Alarm", "Timer", "Pasta".
    var label: String
    /// "alarm" | "timer" — picks the icon and wording in the Live Activity.
    var kind: String
}
#endif
