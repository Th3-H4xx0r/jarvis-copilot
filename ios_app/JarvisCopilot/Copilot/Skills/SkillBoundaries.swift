import Foundation

/// Every platform capability a phone skill needs, expressed as a small
/// `Sendable` protocol so the skills themselves are pure argument plumbing and
/// every one of them is testable against a mock.
///
/// Production implementations live in `SkillBoundaries*.swift`; the mocks live
/// in `JarvisCopilotTests/Skills/SkillMocks.swift`.

// MARK: - Clipboard

protocol Clipboarding: Sendable {
    func read() async -> String?
    func write(_ text: String) async
}

// MARK: - Local notifications

/// One local notification to post now (`at == nil`) or schedule.
struct LocalNotificationRequest: Sendable {
    var title: String
    var body: String = ""
    /// When to fire. Nil means immediately.
    var at: Date?
    /// Stable id so a re-sync can cancel and reschedule. Nil → generated.
    var identifier: String?
    /// JSON the tap handler decodes (see `notificationActionPayload`).
    var payload: String?
    /// Alarms want a sound + time-sensitive interruption level.
    var sound: Bool = false
    var timeSensitive: Bool = false
}

protocol Notifying: Sendable {
    /// Prompts on first use. False when the user has denied notifications;
    /// THROWS when the request itself failed, so "the user said no" and "we
    /// never got to ask" don't collapse into the same answer.
    func requestAuthorization() async throws -> Bool
    /// Returns the identifier the notification was posted under.
    @discardableResult
    func post(_ request: LocalNotificationRequest) async throws -> String
    func cancel(identifiers: [String]) async
    /// Identifiers of everything still scheduled (so a UI can list alarms).
    func pending() async -> [String]
}

// MARK: - Opening URLs

protocol URLOpening: Sendable {
    /// Only true for schemes declared in `LSApplicationQueriesSchemes`; an
    /// undeclared scheme can still be opened, we just can't check first.
    func canOpen(_ url: URL) async -> Bool
    func open(_ url: URL) async -> Bool
}

// MARK: - Share sheet

enum SharePayload: Sendable {
    case text(String, subject: String?)
    case image(Data, mime: String, caption: String?)
}

/// Handing a payload to the share sheet needs a presenter, which the skills
/// layer deliberately doesn't own — the UI wave wires a real one up.
protocol SharePresenting: Sendable {
    func present(_ payload: SharePayload) async throws -> Bool
}

// MARK: - Device + battery

protocol DeviceInfoProviding: Sendable {
    func info() async -> [String: String]
}

struct BatterySnapshot: Sendable {
    /// 0–100, or -1 when the simulator/OS won't say.
    let level: Int
    /// `charging` / `full` / `discharging` / `unknown` — the wire values the
    /// Flutter client sent, so the server-side prompt reads the same.
    let state: String
}

protocol BatteryReading: Sendable {
    func snapshot() async -> BatterySnapshot
}

// MARK: - Haptics

protocol Vibrating: Sendable {
    /// False on a device with no haptic engine (iPad, simulator).
    var isAvailable: Bool { get }
    /// One buzz. iOS has no public arbitrary-duration vibration API, so the
    /// `vibrate` skill turns a duration/pattern into a count of these.
    func buzz() async
}

// MARK: - Location

struct LocationFix: Sendable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    let timestamp: Date
}

protocol LocationFixing: Sendable {
    /// One-shot fix. Throws `SkillError.permissionDenied` / `.unavailable`.
    func oneShot(timeout: TimeInterval) async throws -> LocationFix
}

// MARK: - Camera / photo library

enum PhotoSource: Sendable { case camera, library }

struct CapturedImage: Sendable {
    let data: Data
    let mime: String
}

protocol PhotoPicking: Sendable {
    /// Nil when the user cancelled.
    func pick(_ source: PhotoSource) async throws -> CapturedImage?
}

// MARK: - Speech + audio

protocol SpeechSynthesizing: Sendable {
    func speak(_ text: String, voice: String, locale: String) async throws -> Bool
}

struct RecordedAudio: Sendable {
    let data: Data
    let mime: String
    let seconds: Int
}

protocol AudioRecording: Sendable {
    func record(seconds: Int) async throws -> RecordedAudio
}

/// Playing a clip the agent generated (`play_audio`).
protocol AudioPlaying: Sendable {
    func play(data: Data, volume: Double) async throws
    func play(url: URL, volume: Double) async throws
}

// MARK: - Calendar

struct CalendarEventRecord: Sendable, Equatable {
    let title: String
    let notes: String
    let location: String
    let start: Date?
    let end: Date?
    let allDay: Bool
    let calendar: String
}

struct CalendarEventDraft: Sendable, Equatable {
    let title: String
    let notes: String
    let location: String
    let start: Date
    let end: Date
    let allDay: Bool
}

protocol CalendarAccessing: Sendable {
    /// False when the user denied it; throws when the request failed.
    func requestAccess() async throws -> Bool
    func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventRecord]
    /// Returns the created event's identifier.
    func add(_ draft: CalendarEventDraft) async throws -> String
}

// MARK: - Torch

protocol Torching: Sendable {
    func setTorch(on: Bool) async throws -> Bool
}

// MARK: - Health

struct HealthSample: Sendable {
    var value: Double? = nil
    var unit: String? = nil
    var category: Int? = nil
    var activity: String? = nil
    var durationSeconds: Double? = nil
    var start: Date
    var end: Date

    /// The JSON shape `read_healthkit` returned from the Flutter client.
    var json: [String: Any] {
        var out: [String: Any] = [
            "start": ISO8601DateFormatter().string(from: start),
            "end": ISO8601DateFormatter().string(from: end),
        ]
        if let value { out["value"] = value }
        if let unit { out["unit"] = unit }
        if let category { out["value"] = category }
        if let activity { out["activity"] = activity }
        if let durationSeconds { out["duration_s"] = durationSeconds }
        return out
    }
}

protocol HealthReading: Sendable {
    func read(metric: String, days: Int) async throws -> [HealthSample]
}

// MARK: - SMS composer

enum SmsComposeOutcome: Sendable, Equatable {
    case sent
    case cancelled
    case failed(String)
    case unavailable(String)

    /// The `{shown, sent, …}` map the Flutter bridge returned.
    var json: [String: Any] {
        switch self {
        case .sent:                return ["shown": true, "sent": true]
        case .cancelled:           return ["shown": true, "sent": false, "cancelled": true]
        case .failed(let m):       return ["shown": true, "sent": false, "error": m]
        case .unavailable(let m):  return ["shown": false, "error": m]
        }
    }
}

protocol SmsComposing: Sendable {
    func compose(number: String, message: String) async throws -> SmsComposeOutcome
}

// MARK: - Opening another app

struct AppOpenOutcome: Sendable, Equatable {
    var launched: Bool
    var schemeURL: String?
    var matched: String?
    var error: String?

    var json: [String: Any] {
        var out: [String: Any] = ["launched": launched]
        if let schemeURL { out["scheme_url"] = schemeURL }
        if let matched { out["matched"] = matched }
        if let error { out["error"] = error }
        return out
    }
}

protocol AppOpening: Sendable {
    func open(appName: String, schemeURL: String) async -> AppOpenOutcome
}

// MARK: - Shortcuts

struct ShortcutOutcome: Sendable, Equatable {
    var ran: Bool
    var launched: Bool = false
    var result: String?
    var error: String?
    /// Set when the Shortcut launched but produced no callback in time.
    var note: String?
}

protocol ShortcutRunning: Sendable {
    /// `awaitResult: false` is "launch" mode — omit the x-callback so iOS
    /// leaves the user in whatever app the Shortcut opens.
    func run(name: String, input: String, timeoutSeconds: Int, awaitResult: Bool) async -> ShortcutOutcome
    /// Best-effort list of the user's Shortcuts; nil when iOS won't say (it
    /// won't, today — kept so the skill's contract doesn't change later).
    func installedNames() async -> [String]?
    /// Open the Shortcuts app on a new-shortcut editor or an import prompt.
    func openEditor(importURL: String, suggestedName: String) async -> Bool
}
