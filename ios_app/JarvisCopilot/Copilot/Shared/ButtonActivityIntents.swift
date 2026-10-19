import AppIntents
import Foundation

/// Stop on a button's Lock Screen card or Dynamic Island: presses the button for the state the
/// card showed ("Stop arming"). A Live Activity intent, so iOS runs it in the app's process.
///
/// Never his own Control Center press (`physical: false`), so it can't skip Face ID: Stop arming
/// needs none, a Disarm shown on the card still asks. It carries the state it showed, so a card
/// drawn before the alarm armed can't turn Stop into Disarm. A card the server started has no
/// button and stops the door alarm itself.
struct StopButtonActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop a Jarvis button's countdown"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    /// What a press on a server-started door card goes to: the door alarm itself.
    static let doorAlarmID = "door"

    @Parameter(title: "Button")
    var buttonID: String

    /// The `ButtonLiveState.id` the card showed.
    @Parameter(title: "State")
    var stateID: String

    init() {
        buttonID = ""
        stateID = ""
    }

    init(buttonID: String, stateID: String) {
        self.buttonID = buttonID
        self.stateID = stateID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await ControlButtonShelf.dispatch(Self.press(buttonID: buttonID, stateID: stateID))
        return .result()
    }

    static func press(buttonID: String, stateID: String) -> ButtonPress {
        ButtonPress(buttonID: buttonID.isEmpty ? doorAlarmID : buttonID, physical: false,
                    shownState: stateID.isEmpty ? nil : stateID)
    }
}
