import AppIntents
import Foundation
import SwiftUI

/// Control Center buttons: named buttons set up in the app's settings, each running one Jarvis
/// action, and a "Jarvis button" control that runs whichever one it was pointed at.
///
/// Compiled into BOTH the app and the `JarvisWidget` extension. The extension only ever needs
/// a button's id, name and icon (to list them when the control is added, and to draw it); what
/// a button does is the app's alone, so the action rides along in the same JSON undecoded here.

struct ControlButtonInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var symbol: String
    /// Shown as a "Jarvis switch" that stays lit while on, rather than a button.
    var keepsState: Bool? = nil
    var isOn: Bool? = nil
    /// The line under the name, already worked out by the app (state, last result, own text).
    var caption: String? = nil
    /// A switch's symbol while off; nil keeps `symbol`.
    var offSymbol: String? = nil
    /// "#RRGGBB" for the lit symbol; nil is the system's.
    var tint: String? = nil
    /// Disarms or drives the car without Face ID: a widget always shows this button's own name
    /// and symbol, never a design's label, so a widget Jarvis wrote can't disguise it.
    var skipsFaceID: Bool? = nil
    /// The button's live states over time (door alarm, car, a wearable switch, his own states);
    /// nil for a button without states. The control draws the one for "now".
    var timeline: ButtonTimeline? = nil
    /// Show the time left on the tile while a state counts down.
    var showsCountdown: Bool? = nil

    var tintColor: Color? {
        guard let tint, let value = UInt32(tint.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
        else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

enum ControlButtonShelf {
    static let key = "jc.controlButtons"
    static let pendingKey = "jc.controlButtons.pending"
    static let controlKind = "com.jarviscopilot.jarviscopilotMobileAndIOS.JarvisWidget1.ButtonControl"
    static let switchKind = "com.jarviscopilot.jarviscopilotMobileAndIOS.JarvisWidget1.SwitchControl"

    static var defaults: UserDefaults { UserDefaults(suiteName: JarvisShared.appGroupID) ?? .standard }

    /// The buttons as the widget sees them, in the order they are listed in settings.
    static func infos(defaults: UserDefaults = defaults) -> [ControlButtonInfo] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ControlButtonInfo].self, from: data)) ?? []
    }

    /// A press that reached a process which can't run it (the widget extension): left here
    /// for the app to run the next time it is up.
    static func queue(_ id: String, defaults: UserDefaults = defaults) {
        defaults.set((defaults.stringArray(forKey: pendingKey) ?? []) + [id], forKey: pendingKey)
    }

    /// A secret only the app and its Control Center controls know. A Control Center press carries
    /// it; a Shortcut that calls the press intent can't, so it never counts as his own press (the
    /// only kind that may skip Face ID).
    static func pressToken(defaults: UserDefaults = defaults) -> String {
        if let token = defaults.string(forKey: tokenKey), !token.isEmpty { return token }
        let token = UUID().uuidString + UUID().uuidString
        defaults.set(token, forKey: tokenKey)
        return token
    }

    private static let tokenKey = "jc.controlButtons.pressToken"

    static func takePending(defaults: UserDefaults = defaults) -> [String] {
        let ids = defaults.stringArray(forKey: pendingKey) ?? []
        defaults.removeObject(forKey: pendingKey)
        return ids
    }
}

/// One press of a button: which button, the widget it was on (for that widget's model
/// override), and whether a person pressed it — Control Center or a widget — rather than a
/// Shortcut or Siri. Only a physical press may skip Face ID.
struct ButtonPress: Equatable, Sendable {
    var buttonID: String
    var widgetID: String? = nil
    /// His own press in Control Center (it carried the press token). Only these may skip Face ID —
    /// never a widget (a design Jarvis wrote could hide a button), a Shortcut or Siri.
    var physical = true
    /// A switch flipped to this value; nil for a plain press.
    var on: Bool? = nil

    /// How the widget extension queues a press it can't run: `id[=on|=off][|w=<widget>][|shortcut]`.
    /// Entries from older builds ("id", "id=on") read the same as before.
    var queueEntry: String {
        var entry = buttonID
        if let on { entry += on ? "=on" : "=off" }
        if let widgetID, !widgetID.isEmpty { entry += "|w=" + widgetID }
        if !physical { entry += "|shortcut" }
        return entry
    }

    init(buttonID: String, widgetID: String? = nil, physical: Bool = true, on: Bool? = nil) {
        self.buttonID = buttonID
        self.widgetID = widgetID
        self.physical = physical
        self.on = on
    }

    init(queueEntry: String) {
        let parts = queueEntry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let head = parts[0].split(separator: "=", maxSplits: 1).map(String.init)
        self.init(buttonID: head[0], on: head.count == 2 ? head[1] == "on" : nil)
        for part in parts.dropFirst() {
            if part.hasPrefix("w=") { widgetID = String(part.dropFirst(2)) }
            if part == "shortcut" { physical = false }
        }
    }
}

/// Where a press is run. The app installs these at launch; in the widget extension they stay
/// nil and the press is queued instead.
@MainActor
enum ControlButtonBridge {
    static var run: ((ButtonPress) async -> Void)?
    /// A switch flipped to a value (`press.on`).
    static var set: ((ButtonPress) async -> Void)?
}

struct ControlButtonEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Jarvis button"
    static let defaultQuery = ControlButtonQuery()

    let id: String
    let name: String
    let symbol: String
    let info: ControlButtonInfo

    init(_ info: ControlButtonInfo) {
        id = info.id
        name = info.name
        symbol = info.symbol
        self.info = info
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

struct ControlButtonQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ControlButtonEntity] {
        ControlButtonShelf.infos().filter { identifiers.contains($0.id) }.map(ControlButtonEntity.init)
    }

    func suggestedEntities() async throws -> [ControlButtonEntity] {
        ControlButtonShelf.infos().map(ControlButtonEntity.init)
    }
}

/// Buttons go in Control Center as a "Jarvis button"; ones that keep their state as a "Jarvis switch".
struct ButtonOptions: DynamicOptionsProvider {
    func results() async throws -> [ControlButtonEntity] {
        ControlButtonShelf.infos().filter { $0.keepsState != true }.map(ControlButtonEntity.init)
    }
}

struct SwitchOptions: DynamicOptionsProvider {
    func results() async throws -> [ControlButtonEntity] {
        ControlButtonShelf.infos().filter { $0.keepsState == true }.map(ControlButtonEntity.init)
    }
}

/// What a "Jarvis button" control is pointed at, chosen when it is added to Control Center.
@available(iOS 18.0, *)
struct ConfigureJarvisButtonIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Jarvis button"
    static let description = IntentDescription("Choose which of your Jarvis buttons this runs.")

    @Parameter(title: "Button", optionsProvider: ButtonOptions())
    var button: ControlButtonEntity?
}

/// What a "Jarvis switch" control is pointed at: a button set to keep its state.
@available(iOS 18.0, *)
struct ConfigureJarvisSwitchIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Jarvis switch"
    static let description = IntentDescription("Choose which of your Jarvis buttons that keep their state this is.")

    @Parameter(title: "Button", optionsProvider: SwitchOptions())
    var button: ControlButtonEntity?
}

/// Flips a switch from Control Center or a widget. Like a press, run in the app's process.
/// Not discoverable, so no Shortcut can flip it: a flip is always a person's.
struct SetJarvisButtonIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn a Jarvis switch on or off"
    static let isDiscoverable = false

    @Parameter(title: "Button")
    var button: ControlButtonEntity?

    @Parameter(title: "On")
    var value: Bool

    /// The widget design it sits on, for that widget's model override.
    @Parameter(title: "Widget")
    var widget: String?

    /// `ControlButtonShelf.pressToken()` when Control Center built it.
    @Parameter(title: "Token")
    var token: String?

    init() {}

    init(button: ControlButtonEntity?, widget: String? = nil, token: String? = nil) {
        self.button = button
        self.widget = widget
        self.token = token
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = button?.id else { return .result() }
        let own = token != nil && token == ControlButtonShelf.pressToken()
        await ControlButtonShelf.dispatch(ButtonPress(buttonID: id, widgetID: widget, physical: own, on: value))
        return .result()
    }
}

/// A press from Control Center or a widget. Hidden from Shortcuts and Siri, which use
/// `RunJarvisButtonIntent`; and it only counts as his own press when it carries the press token,
/// which only Control Center's control is built with.
struct PressJarvisButtonIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Press a Jarvis button"
    static let isDiscoverable = false

    @Parameter(title: "Button")
    var button: ControlButtonEntity?

    @Parameter(title: "Widget")
    var widget: String?

    @Parameter(title: "Token")
    var token: String?

    init() {}

    init(button: ControlButtonEntity?, widget: String? = nil, token: String? = nil) {
        self.button = button
        self.widget = widget
        self.token = token
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = button?.id else { return .result() }
        let own = token != nil && token == ControlButtonShelf.pressToken()
        await ControlButtonShelf.dispatch(ButtonPress(buttonID: id, widgetID: widget, physical: own))
        return .result()
    }
}

/// Runs one button from a Shortcut, Siri or an automation. A Live Activity intent so iOS performs
/// it in the app's process — launching the app in the background if it isn't running — where the
/// action can actually run. Never skips Face ID.
struct RunJarvisButtonIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Run a Jarvis button"
    static let description = IntentDescription("Runs one of the buttons set up in Jarvis settings.")

    @Parameter(title: "Button")
    var button: ControlButtonEntity?

    init() {}

    init(button: ControlButtonEntity?) {
        self.button = button
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = button?.id else { return .result() }
        await ControlButtonShelf.dispatch(ButtonPress(buttonID: id, physical: false))
        return .result()
    }
}

extension ControlButtonShelf {
    /// Hands a press to the app, or queues it when this is the widget extension.
    @MainActor
    static func dispatch(_ press: ButtonPress) async {
        let handler = press.on == nil ? ControlButtonBridge.run : ControlButtonBridge.set
        if let handler {
            await handler(press)
        } else {
            queue(press.queueEntry)
        }
    }
}
