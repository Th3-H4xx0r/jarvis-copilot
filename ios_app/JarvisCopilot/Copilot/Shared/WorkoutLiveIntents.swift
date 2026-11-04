import AppIntents
import Foundation

/// The workout Live Activity's buttons (Lock Screen and Dynamic Island): change
/// the next set's weight or reps, log it, move or skip a rest, pause or resume.
/// Live Activity intents, so iOS runs them in the app's process, where the
/// workout is; no Face ID (logging a set mid-workout is the point).
///
/// Compiled into BOTH the app and the `JarvisWidget` extension: the widget only
/// builds the buttons, the app installs `WorkoutLiveBridge.perform` at launch.
@MainActor
enum WorkoutLiveBridge {
    /// Runs one `WorkoutLiveAction` on the running workout. Nil in the widget extension.
    static var perform: ((WorkoutLiveAction) -> Void)?
}

/// What a workout Live Activity button does.
enum WorkoutLiveAction: String, CaseIterable {
    case weightUp, weightDown, repsUp, repsDown
    /// Log the next set (and start its rest).
    case logSet
    case restLonger, restShorter, skipRest
    case pause, resume
}

struct WorkoutLiveActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Workout control"
    static let description = IntentDescription("Logs a set, changes its weight or reps, or controls the rest or the workout.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @Parameter(title: "Action")
    var action: String

    init() { action = "" }
    init(_ action: WorkoutLiveAction) { self.action = action.rawValue }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let action = WorkoutLiveAction(rawValue: action) {
            WorkoutLiveBridge.perform?(action)
        }
        return .result()
    }
}
