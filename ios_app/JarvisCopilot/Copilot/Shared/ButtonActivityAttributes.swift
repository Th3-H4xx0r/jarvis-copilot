import ActivityKit
import Foundation

/// A Jarvis button's countdown on the Lock Screen and in the Dynamic Island: "Door alarm ·
/// Away in 0:45 · Stop arming". One per `source` (the door, the car, one button), started and
/// updated by the app (`ButtonActivityController`) and by the server's Live Activity pushes.
/// Shared by the app and the widget (which draws it, `ButtonActivityViews`).
///
/// Pushed content is decoded by ActivityKit with a default `JSONDecoder`: camelCase keys, and
/// dates as seconds since 2001-01-01 (`timeIntervalSinceReferenceDate`), not Unix time. `id`,
/// `title`, `symbol` and `alert` of the state and `finished` are required; the rest may be left out.
struct ButtonActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// What it shows now: the state's name, its countdown and what Stop does.
        var state: ButtonLiveState
        /// Done: the card shows `result` with a checkmark for a few seconds, then goes.
        var finished: Bool
        /// "Armed Away", "Arming cancelled".
        var result: String?
    }

    /// "door", "car" or "button.<id>": one activity each.
    var source: String
    /// The button Stop presses; "" for a card the server started (Stop then goes to the door alarm).
    var buttonID: String
    /// "Door alarm".
    var name: String
    var symbol: String
}
