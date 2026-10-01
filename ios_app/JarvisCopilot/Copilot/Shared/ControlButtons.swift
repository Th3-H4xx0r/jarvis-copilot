import AppIntents
import Foundation

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
}

enum ControlButtonShelf {
    static let key = "jc.controlButtons"
    static let pendingKey = "jc.controlButtons.pending"
    static let controlKind = "com.jarviscopilot.jarviscopilotMobileAndIOS.JarvisWidget1.ButtonControl"

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

/// Where a press is run. The app installs `run` at launch; in the widget extension it stays
/// nil and the press is queued instead.
@MainActor
enum ControlButtonBridge {
    static var run: ((String) async -> Void)?
}

struct ControlButtonEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Jarvis button"
    static let defaultQuery = ControlButtonQuery()

    let id: String
    let name: String
    let symbol: String

    init(_ info: ControlButtonInfo) {
        id = info.id
        name = info.name
        symbol = info.symbol
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

/// What a "Jarvis button" control is pointed at, chosen when it is added to Control Center.
@available(iOS 18.0, *)
struct ConfigureJarvisButtonIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Jarvis button"
    static let description = IntentDescription("Choose which of your Jarvis buttons this runs.")

    @Parameter(title: "Button")
    var button: ControlButtonEntity?
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
