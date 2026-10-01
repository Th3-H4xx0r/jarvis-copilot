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

    static func takePending(defaults: UserDefaults = defaults) -> [String] {
        let ids = defaults.stringArray(forKey: pendingKey) ?? []
        defaults.removeObject(forKey: pendingKey)
        return ids
    }
}

/// Where a press is run. The app installs these at launch; in the widget extension they stay
/// nil and the press is queued instead.
@MainActor
enum ControlButtonBridge {
    static var run: ((String) async -> Void)?
    /// A switch flipped to a value.
    static var set: ((String, Bool) async -> Void)?
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

/// Flips a switch. Like a press, run in the app's process.
struct SetJarvisButtonIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn a Jarvis switch on or off"
    static let isDiscoverable = false

    @Parameter(title: "Button")
    var button: ControlButtonEntity?

    @Parameter(title: "On")
    var value: Bool

    init() {}

    init(button: ControlButtonEntity?) {
        self.button = button
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = button?.id else { return .result() }
        if let set = ControlButtonBridge.set {
            await set(id, value)
        } else {
            ControlButtonShelf.queue(id + (value ? "=on" : "=off"))
        }
        return .result()
    }
}

/// Runs one button. A Live Activity intent so iOS performs it in the app's process — launching
/// the app in the background if it isn't running — where the action can actually run.
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
        if let run = ControlButtonBridge.run {
            await run(id)
        } else {
            ControlButtonShelf.queue(id)
        }
        return .result()
    }
}
