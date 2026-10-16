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

    static let expandedHold: TimeInterval = 8
    static let compactHold: TimeInterval = 6

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

    /// You clicked somewhere else: fold to the pill, whatever kept it open.
    mutating func clickedOutside(at now: TimeInterval) {
        guard state == .expanded else { return }
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

/// Why the island opened. Only an open for typing (the chat shortcuts) takes the
/// keyboard: an agent asking for you never steals keys from the app you're in,
/// where a stray "y" could approve a command.
enum IslandOpenReason { case attention, activity, toggle, typing }

enum IslandFocus {
    static func takesKeyboard(_ reason: IslandOpenReason) -> Bool { reason == .typing }
}

/// A card that just slid into place under the pointer ignores clicks briefly,
/// so a double click on the one before can't answer it unread.
struct ArmGate {
    static let delay: TimeInterval = 0.5
    let shownAt: Date
    func isArmed(at now: Date) -> Bool { now.timeIntervalSince(shownAt) >= Self.delay }
}

/// When the pill over the notch stays up: while something needs you, while
/// agents work only if you asked for that, or always if you turned off hiding.
/// Otherwise the menu bar stays clear (a session that is merely working all day
/// would keep a black bar over it).
enum IslandVisibility {
    static func keepsPill(needsYou: Bool, working: Bool, showWhileWorking: Bool, alwaysShow: Bool) -> Bool {
        needsYou || (showWhileWorking && working) || alwaysShow
    }
}

/// What the open Agents tab measured: the part above the list (header, cards)
/// and the list's whole content.
struct IslandMeasure: Equatable {
    var top: CGFloat
    var list: CGFloat
}

/// How tall the open Agents island is: room for the tabs, the header, each
/// session row (with its step line) and what's waiting, never more than the
/// panel. Measured against IslandViews' paddings.
enum IslandLayout {
    enum Pending { case approval, question }
    static let rowHeight: CGFloat = 58
    /// The tab bar's height (IslandViews pins it, so the sums below are exact).
    static let tabsHeight: CGFloat = 26
    /// The voice stage's height (the panel's island layout, the island's width).
    static let voicePanelHeight: CGFloat = 190

    /// The Music tab's rows, each pinned by MusicPane: the cover with title and
    /// artist, the progress bar between its times, the controls.
    enum Music {
        static let artwork: CGFloat = 56
        static let progress: CGFloat = 16
        static let controls: CGFloat = 30
        static let gap: CGFloat = 12
    }

    /// Measured: as tall as what the Agents tab holds (its header and cards,
    /// then the list with an opened session's steps and diffs), up to the
    /// panel; past that the list scrolls.
    static func agentsHeight(topInset: CGFloat, top: CGFloat, list: CGFloat) -> CGFloat {
        min(topInset + tabsHeight + 10 + top + 10 + list + 14, IslandController.panelSize.height)
    }

    /// The slim scroll bar's thumb: the visible share of the list, moving with
    /// the scroll. Nil when everything fits.
    static func scrollThumb(content: CGFloat, visible: CGFloat, offset: CGFloat) -> (start: CGFloat, length: CGFloat)? {
        guard visible > 0, content > visible + 1 else { return nil }
        let length = max(24, visible * visible / content)
        let progress = min(max(offset / (content - visible), 0), 1)
        return ((visible - length) * progress, length)
    }

    /// The Voice view: the tab row, then the voice panel.
    static func voiceHeight(topInset: CGFloat) -> CGFloat {
        topInset + tabsHeight + 10 + voicePanelHeight + 14
    }

    /// The open Music tab is as tall as its rows, nothing more.
    static func musicHeight(topInset: CGFloat) -> CGFloat {
        topInset + tabsHeight + 10 + Music.artwork + Music.gap + Music.progress + Music.gap + Music.controls + 14
    }

    static func agentsHeight(topInset: CGFloat, sessions: Int, pending: Pending?, flash: Bool) -> CGFloat {
        var h = topInset + 34 + 10 + 40 + 10 + 14          // inset, tabs, gap, header, gap, bottom
        h += CGFloat(min(max(sessions, 1), 4)) * rowHeight
        switch pending {
        case .question: h += 240
        case .approval: h += 160
        case nil: break
        }
        if flash { h += 50 }
        return min(h, IslandController.panelSize.height)
    }
}

/// How often the island polls the pointer: quickly only close to it, a little
/// while it's open or the pointer is in the band around the panel, and once a
/// second otherwise (a mouse-moved monitor wakes it as the pointer comes near).
enum IslandTick {
    static let fast: TimeInterval = 1.0 / 60
    static let near: TimeInterval = 1.0 / 20
    static let idle: TimeInterval = 1.0

    static func interval(expanded: Bool, nearIsland: Bool, inBand: Bool) -> TimeInterval {
        nearIsland ? fast : (expanded || inBand) ? near : idle
    }
}

/// What keeps the open island from folding on its own: something you're
/// typing into, a request waiting on you, or the Voice view (by rule — panes
/// appear and disappear in an order that would clear a flag they share).
enum IslandPin {
    static func holds(pinned: Bool, tab: IslandTab, pending: Bool) -> Bool {
        pinned || pending || tab == .voice
    }
}

/// A limit window's pace and countdown: use minus the share of the window
/// already gone (above zero it runs ahead of the clock — a deficit; below, in
/// reserve), and when it resets.
enum UsagePace {
    static let fiveHours: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86_400

    static func pace(used: Int, resetsAt: Date, length: TimeInterval, now: Date) -> Double {
        let left = min(max(resetsAt.timeIntervalSince(now), 0), length)
        return Double(used) - (length - left) / length * 100
    }

    static func resetsIn(_ resetsAt: Date, now: Date) -> String {
        let s = Int(resetsAt.timeIntervalSince(now))
        guard s > 0 else { return "now" }
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) day\(d == 1 ? "" : "s")" + (h > 0 ? " \(h)h" : "") }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(1, m)) min"
    }
}

/// Where the orb sits in the open island, per tab: Voice's big orb on the
/// stage, the Agents header's, or the tab row's orb button.
enum OrbHome: Hashable {
    case voice, agents, row

    static func of(_ tab: IslandTab) -> OrbHome {
        switch tab {
        case .voice: return .voice
        case .agents: return .agents
        default: return .row
        }
    }
}

/// The notch's orb flying into the open island (out) and back into the notch
/// as it folds — only between those two, and not with Reduce Motion on.
enum OrbFlightPlan {
    enum Direction: Equatable { case out, back }

    static func direction(from: IslandStateMachine.State, to: IslandStateMachine.State,
                          reduceMotion: Bool) -> Direction? {
        guard !reduceMotion else { return nil }
        if from == .compact && to == .expanded { return .out }
        if from == .expanded && to == .compact { return .back }
        return nil
    }

    /// When the orb in its place takes over (each spring — IslandViews'
    /// `OrbFlightPlan.outSpring` / `backSpring` — has all but settled).
    static let outLanding: TimeInterval = 0.62
    static let backLanding: TimeInterval = 0.38
    /// How long an out flight waits for its home's first layout before it gives up.
    static let homeWait: TimeInterval = 0.4
}

/// The orb's path: it drops out of the notch, then glides into place — a
/// curve bent through the point under the ear at home's height — growing from
/// the ear's size to home's. `t` runs 0 (the ear) to 1 (home); the spring may
/// carry it a little past 1, which swells the orb but never moves it past home.
enum OrbPath {
    static func at(_ t: CGFloat, ear: CGRect, home: CGRect) -> (center: CGPoint, side: CGFloat) {
        let a = CGPoint(x: ear.midX, y: ear.midY), b = CGPoint(x: home.midX, y: home.midY)
        let s = min(max(t, 0), 1), u = 1 - s
        // Quadratic Bézier with its control point at (a.x, b.y).
        let x = u * u * a.x + 2 * u * s * a.x + s * s * b.x
        let y = u * u * a.y + 2 * u * s * b.y + s * s * b.y
        let side = ear.width + (home.width - ear.width) * t
        return (CGPoint(x: x, y: y), max(1, side))
    }

    /// The soft light it carries: none at either end, brightest mid-flight.
    static func glow(_ t: CGFloat) -> Double {
        Double(sin(.pi * min(max(t, 0), 1)))
    }
}
