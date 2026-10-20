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
    /// What a wearable's command is doing now, as the device reports it; nil when it can't tell.
    var wearableState: (_ deviceID: String, _ skill: String, _ arguments: [String: String]) -> CommandLiveState? = {
        _, _, _ in nil
    }
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

    /// The button's states over time, or nil for a button without states — with his own icons.
    static func resolve(_ button: ControlButton, live: LiveValues, now: Date) -> [ResolvedState]? {
        guard var states = automatic(button, live: live, now: now) else { return nil }
        for index in states.indices {
            if let symbol = button.stateSymbols[states[index].state.id] { states[index].state.symbol = symbol }
        }
        return states
    }

    /// Every state a button can show, for choosing their icons: the door's, the car's, a
    /// wearable's sides — worked out the same way the live ones are. Empty for his own states
    /// (each rule has its icon) and for buttons that follow nothing.
    static func possibleStates(_ button: ControlButton, reported: CommandLiveState? = nil) -> [ButtonLiveState] {
        guard button.states == nil else { return [] }
        let at = Date()
        var scenarios: [LiveValues] = []
        switch button.action {
        case .door:
            scenarios = [["state": "disarmed"], ["state": "arming", "mode": "away", "deadline": at.timeIntervalSince1970 + 60],
                         ["state": "armed_away"], ["state": "armed_home"],
                         ["state": "entry", "deadline": at.timeIntervalSince1970 + 30],
                         ["state": "triggered", "siren_on": true], ["state": "triggered", "siren_on": false]]
                .map { LiveValues(door: DoorAlarmInfo(json: $0)) }
        case .car:
            scenarios = [CarLive(locked: true), CarLive(locked: false), CarLive(running: true), CarLive(running: false)]
                .map { LiveValues(car: $0) }
        case .wearable:
            // What the device really reports decides the states: on/off, or a mode — not both.
            let shapes: [CommandLiveState]
            if let reported, reported.on != nil {
                shapes = [CommandLiveState(on: true, mode: reported.mode), CommandLiveState(on: false)]
            } else if reported?.mode != nil {
                shapes = [CommandLiveState(mode: reported?.mode)]
            } else {
                shapes = [CommandLiveState(on: true), CommandLiveState(on: false), CommandLiveState(mode: "…")]
            }
            scenarios = shapes.map { state in
                var live = LiveValues()
                live.wearableState = { _, _, _ in state }
                return live
            }
        default:
            return []
        }
        var seen: Set<String> = []
        var out: [ButtonLiveState] = []
        var plain = button
        plain.stateSymbols = [:]
        for live in scenarios {
            for resolved in automatic(plain, live: live, now: at) ?? [] where seen.insert(resolved.state.id).inserted {
                out.append(resolved.state)
            }
        }
        return out
    }

    private static func automatic(_ button: ControlButton, live: LiveValues, now: Date) -> [ResolvedState]? {
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
        // A wearable command that isn't an on/off switch only ever runs itself; its state is just
        // what the tile says. Nothing to refuse.
        if case .wearable(_, _, let arguments) = button.action,
           !WearableQuickActions.switchKeys.contains(where: { arguments[$0] != nil }) {
            return .run(button.action)
        }
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
        let reported = live.wearableState(deviceID, skill, arguments)
        guard let key = WearableQuickActions.switchKeys.first(where: { arguments[$0] != nil }) else {
            // Not a plain on/off switch (a mode, a pin, a workout, notes): the button runs its own
            // action and its line says what the device is doing now.
            let mode = reported?.mode.map { $0.replacingOccurrences(of: "_", with: " ") }
            let on = reported?.on
            let caption: String
            if let mode, on != false, !["on", "off"].contains(mode) {
                caption = "Now: \(mode)"
            } else if let on {
                caption = on ? "On" : "Off"
            } else {
                return nil
            }
            var state = ButtonLiveState(id: "\(skill).\(on == true ? "on" : on == false ? "off" : "mode")",
                                        title: button.name.isEmpty ? "Jarvis button" : button.name,
                                        symbol: button.symbol, caption: caption)
            if on != false, let ends = reported?.endsAt, ends > now { state.endsAt = ends }
            return [ResolvedState(from: nil, state: state, action: button.action)]
        }
        let known = reported?.on
        let guess = live.lastSet[button.id].flatMap { now.timeIntervalSince($0.at) < optimisticFor ? $0 : nil }
        guard let isOn = known ?? guess?.on else { return nil }
        let names = WearableQuickActions.names(for: skill)
        var turned = arguments
        turned[key] = isOn ? "false" : "true"
        if !isOn, arguments["confirm"] != nil { turned["confirm"] = "true" }
        var state = ButtonLiveState(id: "\(skill).\(isOn ? "on" : "off")", title: isOn ? names.off : names.on,
                                    symbol: isOn ? "stop.circle.fill" : button.symbol, caption: isOn ? "On" : "Off")
        // Something with a known end (a sterilise cycle) counts down while it's on.
        if isOn, let ends = reported?.endsAt, ends > now { state.endsAt = ends }
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
