import Foundation

/// His own states for a button: it follows a live value (anything a widget can show) and each rule
/// says what the button shows and does while the value matches. The first matching rule wins.
struct ButtonStates: Codable, Equatable {
    var follows: String
    var rules: [Rule]
    /// A live value holding an end time (seconds since 1970, or ISO 8601) to count down to.
    var countdownKey: String?

    struct Rule: Codable, Equatable {
        var when: Match
        var title: String
        var symbol: String
        var action: RingAction
    }

    enum Match: Codable, Equatable {
        case equals(String)
        case on
        case off
        case otherwise
    }
}

/// The car as the buttons know it: what it last reported, or what Jarvis last told it to do.
struct CarLive: Equatable {
    var locked: Bool?
    var running: Bool?
    var startedAt: Date?
}

/// Everything a button's state can depend on, gathered by `LiveButtons`.
struct LiveValues {
    var door: DoorAlarmInfo?
    var car: CarLive?
    /// The widget data hub's values (`door.state`, `bottle.status`, …) for his own states.
    var values: [String: JCJSON] = [:]
    /// Whether a wearable's switch is on, from what the device reports; nil when it doesn't say.
    var wearableOn: (_ deviceID: String, _ skill: String) -> Bool? = { _, _ in nil }
    /// What each button last switched a wearable to, for devices that don't report it.
    var lastSet: [String: (on: Bool, at: Date)] = [:]
}

/// One state of a button over time, with the action a press runs while it shows.
struct ResolvedState {
    var from: Date?
    var state: ButtonLiveState
    var action: RingAction
}

/// Works out what a button shows and does: the door alarm, the car and wearable switches are
/// followed automatically; any button can have his own states; anything else has none.
enum ButtonStateResolver {
    /// A remote start runs about this long; the car doesn't report it.
    static let remoteStartRun: TimeInterval = 10 * 60
    /// How long a wearable switch a button set is trusted when the device doesn't report it.
    static let optimisticFor: TimeInterval = 6 * 60 * 60

    /// The button's states over time, or nil for a button without states.
    static func resolve(_ button: ControlButton, live: LiveValues, now: Date) -> [ResolvedState]? {
        if let states = button.states { return custom(states, button: button, live: live) }
        guard button.followsLive, !button.keepsState else { return nil }
        switch button.action {
        case .door(let command, let skip):
            return live.door.map { door(command, skip: skip, alarm: $0, button: button) }
        case .car(let command, let skip):
            return live.car.flatMap { car(command, skip: skip, car: $0, now: now) }
        case .wearable(let deviceID, let skill, let arguments):
            return wearable(deviceID: deviceID, skill: skill, arguments: arguments, button: button, live: live, now: now)
        default:
            return nil
        }
    }

    static func timeline(_ button: ControlButton, live: LiveValues, now: Date) -> ButtonTimeline? {
        resolve(button, live: live, now: now).map { ButtonTimeline($0.map { .init(from: $0.from, state: $0.state) }) }
    }

    /// What a press runs now. A press that saw a state the button has moved on from is refused —
    /// returned as `.changed(now)` — so a stale "Stop arming" never becomes a disarm.
    enum Press { case run(RingAction), changed(ButtonLiveState) }

    static func press(_ button: ControlButton, shownState: String?, live: LiveValues, now: Date) -> Press {
        guard let states = resolve(button, live: live, now: now), !states.isEmpty else {
            // The tile showed a state the button no longer has (states turned off, a guess that
            // expired): don't guess what he meant.
            if let shownState, shownState != ownStateID { return .changed(own(button)) }
            return .run(button.action)
        }
        let current = states.last { ($0.from ?? .distantPast) <= now } ?? states[0]
        guard let shownState else {
            // No state on the tile (a new button, one drawn before the app knew): only the button's
            // own action may run — an "Arm Away" tile must never disarm.
            return current.action == button.action ? .run(button.action) : .changed(current.state)
        }
        if shownState != current.state.id { return .changed(current.state) }
        return .run(current.action)
    }

    /// The state a button shows when it follows nothing right now: its own name and action.
    static let ownStateID = "own"

    static func own(_ button: ControlButton) -> ButtonLiveState {
        ButtonLiveState(id: ownStateID, title: button.name.isEmpty ? "Jarvis button" : button.name, symbol: button.symbol)
    }

    // MARK: the door alarm

    private static func door(_ command: DoorButtonCommand, skip: Bool, alarm: DoorAlarmInfo,
                             button: ControlButton) -> [ResolvedState] {
        let disarm = RingAction.door(.disarm, skipFaceID: skip)
        let armed = { (mode: String?) in
            ButtonLiveState(id: "door.armed_\(mode ?? "away")", title: "Disarm", symbol: "lock.open.fill",
                            caption: mode == "home" ? "Armed Home" : "Armed Away")
        }
        switch alarm.state {
        case "arming" where command == .armNow:
            // Arm now finishes the exit delay early; it's the one door button that doesn't stop it.
            var now = ButtonLiveState(id: "door.arming", title: "Arm now", symbol: "bolt.shield.fill",
                                      caption: alarm.mode == "home" ? "Home in" : "Away in")
            now.startedAt = alarm.since
            now.endsAt = alarm.deadline
            var out = [ResolvedState(from: nil, state: now, action: .door(.armNow))]
            if let deadline = alarm.deadline {
                out.append(ResolvedState(from: deadline, state: armed(alarm.mode), action: disarm))
            }
            return out
        case "arming":
            var stop = ButtonLiveState(id: "door.arming", title: "Stop arming", symbol: "stop.circle.fill",
                                       caption: alarm.mode == "home" ? "Home in" : "Away in")
            stop.startedAt = alarm.since
            stop.endsAt = alarm.deadline
            var out = [ResolvedState(from: nil, state: stop, action: .door(.cancelArming))]
            if let deadline = alarm.deadline {
                out.append(ResolvedState(from: deadline, state: armed(alarm.mode), action: disarm))
            }
            return out
        case "armed_away", "armed_home":
            return [ResolvedState(from: nil, state: armed(alarm.state == "armed_home" ? "home" : "away"), action: disarm)]
        case "entry":
            var entry = ButtonLiveState(id: "door.entry", title: "Disarm", symbol: "lock.open.fill",
                                        caption: "\(alarm.contactName ?? "A door") opened", alert: true)
            entry.startedAt = alarm.since
            entry.endsAt = alarm.deadline
            var out = [ResolvedState(from: nil, state: entry, action: disarm)]
            if let deadline = alarm.deadline {
                out.append(ResolvedState(from: deadline, state: going(siren: true), action: .door(.silence, skipFaceID: skip)))
            }
            return out
        case "triggered":
            return [ResolvedState(from: nil, state: going(siren: alarm.sirenOn),
                                  action: alarm.sirenOn ? .door(.silence, skipFaceID: skip) : disarm)]
        default:
            // Disarmed: an Arm button arms; any other door button only says so.
            switch command {
            case .armHome, .armAway:
                return [ResolvedState(from: nil, state: ButtonLiveState(id: "door.disarmed", title: command.title,
                                                                         symbol: "shield.lefthalf.filled",
                                                                         caption: "Disarmed"),
                                      action: button.action)]
            default:
                return [ResolvedState(from: nil, state: ButtonLiveState(id: "door.disarmed", title: "Disarmed",
                                                                         symbol: "shield.slash", caption: nil),
                                      action: .door(.status))]
            }
        }
    }

    private static func going(siren: Bool) -> ButtonLiveState {
        ButtonLiveState(id: siren ? "door.siren" : "door.triggered", title: siren ? "Silence" : "Disarm",
                        symbol: siren ? "speaker.slash.fill" : "lock.open.fill", caption: "Alarm going off",
                        alert: true)
    }

    // MARK: the car

    private static func car(_ command: String, skip: Bool, car: CarLive, now: Date) -> [ResolvedState]? {
        switch command {
        case "lock", "unlock":
            guard let locked = car.locked else { return nil }
            return [locked
                ? ResolvedState(from: nil, state: ButtonLiveState(id: "car.locked", title: "Unlock", symbol: "lock.open.fill",
                                                                   caption: "Locked"),
                                action: .car(command: "unlock", skipFaceID: skip))
                : ResolvedState(from: nil, state: ButtonLiveState(id: "car.unlocked", title: "Lock", symbol: "lock.fill",
                                                                   caption: "Unlocked"),
                                action: .car(command: "lock", skipFaceID: skip))]
        case "start", "stop":
            guard let running = car.running else { return nil }
            guard running else {
                return [ResolvedState(from: nil, state: ButtonLiveState(id: "car.off", title: "Start", symbol: "power",
                                                                         caption: "Engine off"),
                                      action: .car(command: "start", skipFaceID: skip))]
            }
            var on = ButtonLiveState(id: "car.running", title: "Stop engine", symbol: "power", caption: "Running")
            if let started = car.startedAt, started.addingTimeInterval(remoteStartRun) > now {
                on.startedAt = started
                on.endsAt = started.addingTimeInterval(remoteStartRun)
            }
            return [ResolvedState(from: nil, state: on, action: .car(command: "stop"))]
        default:
            return nil
        }
    }

    // MARK: wearable switches

    private static func wearable(deviceID: String, skill: String, arguments: [String: String], button: ControlButton,
                                 live: LiveValues, now: Date) -> [ResolvedState]? {
        guard let key = WearableQuickActions.switchKeys.first(where: { arguments[$0] != nil }) else { return nil }
        let known = live.wearableOn(deviceID, skill)
        let guess = live.lastSet[button.id].flatMap { now.timeIntervalSince($0.at) < optimisticFor ? $0 : nil }
        guard let isOn = known ?? guess?.on else { return nil }
        let names = WearableQuickActions.names(for: skill)
        var turned = arguments
        turned[key] = isOn ? "false" : "true"
        if !isOn, arguments["confirm"] != nil { turned["confirm"] = "true" }
        let state = ButtonLiveState(id: "\(skill).\(isOn ? "on" : "off")", title: isOn ? names.off : names.on,
                                    symbol: isOn ? "stop.circle.fill" : button.symbol, caption: isOn ? "On" : "Off")
        var out = [ResolvedState(from: nil, state: state,
                                 action: .wearable(deviceID: deviceID, skill: skill, arguments: turned))]
        // Only a guess (the device doesn't say): after a while the tile goes back to the button itself.
        if known == nil, let guess {
            out.append(ResolvedState(from: guess.at.addingTimeInterval(optimisticFor), state: own(button),
                                     action: button.action))
        }
        return out
    }

    // MARK: his own states

    private static func custom(_ states: ButtonStates, button: ControlButton, live: LiveValues) -> [ResolvedState]? {
        let value = live.values[states.follows]
        guard let index = states.rules.firstIndex(where: { matches($0.when, value) }) else { return nil }
        let rule = states.rules[index]
        // The rule's title is part of the id: reordering rules must not make an old tile's id match
        // a different rule.
        var state = ButtonLiveState(id: "custom.\(index).\(rule.title)", title: rule.title, symbol: rule.symbol,
                                    caption: value?.asString)
        if let key = states.countdownKey, let end = date(live.values[key]) { state.endsAt = end }
        return [ResolvedState(from: nil, state: state, action: rule.action)]
    }

    static func matches(_ match: ButtonStates.Match, _ value: JCJSON?) -> Bool {
        switch match {
        case .otherwise: return true
        case .equals(let text): return value?.asString?.lowercased() == text.lowercased()
        case .on: return truthy(value) == true
        case .off: return truthy(value) == false
        }
    }

    private static func truthy(_ value: JCJSON?) -> Bool? {
        switch value {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0
        case .string(let s)?:
            switch s.lowercased() {
            case "on", "true", "yes", "1", "running", "armed", "open": return true
            case "off", "false", "no", "0", "stopped", "disarmed", "closed", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func date(_ value: JCJSON?) -> Date? {
        if let seconds = value?.asDouble, seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
        if let text = value?.asString { return ISO8601DateFormatter().date(from: text) }
        return nil
    }
}
