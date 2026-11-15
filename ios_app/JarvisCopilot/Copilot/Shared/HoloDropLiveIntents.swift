import AppIntents
import Foundation

/// The "Drop waiting" card's Save / Copy buttons (Dynamic Island and Lock Screen). Live Activity
/// intents, so iOS runs them in the app's process — in the background, no app opening. Open is a
/// link (`jarviscopilot://holo-drop?drop=<id>&do=open`): opening something needs the app forward.
///
/// Compiled into BOTH the app and the `JarvisWidget` extension: the widget only builds the
/// buttons; the app installs `HoloDropLiveBridge.perform` at launch.
@MainActor
enum HoloDropLiveBridge {
    /// (drop id, action raw value: "save" | "copy" | "open"). Nil in the widget extension.
    static var perform: ((String, String) -> Void)?
}

struct HoloDropLiveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Holo Drop"
    static let description = IntentDescription("Saves or copies a drop that arrived on this iPhone.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @Parameter(title: "Drop")
    var dropID: String

    @Parameter(title: "Action")
    var action: String

    init() {
        dropID = ""
        action = ""
    }

    init(dropID: String, action: String) {
        self.dropID = dropID
        self.action = action
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if !dropID.isEmpty { HoloDropLiveBridge.perform?(dropID, action) }
        return .result()
    }
}
