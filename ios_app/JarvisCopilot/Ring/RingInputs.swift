import Foundation

/// A tap, swipe or press on the ring, named by the code the ring sends.
///
/// The ring only reports its inputs to the phone in music mode, where it labels them
/// play/pause, previous, next and volume. Jarvis keeps it in that mode and runs your own
/// action instead of controlling music, so these names are what the ring calls them.
enum RingInput: String, CaseIterable, Codable, Identifiable {
    case tap
    case swipeForward = "swipe_forward"
    case swipeBack = "swipe_back"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case longPress = "long_press"
    case doubleTap = "double_tap"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tap: return "Tap"
        case .swipeForward: return "Swipe forward"
        case .swipeBack: return "Swipe back"
        case .volumeUp: return "Volume-up gesture"
        case .volumeDown: return "Volume-down gesture"
        case .longPress: return "Long press"
        case .doubleTap: return "Double tap"
        }
    }

    /// `0x1D` music actions: 1 play/pause · 2 previous · 3 next · 4 volume up · 5 volume down.
    init?(musicAction: Int) {
        switch musicAction {
        case 1: self = .tap
        case 2: self = .swipeBack
        case 3: self = .swipeForward
        case 4: self = .volumeUp
        case 5: self = .volumeDown
        default: return nil
        }
    }

    /// `0x73`/45 key events: 1 swipe down · 2 swipe up · 3 click · 4 long press.
    init?(touchKey: Int) {
        switch touchKey {
        case 1: self = .swipeBack
        case 2: self = .swipeForward
        case 3: self = .tap
        case 4: self = .longPress
        default: return nil
        }
    }
}

/// What the ring's taps and swipes drive.
///
/// In its music mode the ring talks straight to iOS as a Bluetooth media remote, so the press
/// never reaches this app — that mode can only control music. The modes QRing drives from its
/// own app report each press over the ring's channel instead (`0x73`: 41 a game click, 37 the
/// tasbih counter, 48 a couple double-tap), which is what a custom action needs. Game is the
/// one this ring advertises.
enum RingInputMode: String, CaseIterable, Codable, Identifiable {
    case jarvis, music, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jarvis: return "Jarvis actions"
        case .music: return "Music"
        case .off: return "Off"
        }
    }

    var detail: String {
        switch self {
        case .jarvis: return "The ring reports every press to Jarvis, which runs what you set below."
        case .music: return "The ring acts as a media remote to iOS. Jarvis never sees these presses."
        case .off: return "The ring ignores taps and swipes."
        }
    }

    /// The ring's app type for touch and gesture control.
    var appType: UInt8 {
        switch self {
        case .jarvis: return RingTouchMode.game.rawValue
        case .music: return RingTouchMode.music.rawValue
        case .off: return RingTouchMode.off.rawValue
        }
    }
}

/// The last input the ring sent, so the settings screen can show which row it lands on.
struct RingInputEvent: Equatable {
    let input: RingInput
    let date: Date
}

/// What Jarvis does when a ring input fires.
enum RingAction: Codable, Equatable {
    case none
    /// Anything Jarvis can do: the text runs as a Jarvis turn with all its tools.
    case prompt(String)
    /// One named action — a phone skill or a ring skill — run the way Jarvis runs it.
    case skill(id: String, arguments: [String: String])

    var isSet: Bool {
        if case .none = self { return false }
        return true
    }

    /// One line describing the action, for the settings row and the log.
    var summary: String {
        switch self {
        case .none:
            return "Nothing"
        case .prompt(let text):
            return "Ask Jarvis: \(text)"
        case .skill(let id, let arguments):
            guard let option = RingActionCatalogue.option(id) else { return id }
            guard let parameter = option.parameter, let value = arguments[parameter.key], !value.isEmpty else {
                return option.label
            }
            return "\(option.label): \(value)"
        }
    }
}

/// One thing a ring input can be set to do, backed by a skill this phone already has.
struct RingActionOption: Identifiable, Equatable {
    struct Parameter: Equatable {
        let key: String
        let title: String
        let placeholder: String
    }

    let id: String
    let group: String
    let label: String
    /// The skill that runs it — a phone skill, or a `ring_*` skill on this ring.
    let skill: String
    var arguments: [String: String] = [:]
    /// The one value the user fills in, if the action takes one.
    var parameter: Parameter?
    var note: String?
}

/// Every predefined action a ring input can run. Anything else is a prompt.
enum RingActionCatalogue {
    static let options: [RingActionOption] = [
        // Phone
        RingActionOption(id: "flashlight_on", group: "Phone", label: "Torch on", skill: "flashlight_on"),
        RingActionOption(id: "flashlight_off", group: "Phone", label: "Torch off", skill: "flashlight_off"),
        RingActionOption(id: "vibrate", group: "Phone", label: "Vibrate", skill: "vibrate",
                         arguments: ["duration_ms": "400"]),
        RingActionOption(id: "notify", group: "Phone", label: "Show a notification", skill: "notify",
                         arguments: ["title": "Ring"],
                         parameter: .init(key: "body", title: "Text", placeholder: "Marked")),
        RingActionOption(id: "speak", group: "Phone", label: "Speak something", skill: "text_to_speech",
                         parameter: .init(key: "text", title: "Words", placeholder: "On my way")),
        RingActionOption(id: "battery_level", group: "Phone", label: "Read the battery level", skill: "battery_level"),
        RingActionOption(id: "take_photo", group: "Phone", label: "Take a photo", skill: "take_photo",
                         note: "Opens the camera, so the phone has to be unlocked."),
        RingActionOption(id: "set_timer", group: "Phone", label: "Start a timer", skill: "set_timer",
                         parameter: .init(key: "minutes", title: "Minutes", placeholder: "10")),
        // Apps and shortcuts
        RingActionOption(id: "open_app", group: "Apps", label: "Open an app", skill: "open_app",
                         parameter: .init(key: "app", title: "App", placeholder: "spotify")),
        RingActionOption(id: "open_url", group: "Apps", label: "Open a link", skill: "open_url",
                         parameter: .init(key: "url", title: "URL", placeholder: "https://…")),
        RingActionOption(id: "run_shortcut", group: "Apps", label: "Run a Shortcut", skill: "run_shortcut",
                         parameter: .init(key: "name", title: "Shortcut", placeholder: "Goodnight")),
        // Media and system settings — iOS only lets an app reach these through Shortcuts.
        RingActionOption(id: "play_pause", group: "Media", label: "Play / pause", skill: "run_shortcut",
                         arguments: ["name": "JC Play Pause"],
                         parameter: .init(key: "name", title: "Shortcut", placeholder: "JC Play Pause"),
                         note: "Needs a Shortcut of this name that plays/pauses."),
        RingActionOption(id: "next_track", group: "Media", label: "Next track", skill: "run_shortcut",
                         arguments: ["name": "JC Next Track"],
                         parameter: .init(key: "name", title: "Shortcut", placeholder: "JC Next Track"),
                         note: "Needs a Shortcut of this name that skips forward."),
        RingActionOption(id: "previous_track", group: "Media", label: "Previous track", skill: "run_shortcut",
                         arguments: ["name": "JC Previous Track"],
                         parameter: .init(key: "name", title: "Shortcut", placeholder: "JC Previous Track"),
                         note: "Needs a Shortcut of this name that skips back."),
        RingActionOption(id: "volume", group: "Media", label: "Set volume", skill: "phone_control",
                         arguments: ["action": "volume"],
                         parameter: .init(key: "value", title: "Percent", placeholder: "40"),
                         note: "Runs the \"JC Volume\" Shortcut."),
        RingActionOption(id: "focus_on", group: "Media", label: "Focus on", skill: "phone_control",
                         arguments: ["action": "focus", "value": "1"], note: "Runs the \"JC Focus\" Shortcut."),
        RingActionOption(id: "focus_off", group: "Media", label: "Focus off", skill: "phone_control",
                         arguments: ["action": "focus", "value": "0"], note: "Runs the \"JC Focus\" Shortcut."),
        // The ring itself
        RingActionOption(id: "measure_heart_rate", group: "Ring", label: "Measure heart rate", skill: "ring_measure",
                         arguments: ["metric": "heart_rate"]),
        RingActionOption(id: "measure_spo2", group: "Ring", label: "Measure blood oxygen", skill: "ring_measure",
                         arguments: ["metric": "spo2"]),
        RingActionOption(id: "ring_sync", group: "Ring", label: "Sync the ring now", skill: "ring_sync",
                         arguments: ["days": "0"]),
    ]

    static func option(_ id: String) -> RingActionOption? {
        options.first { $0.id == id }
    }

    static var groups: [String] {
        var seen: [String] = []
        for option in options where !seen.contains(option.group) { seen.append(option.group) }
        return seen
    }
}

/// What each ring input runs, kept per ring.
@MainActor
final class RingInputStore: ObservableObject {
    private static var instances: [String: RingInputStore] = [:]

    /// One store per ring, so the settings screen and the manager see the same actions.
    static func shared(for deviceID: String) -> RingInputStore {
        if let existing = instances[deviceID] { return existing }
        let store = RingInputStore(deviceID: deviceID)
        instances[deviceID] = store
        return store
    }

    @Published private(set) var actions: [RingInput: RingAction] = [:]
    /// What the user chose the ring's presses should do; nil until they choose.
    @Published private(set) var mode: RingInputMode?

    private let key: String
    private let modeKey: String
    private let defaults: UserDefaults

    init(deviceID: String, defaults: UserDefaults = .standard) {
        self.key = "jc.ring.inputs.\(deviceID)"
        self.modeKey = "jc.ring.inputs.\(deviceID).mode"
        self.defaults = defaults
        mode = defaults.string(forKey: modeKey).flatMap(RingInputMode.init(rawValue:))
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: RingAction].self, from: data) {
            actions = stored.reduce(into: [:]) { out, pair in
                if let input = RingInput(rawValue: pair.key) { out[input] = pair.value }
            }
        }
    }

    func action(for input: RingInput) -> RingAction { actions[input] ?? .none }

    /// True once anything is set, which is when the ring is asked to report its inputs.
    var isConfigured: Bool { actions.values.contains(where: \.isSet) }

    /// What to put the ring in when nobody has chosen: reporting once actions exist, else off,
    /// so a ring nobody configured keeps its own behaviour.
    var wantedMode: RingInputMode { mode ?? (isConfigured ? .jarvis : .off) }

    func setMode(_ mode: RingInputMode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    func set(_ action: RingAction, for input: RingInput) {
        if action.isSet { actions[input] = action } else { actions.removeValue(forKey: input) }
        let stored = actions.reduce(into: [String: RingAction]()) { out, pair in out[pair.key.rawValue] = pair.value }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
    }
}

/// Runs what an input is set to: a Jarvis turn for a prompt, otherwise the skill itself —
/// the phone's own skills through `InvokeRunner` (which defers anything needing the screen),
/// and `ring_*` skills through the device registry.
@MainActor
enum RingActionRunner {
    /// Returns one line for the log.
    static func run(_ action: RingAction) async -> String {
        switch action {
        case .none:
            return "nothing set"
        case .prompt(let text):
            return await ask(text)
        case .skill(let id, let arguments):
            guard let option = RingActionCatalogue.option(id) else { return "unknown action \(id)" }
            return await invoke(option.skill, merged(option, arguments))
        }
    }

    private static func merged(_ option: RingActionOption, _ arguments: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in option.arguments.merging(arguments, uniquingKeysWith: { _, given in given }) {
            if let number = Int(value) {
                out[key] = number
            } else if let number = Double(value) {
                out[key] = number
            } else {
                out[key] = value
            }
        }
        return out
    }

    private static func invoke(_ skill: String, _ args: [String: Any]) async -> String {
        if SkillRegistry.shared.find(skill) != nil {
            let outcome = await InvokeRunner.shared.run(skill, args)
            if let error = outcome.error { return "\(skill) failed: \(error)" }
            return summary(skill, outcome.result)
        }
        do {
            return summary(skill, try await DeviceRegistry.shared.invoke(skill: skill, args: args))
        } catch {
            return "\(skill) failed: \(error.localizedDescription)"
        }
    }

    private static func summary(_ skill: String, _ result: [String: Any]?) -> String {
        guard let result, !result.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else { return skill }
        return "\(skill): \(text.prefix(120))"
    }

    /// A prompt runs as a Jarvis turn in one conversation kept for the ring.
    private static func ask(_ text: String) async -> String {
        guard BridgeClient.shared.isPaired else { return "Jarvis is not paired in this app" }
        do {
            let chat = BoardChat()
            let session = try await chat.sessionID(for: "ring.inputs", title: "Ring")
            let turn = try await chat.run(sessionID: session, message: text, joinRunningTurn: false)
            let reply = turn.message.plainText
            let line = reply.split(whereSeparator: \.isNewline).last.map(String.init) ?? reply
            return line.isEmpty ? "done" : line
        } catch {
            return "Jarvis: \(error.localizedDescription)"
        }
    }
}
