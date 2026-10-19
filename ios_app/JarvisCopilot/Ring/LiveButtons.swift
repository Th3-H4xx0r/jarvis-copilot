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
    /// The sources a card is up for, and the state it shows.
    private var cards: [String: String] = [:]
    private var tick: Task<Void, Never>?

    // Dependencies — overridable in tests.
    var buttons: () -> [ControlButton] = { ControlButtonStore.shared.buttons }
    var apply: ([String: ButtonTimeline?]) -> Void = { ControlButtonStore.shared.applyTimelines($0) }
    var fetchDoor: () async -> DoorAlarmInfo? = { try? await DoorAlarmAPI().state().alarm }
    var fetchCar: () async -> CarReading? = {
        guard let car = try? await ToyotaAPI().state().car else { return nil }
        return CarReading(locked: car.doors?.locked, running: car.running)
    }
    var widgetData: () -> [String: JCJSON] = { WidgetDataFile.read() }
    var wearableOn: (String, String) -> Bool? = { LiveButtons.reportedOn(deviceID: $0, skill: $1) }
    var showCard: (String, String, String, String, ButtonLiveState) async -> Void = {
        await ButtonActivityController.shared.show(source: $0, buttonID: $1, name: $2, symbol: $3, state: $4)
    }
    var finishCard: (String, String) async -> Void = { await ButtonActivityController.shared.finish(source: $0, result: $1) }
    var setDoorPushToStart: (Bool) -> Void = { ButtonActivityController.shared.setDoorPushToStart(enabled: $0) }
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
        let followed = Set(buttons().compactMap(Self.source))
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
        live.values = widgetData()
        live.wearableOn = wearableOn
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
    func pressDoorCard(shownState: String?) async {
        guard let alarm = await Self.within(3, fetchDoor) else { return }
        live.door = alarm
        let context = RingActionContext(chatKey: "ring.inputs", chatTitle: "Ring", physical: false)
        switch alarm.state {
        case "arming" where shownState == nil || shownState == "door.arming":
            _ = await runAction(.door(.cancelArming), context)
        case "entry", "triggered":
            _ = await runAction(.door(alarm.sirenOn ? .silence : .disarm), context)
        default:
            break
        }
        if let after = await Self.within(3, fetchDoor) { live.door = after }
        await recompute()
    }

    // MARK: working it out

    /// Every button's states, written for Control Center and widgets; the Lock Screen card follows.
    func recompute() async {
        let at = now()
        live.values = widgetData()
        live.wearableOn = wearableOn
        let all = buttons()
        var timelines: [String: ButtonTimeline?] = [:]
        for button in all where !button.keepsState {
            timelines[button.id] = ButtonStateResolver.timeline(button, live: live, now: at)
        }
        apply(timelines)
        setDoorPushToStart(all.contains { Self.source($0) == "door" && $0.showsLiveActivity })
        await updateCards(all, timelines: timelines, at: at)
        scheduleTick(timelines.values.compactMap { $0 }, at: at)
    }

    /// One card per source: the door, the car, or the button itself.
    private func updateCards(_ all: [ControlButton], timelines: [String: ButtonTimeline?], at: Date) async {
        var wanted: [String: (button: ControlButton, state: ButtonLiveState)] = [:]
        for button in all where button.showsLiveActivity {
            guard let timeline = timelines[button.id] ?? nil, let state = timeline.state(at: at),
                  let ends = state.endsAt, ends > at else { continue }
            let followed = Self.source(button)
            let source = followed == "door" || followed == "car" ? followed! : "button.\(button.id)"
            if wanted[source] == nil { wanted[source] = (button, state) }
        }
        for (source, entry) in wanted where cards[source] != entry.state.id {
            let (name, symbol) = Self.cardLabel(source: source, button: entry.button)
            await showCard(source, entry.button.id, name, symbol, entry.state)
            cards[source] = entry.state.id
        }
        for source in Array(cards.keys) where wanted[source] == nil {
            cards[source] = nil
            await finishCard(source, Self.result(source: source, live: live))
        }
    }

    /// While something counts down and the app is awake: redraw at the next change, and every
    /// 15 s so a tile that can't tick still shows the time left.
    private func scheduleTick(_ timelines: [ButtonTimeline], at: Date) {
        tick?.cancel()
        let counting = timelines.contains { $0.state(at: at)?.endsAt.map { $0 > at } ?? false }
        let next = timelines.compactMap { $0.nextChange(after: at) }.min()
        guard counting || next != nil else { return }
        let wait = min(15, max(1, (next ?? at.addingTimeInterval(15)).timeIntervalSince(at)))
        tick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reloadControls()
            await self.recompute()
        }
    }

    private func updateCar(_ state: CarReading) {
        var car = live.car ?? CarLive()
        car.locked = state.locked ?? car.locked
        if state.running != car.running { car.startedAt = state.running ? (car.startedAt ?? now()) : nil }
        car.running = state.running
        live.car = car
    }

    // MARK: helpers

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

    /// A wearable switch's state as the device reports it, for the devices that do.
    static func reportedOn(deviceID: String, skill: String) -> Bool? {
        guard let device = DeviceRegistry.shared.device(id: deviceID) else { return nil }
        let snapshot = device.snapshot()
        switch skill {
        case "bottle_sterilise": return snapshot["sterilising"] as? Bool
        case "dashcam_set_recording": return snapshot["recording"] as? Bool
        case "esp32_set_led": return snapshot["led_on"] as? Bool
        case "lights_set": return (snapshot["controllers"] as? [[String: Any]])?.first?["on"] as? Bool
        default: return nil
        }
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
