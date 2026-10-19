import Foundation

/// What a Jarvis button shows and does right now: "Stop arming · 0:45", "Disarm", "Unlock".
/// Worked out by the app (`ButtonStateResolver`) and drawn by the Control Center control, widget
/// buttons and the Lock Screen card. Compiled into the app and the widget extension.
struct ButtonLiveState: Codable, Hashable, Sendable {
    /// Stable id of the state, e.g. "door.arming", "car.locked".
    var id: String
    /// What a press does now.
    var title: String
    var symbol: String
    /// The line under it: "Away in", "Armed Away", "Locked".
    var caption: String?
    /// "#RRGGBB"; nil is the button's own tint.
    var tint: String?
    /// Going off: drawn red.
    var alert = false
    /// When the running thing started (for a progress bar) and when it ends (the countdown).
    var startedAt: Date?
    var endsAt: Date?
}

/// A button's states over time, so a tile drawn while the app sleeps still shows the right one:
/// "Stop arming" until the exit delay ends, then "Disarm".
struct ButtonTimeline: Codable, Hashable, Sendable {
    struct Segment: Codable, Hashable, Sendable {
        /// When this state starts; nil = from the start.
        var from: Date?
        var state: ButtonLiveState
    }

    /// Sorted by `from`; the first one's `from` is nil.
    var segments: [Segment]

    init(_ segments: [Segment]) {
        self.segments = segments.sorted { ($0.from ?? .distantPast) < ($1.from ?? .distantPast) }
    }

    init(_ state: ButtonLiveState) { self.init([Segment(from: nil, state: state)]) }

    /// The state showing at `date`: the last segment that has started.
    func state(at date: Date) -> ButtonLiveState? {
        segments.last { ($0.from ?? .distantPast) <= date }?.state ?? segments.first?.state
    }

    /// When the state next changes after `date`, if it will on its own.
    func nextChange(after date: Date) -> Date? {
        segments.compactMap(\.from).first { $0 > date }
    }
}
