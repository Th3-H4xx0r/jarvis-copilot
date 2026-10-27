import Foundation
import WidgetKit

/// Keeps Jarvis buttons following what's happening: gathers the door alarm, the car and wearable
/// switches, works out every button's states (`ButtonStateResolver`), writes them for Control
/// Center and widgets, and shows the Lock Screen card + Dynamic Island while something counts down.
@MainActor
final class LiveButtons {
    static let shared = LiveButtons()
    /// What a door card the server started (no button behind it) presses with.
    static let doorCardID = "door"

    private(set) var live = LiveValues()
    /// The sources a card is up for, and what it shows (state id + end time).
    private var cards: [String: String] = [:]
    private var seeded = false
    private var tick: Task<Void, Never>?
    /// A recompute running, and whether another was asked for meanwhile.
    private var computing = false
    private var again = false

    // Dependencies — overridable in tests.
    var buttons: () -> [ControlButton] = { ControlButtonStore.shared.buttons }
    var apply: ([String: ButtonTimeline?]) -> Void = { ControlButtonStore.shared.applyTimelines($0) }
    var fetchDoor: () async -> DoorAlarmInfo? = { try? await DoorAlarmAPI().state().alarm }
    var fetchCar: () async -> CarReading? = {
        guard let car = try? await ToyotaAPI().state().car else { return nil }
        return CarReading(locked: car.doors?.locked, running: car.running)
    }
    var widgetData: () -> [String: JCJSON] = { WidgetDataFile.read() }
    var wearableState: (String, String, [String: String]) -> CommandLiveState? = { deviceID, skill, arguments in
        DeviceRegistry.shared.device(id: deviceID)?.commandState(skill, arguments: arguments)
    }
    var showCard: (String, String, String, String, ButtonLiveState) async -> Bool = {
        await ButtonActivityController.shared.show(source: $0, buttonID: $1, name: $2, symbol: $3, state: $4)
    }
    var finishCard: (String, String) async -> Void = { await ButtonActivityController.shared.finish(source: $0, result: $1) }
    var setDoorPushToStart: (Bool) -> Void = { ButtonActivityController.shared.setDoorPushToStart(enabled: $0) }
    /// Cards already up when the app (re)started: source → state id.
    var runningCards: () -> [String: String] = {
        ButtonActivityController.shared.running.mapValues { LiveButtons.episode($0.state) }
    }
    var notify: (String, String) async -> Void = { title, body in
        try? await DefaultNotifier().post(LocalNotificationRequest(title: title, body: body))
    }
    var runAction: (RingAction, RingActionContext) async -> String = { await RingActionRunner.run($0, context: $1) }
    var reloadControls: () -> Void = {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: ControlButtonShelf.controlKind)
        }
    }
    var now: () -> Date = Date.init

    /// What the car last reported.
    struct CarReading: Sendable {
        var locked: Bool?
        var running: Bool
    }

    // MARK: what changes the states

    /// Fetches what the buttons follow (door, car) and works the states out again.
    func refresh(door: Bool = true, car: Bool = true) async {
        let followed = Set(buttons().flatMap(Self.follows))
        if door, followed.contains("door"), let alarm = await Self.within(3, fetchDoor) { live.door = alarm }
        if car, followed.contains("car"), let state = await Self.within(3, fetchCar) { updateCar(state) }
        await recompute()
    }

    /// The server says the door alarm changed (`live_state`).
    func doorChanged(_ alarm: DoorAlarmInfo) async {
        live.door = alarm
        await recompute()
    }

    /// What a press runs now: the followed source is refreshed first (≤ 3 s) so a press never acts
    /// on an old reading.
    func press(_ button: ControlButton, shownState: String?) async -> ButtonStateResolver.Press {
        switch Self.source(button) {
        case "door": if let alarm = await Self.within(3, fetchDoor) { live.door = alarm }
        case "car": if let state = await Self.within(3, fetchCar) { updateCar(state) }
        default: break
        }
        live.values = values()
        live.wearableState = wearableState
        return ButtonStateResolver.press(button, shownState: shownState, live: live, now: now())
    }

    /// After a press ran: what it did becomes the state at once (a car that just locked reads
    /// Unlock), and the door is read back.
    func didRun(_ button: ControlButton, action: RingAction, line: String) async {
        if Self.succeeded(line) {
            switch action {
            case .car(let command, _):
                var car = live.car ?? CarLive()
                switch command {
                case "lock": car.locked = true
                case "unlock": car.locked = false
                case "start": car.running = true; car.startedAt = now()
                case "stop": car.running = false; car.startedAt = nil
                default: break
                }
                live.car = car
            case .wearable(_, _, let arguments):
                if let key = WearableQuickActions.switchKeys.first(where: { arguments[$0] != nil }) {
                    live.lastSet[button.id] = (arguments[key] == "true", now())
                }
            default:
                break
            }
        }
        if case .door = action, let alarm = await Self.within(3, fetchDoor) { live.door = alarm }
        await recompute()
    }

    /// Stop on a door card the server started: cancels arming while it is still arming; anything
    /// else (the entry delay) disarms through Face ID.
    func pressDoorCard(shownState: String?, unlocked: Bool = false) async {
        let context = RingActionContext(chatKey: "ring.inputs", chatTitle: "Ring", physical: false, unlocked: unlocked)
        var line: String?
        if let alarm = await Self.within(3, fetchDoor) {
            live.door = alarm
            // Only what the card showed runs: a stale "Stop arming" never becomes a disarm.
            switch alarm.state {
            case "arming" where shownState == "door.arming":
                line = await runAction(.door(.cancelArming), context)
            case "entry" where shownState == "door.entry":
                line = await runAction(.door(.disarm), context)
            case "triggered" where shownState == (alarm.sirenOn ? "door.siren" : "door.triggered"):
                line = await runAction(.door(alarm.sirenOn ? .silence : .disarm), context)
            default:
                break
            }
        } else if shownState == "door.arming" {
            // Couldn't read the alarm: stopping arming is always safe to ask for.
            line = await runAction(.door(.cancelArming), context)
        }
        if let line, !Self.succeeded(line), !line.hasPrefix("Tap the notification") { await notify("Door alarm", line) }
        if let after = await Self.within(3, fetchDoor) { live.door = after }
        await recompute()
    }

    // MARK: working it out

    /// Every button's states, written for Control Center and widgets; the Lock Screen card follows.
    /// Calls that land while one runs are folded into one more pass.
    func recompute() async {
        guard !computing else { again = true; return }
        computing = true
        defer { computing = false }
        repeat {
            again = false
            await recomputeOnce()
        } while again
    }

    private func recomputeOnce() async {
        let at = now()
        live.values = values()
        live.wearableState = wearableState
        let all = buttons()
        var timelines: [String: ButtonTimeline?] = [:]
        for button in all where !button.keepsState {
            // Nothing read yet (a launch whose fetch failed): keep the last good tile rather than
            // wiping it to the button's plain name.
            if Self.source(button) == "door" && live.door == nil { continue }
            if Self.source(button) == "car" && live.car == nil { continue }
            timelines[button.id] = ButtonStateResolver.timeline(button, live: live, now: at)
        }
        apply(timelines)
        setDoorPushToStart(all.contains { Self.source($0) == "door" && $0.showsLiveActivity })
        await updateCards(all, timelines: timelines, at: at)
        scheduleTick(timelines.values.compactMap { $0 }, at: at)
    }

    /// One card per source: the door, the car, or the button itself — up while something counts
    /// down or the alarm is going off.
    private func updateCards(_ all: [ControlButton], timelines: [String: ButtonTimeline?], at: Date) async {
        if !seeded {
            seeded = true
            for (source, id) in runningCards() where cards[source] == nil { cards[source] = id }
        }
        var current: [String: (button: ControlButton, state: ButtonLiveState)] = [:]
        for button in all where button.showsLiveActivity {
            guard let timeline = timelines[button.id] ?? nil, let state = timeline.state(at: at) else { continue }
            let followed = Self.source(button)
            let source = followed == "door" || followed == "car" ? followed! : "button.\(button.id)"
            if current[source] == nil { current[source] = (button, state) }
        }
        let wanted = current.filter { $0.value.state.alert || ($0.value.state.endsAt.map { $0 > at } ?? false) }
        for (source, entry) in wanted where cards[source] != Self.episode(entry.state) {
            let (name, symbol) = Self.cardLabel(source: source, button: entry.button)
            // Not up (Live Activities off, iOS refused it in the background): tried again next pass.
            if await showCard(source, entry.button.id, name, symbol, entry.state) {
                cards[source] = Self.episode(entry.state)
            }
        }
        for source in Array(cards.keys) where wanted[source] == nil {
            cards[source] = nil
            // What it says as it goes is what the button shows now ("Armed Away"), not a guess.
            let result = current[source].map { $0.state.caption ?? $0.state.title } ?? Self.result(source: source, live: live)
            await finishCard(source, result)
        }
    }

    /// A card's content changes when its state or its end time does.
    static func episode(_ state: ButtonLiveState) -> String {
        "\(state.id)@\(state.endsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-")"
    }

    /// While something counts down and the app is awake: redraw at the next change (reading the
    /// door again then), and every 15 s in the last ten minutes so a tile that can't tick still
    /// shows the time left.
    private func scheduleTick(_ timelines: [ButtonTimeline], at: Date) {
        tick?.cancel()
        let ends = timelines.compactMap { $0.state(at: at)?.endsAt }.filter { $0 > at }.min()
        let next = timelines.compactMap { $0.nextChange(after: at) }.min()
        guard ends != nil || next != nil else { return }
        let soon = ends.map { $0.timeIntervalSince(at) < 600 } ?? false
        let wait = min(soon ? 15 : 60, max(1, (next ?? at.addingTimeInterval(60)).timeIntervalSince(at)))
        tick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reloadControls()
            await self.refresh(door: true, car: false)
        }
    }

    private func updateCar(_ state: CarReading) {
        var car = live.car ?? CarLive()
        car.locked = state.locked ?? car.locked
        // Only Jarvis's own Start gives a start time: a car found running (driving) gets no countdown.
        if !state.running { car.startedAt = nil }
        car.running = state.running
        live.car = car
    }

    /// The widget hub's values with the door and car as read just now on top.
    private func values() -> [String: JCJSON] {
        widgetData().merging(widgetValues()) { _, fresh in fresh }
    }

    // MARK: helpers

    /// What a button needs read to work out its states: its own source, or the area of the live
    /// value his own states follow ("door.state" → "door").
    static func follows(_ button: ControlButton) -> [String] {
        if let key = button.states?.follows {
            return ["door", "car"].filter { key.hasPrefix("\($0).") || button.states?.countdownKey?.hasPrefix("\($0).") == true }
        }
        return source(button).map { [$0] } ?? []
    }

    /// What a button follows on its own: "door", "car", "wearable" — nil for none (or his own states).
    static func source(_ button: ControlButton) -> String? {
        guard button.followsLive, !button.keepsState, button.states == nil else { return nil }
        switch button.action {
        case .door: return "door"
        case .car(let command, _): return ["lock", "unlock", "start", "stop"].contains(command) ? "car" : nil
        case .wearable: return "wearable"
        default: return nil
        }
    }

    static func cardLabel(source: String, button: ControlButton) -> (String, String) {
        switch source {
        case "door": return ("Door alarm", "lock.shield")
        case "car": return ("Car", "car.fill")
        default: return (button.name.isEmpty ? "Jarvis button" : button.name, button.symbol)
        }
    }

    /// What the card says as it goes: "Armed Away", "Disarmed", "Engine off".
    static func result(source: String, live: LiveValues) -> String {
        switch source {
        case "door":
            switch live.door?.state {
            case "armed_away": return "Armed Away"
            case "armed_home": return "Armed Home"
            case "triggered": return "Alarm going off"
            default: return "Disarmed"
            }
        case "car": return live.car?.running == true ? "Running" : "Engine off"
        default: return "Done"
        }
    }

    static func succeeded(_ line: String) -> Bool {
        !(line.contains(" failed") || line.contains("unavailable") || line.hasPrefix("Not approved")
          || line.hasPrefix("Tap the notification") || line.contains("needs Face ID") || line.hasPrefix("unknown"))
    }

    /// The widgets' live values for the door and the car.
    func widgetValues() -> [String: JCJSON] {
        var out: [String: JCJSON] = [:]
        if let door = live.door {
            out["door.state"] = .string(door.state)
            if let mode = door.mode { out["door.mode"] = .string(mode) }
            if let deadline = door.deadline { out["door.deadline"] = .number(deadline.timeIntervalSince1970) }
        }
        if let locked = live.car?.locked { out["car.locked"] = .bool(locked) }
        if let running = live.car?.running { out["car.running"] = .bool(running) }
        return out
    }

    /// `op`'s answer, or nil after `seconds`.
    static func within<T: Sendable>(_ seconds: Double, _ op: @escaping @MainActor () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: the server's word

    /// `live_state`: the server tells the phone the door alarm changed. Server use only — the server
    /// keeps it out of Jarvis's tools.
    static func skill() -> AnySkill {
        AnySkill(
            name: "live_state",
            description: "The server's word that the door alarm changed, for the live buttons. Server use only.",
            inputSchema: SkillSchema.object([
                "source": SkillSchema.string("door"),
                "alarm": SkillSchema.object([:]),
            ], required: ["source"])
        ) { args in
            guard SkillArgs.string(args, "source") == "door", let alarm = args["alarm"] as? [String: Any] else {
                return ["ok": false, "error": "source must be door with an alarm object"]
            }
            await LiveButtons.shared.doorChanged(DoorAlarmInfo(json: alarm))
            return ["ok": true]
        }
    }
}
