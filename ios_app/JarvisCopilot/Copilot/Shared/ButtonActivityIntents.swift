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

    static func press(buttonID: String, stateID: String, unlocked: Bool = false) -> ButtonPress {
        ButtonPress(buttonID: buttonID.isEmpty ? doorAlarmID : buttonID, physical: false,
                    shownState: stateID.isEmpty ? nil : stateID, unlocked: unlocked)
    }

    /// The card states whose press disarms or silences the alarm: those go through
    /// `UnlockedButtonActivityIntent`.
    static func needsUnlock(_ stateID: String) -> Bool {
        stateID.hasPrefix("door.armed") || ["door.entry", "door.triggered", "door.siren"].contains(stateID)
    }
}

/// Disarm or Silence on the alarm's Lock Screen card or Dynamic Island. iOS runs it only once the
/// iPhone is unlocked (it asks for Face ID, or the passcode, first), and that unlock is the
/// approval — his call (2026-10-27): the alarm disarms right there, signed with the button key,
/// instead of a "Tap to approve" notification. Still refuses a card whose state has moved on.
struct UnlockedButtonActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Disarm from a Jarvis alarm card"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let isDiscoverable = false

    @Parameter(title: "Button")
    var buttonID: String

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
        await ControlButtonShelf.dispatch(StopButtonActivityIntent.press(buttonID: buttonID, stateID: stateID, unlocked: true))
        return .result()
    }
}
