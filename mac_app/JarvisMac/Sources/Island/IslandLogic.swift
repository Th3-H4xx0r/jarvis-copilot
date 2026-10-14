import Foundation

/// The resting island's size: the physical notch when the screen has one, a
/// small black bar under the menu bar when it doesn't. After coucou's
/// IslandScreenGeometry (github.com/Louis-CFM/coucou, MIT).
struct IslandGeometry: Equatable {
    static let fallbackNotchWidth: CGFloat = 184
    private static let noNotchWidth: CGFloat = 80
    private static let noNotchHeight: CGFloat = 24

    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    init(screenWidth: CGFloat, safeAreaTop: CGFloat,
         auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?, menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
                let measured = screenWidth - left - right
                width = measured > 0 && measured < screenWidth ? measured : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = min(Self.noNotchHeight, menuBarHeight)
        }
    }
}

/// Which screen the island lives on.
enum IslandDisplayChoice: Equatable {
    case notch          // the built-in screen with a notch, else the main screen
    case menuBar        // the screen with the menu bar
    case followMouse    // whichever screen the pointer is on (moves only while closed)
    case display(String)  // one display, by its stable UUID

    init(rawValue: String) {
        switch rawValue {
        case "menuBar": self = .menuBar
        case "followMouse": self = .followMouse
        default:
            if rawValue.hasPrefix("display:"), rawValue.count > 8 {
                self = .display(String(rawValue.dropFirst(8)))
            } else {
                self = .notch
            }
        }
    }

    var rawValue: String {
        switch self {
        case .notch: return "notch"
        case .menuBar: return "menuBar"
        case .followMouse: return "followMouse"
        case .display(let id): return "display:\(id)"
        }
    }
}

/// When the island is hidden, compact (the pill around the notch) or expanded.
/// Pure: the controller calls ``tick`` with the time and what the pointer does.
/// Timings after coucou's IslandStateMachine: an expanded island folds back
/// after 15 s untouched, a compact one hides after 60 s once nothing runs.
struct IslandStateMachine: Equatable {
    enum State: Equatable { case hidden, compact, expanded }

    static let expandedHold: TimeInterval = 15
    static let compactHold: TimeInterval = 60

    private(set) var state: State = .hidden
    private var since: TimeInterval = 0

    /// Something needs you (approval, question, finished, error): open.
    mutating func attention(at now: TimeInterval) {
        state = .expanded
        since = now
    }

    /// A session started or is running: at least the compact pill.
    mutating func activity(at now: TimeInterval) {
        if state == .hidden {
            state = .compact
            since = now
        }
    }

    /// A click on the pill, or the toggle shortcut.
    mutating func toggle(at now: TimeInterval) {
        state = state == .expanded ? .compact : .expanded
        since = now
    }

    mutating func close(at now: TimeInterval) {
        state = .compact
        since = now
    }

    mutating func tick(now: TimeInterval, hovering: Bool, pinned: Bool, hasSessions: Bool) {
        switch state {
        case .expanded:
            if hovering || pinned {
                since = now
            } else if now - since > Self.expandedHold {
                state = .compact
                since = now
            }
        case .compact:
            if hovering || hasSessions {
                since = now
            } else if now - since > Self.compactHold {
                state = .hidden
                since = now
            }
        case .hidden:
            if hasSessions {
                state = .compact
                since = now
            }
        }
    }
}
