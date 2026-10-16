import AppIntents
import Foundation

/// The CarPlay Talk widget's button: one tap starts a one-shot Jarvis turn in the
/// background — no Jarvis screen, the car stays where it is — and a second tap stops it.
///
/// An `AudioRecordingIntent`, the one way iOS lets an app start the microphone from
/// the background, and a `LiveActivityIntent` so iOS runs `perform()` in the app's
/// process, where the voice session lives. Compiled into the app and the widget.
@available(iOS 18.0, *)
struct CarTalkIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Talk to Jarvis"
    static let description = IntentDescription("Start or stop a voice turn with Jarvis from CarPlay.")
    static let isDiscoverable = false
    /// The phone is locked in a pocket while driving.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // Nil in the widget extension: no microphone there, and a start queued for
        // later would switch the mic on at some random moment. Nothing happens.
        guard let toggle = CarTalkBridge.toggle else { return .result() }
        await toggle()
        return .result()
    }
}

enum CarTalkBridge {
    enum Action: Equatable { case start, stop }

    /// Starts or stops the car's turn. Set by the app at launch; nil in the widget.
    @MainActor static var toggle: (() async -> Void)?

    /// Any live session — connecting, listening, thinking or speaking — stops.
    static func action(sessionActive: Bool) -> Action { sessionActive ? .stop : .start }
}

/// What the Talk widget shows: the turn's state and one line (his words, then the
/// reply). Written by the app into the App Group, read by the widget's timeline.
struct CarTalkSnapshot: Codable, Equatable {
    var state: String
    var line: String
    var updatedAt: Date

    /// Past this, a state is treated as over: a killed app can't leave "Listening"
    /// on the widget, and a held reply leaves with its 2 minutes.
    static let staleAfter: TimeInterval = 120
    static let key = "jc.carTalk.snapshot"
    static var store: UserDefaults { UserDefaults(suiteName: JarvisShared.appGroupID) ?? .standard }
    static let idle = CarTalkSnapshot(state: "idle", line: "", updatedAt: .distantPast)

    func shown(now: Date) -> CarTalkSnapshot {
        guard now.timeIntervalSince(updatedAt) > Self.staleAfter else { return self }
        return CarTalkSnapshot(state: "idle", line: "", updatedAt: updatedAt)
    }

    static func load(_ defaults: UserDefaults = store) -> CarTalkSnapshot {
        guard let data = defaults.data(forKey: key),
              let snap = try? JSONDecoder().decode(CarTalkSnapshot.self, from: data) else { return idle }
        return snap
    }

    func save(_ defaults: UserDefaults = Self.store) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
