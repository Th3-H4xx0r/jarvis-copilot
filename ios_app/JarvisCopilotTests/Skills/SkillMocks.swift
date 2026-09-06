import Foundation
@testable import JarvisCopilot

/// Mocks for every phone-skill platform boundary. Plain classes with mutable
/// recording state — the suite is single-threaded, so `@unchecked Sendable` is
/// honest here.

final class MockClipboard: Clipboarding, @unchecked Sendable {
    var stored: String?
    var writes: [String] = []
    init(_ stored: String? = nil) { self.stored = stored }
    func read() async -> String? { stored }
    func write(_ text: String) async { stored = text; writes.append(text) }
}

final class MockNotifier: Notifying, @unchecked Sendable {
    var granted: Bool
    var posted: [LocalNotificationRequest] = []
    var cancelled: [String] = []
    var authorizationRequests = 0
    /// Thrown instead of answering, so a test can tell "the user said no" from
    /// "asking failed".
    var error: Error?

    init(granted: Bool = true) { self.granted = granted }

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if let error { throw error }
        return granted
    }

    @discardableResult
    func post(_ request: LocalNotificationRequest) async throws -> String {
        if let error { throw error }
        guard granted else { throw SkillError.permissionDenied("notifications") }
        posted.append(request)
        return request.identifier ?? "mock-\(posted.count)"
    }

    func cancel(identifiers: [String]) async { cancelled.append(contentsOf: identifiers) }
    func pending() async -> [String] { posted.compactMap(\.identifier) }
}

final class MockURLOpener: URLOpening, @unchecked Sendable {
    var opened: [URL] = []
    var openResult = true
    var canOpenResult = true
    init(openResult: Bool = true) { self.openResult = openResult }
    func canOpen(_ url: URL) async -> Bool { canOpenResult }
    func open(_ url: URL) async -> Bool { opened.append(url); return openResult }
}

final class MockSharePresenter: SharePresenting, @unchecked Sendable {
    var presented: [SharePayload] = []
    var error: Error?
    func present(_ payload: SharePayload) async throws -> Bool {
        if let error { throw error }
        presented.append(payload)
        return true
    }
}

final class MockDeviceInfo: DeviceInfoProviding, @unchecked Sendable {
    var payload: [String: String] = [
        "platform": "ios", "model": "iPhone16,2", "name": "Test iPhone",
        "system": "iOS", "system_version": "17.0", "locale": "en_US",
    ]
    func info() async -> [String: String] { payload }
}

final class MockBattery: BatteryReading, @unchecked Sendable {
    var value = BatterySnapshot(level: 77, state: "discharging")
    func snapshot() async -> BatterySnapshot { value }
}

final class MockHaptics: Vibrating, @unchecked Sendable {
    var isAvailable: Bool
    var buzzes = 0
    init(available: Bool = true) { self.isAvailable = available }
    func buzz() async { buzzes += 1 }
}

final class MockTorch: Torching, @unchecked Sendable {
    var isOn = false
    var error: Error?
    func setTorch(on: Bool) async throws -> Bool {
        if let error { throw error }
        isOn = on
        return on
    }
}

final class MockLocationFixer: LocationFixing, @unchecked Sendable {
    var fix = LocationFix(latitude: 37.33, longitude: -122.03, accuracyMeters: 12,
                          timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    var error: Error?
    func oneShot(timeout: TimeInterval) async throws -> LocationFix {
        if let error { throw error }
        return fix
    }
}

final class MockPhotoPicker: PhotoPicking, @unchecked Sendable {
    var image: CapturedImage?
    var error: Error?
    var requested: [PhotoSource] = []
    init(image: CapturedImage? = nil) { self.image = image }
    func pick(_ source: PhotoSource) async throws -> CapturedImage? {
        requested.append(source)
        if let error { throw error }
        return image
    }
}

final class MockSpeech: SpeechSynthesizing, @unchecked Sendable {
    var spoken: [(text: String, voice: String, locale: String)] = []
    var error: Error?
    func speak(_ text: String, voice: String, locale: String) async throws -> Bool {
        if let error { throw error }
        spoken.append((text, voice, locale))
        return true
    }
}

final class MockRecorder: AudioRecording, @unchecked Sendable {
    var clip = RecordedAudio(data: Data([1, 2, 3]), mime: "audio/mp4", seconds: 5)
    var error: Error?
    var requestedSeconds: Int?
    func record(seconds: Int) async throws -> RecordedAudio {
        requestedSeconds = seconds
        if let error { throw error }
        return RecordedAudio(data: clip.data, mime: clip.mime, seconds: seconds)
    }
}

final class MockAudioPlayer: AudioPlaying, @unchecked Sendable {
    var playedBytes: [Int] = []
    var playedURLs: [URL] = []
    var error: Error?
    func play(data: Data, volume: Double) async throws {
        if let error { throw error }
        playedBytes.append(data.count)
    }
    func play(url: URL, volume: Double) async throws {
        if let error { throw error }
        playedURLs.append(url)
    }
}

final class MockContactsStore: ContactsStore, @unchecked Sendable {
    var granted: Bool
    var records: [ContactRecord]
    var error: Error?
    /// Thrown by `requestAccess` only — a failed prompt is not a denial.
    var accessError: Error?
    var accessRequests = 0

    init(granted: Bool = true, contacts: [ContactRecord] = []) {
        self.granted = granted
        self.records = contacts
    }

    func requestAccess() async throws -> Bool {
        accessRequests += 1
        if let accessError { throw accessError }
        return granted
    }

    func contacts() async throws -> [ContactRecord] {
        if let error { throw error }
        return records
    }
}

final class MockCalendar: CalendarAccessing, @unchecked Sendable {
    var granted: Bool
    var records: [CalendarEventRecord]
    var added: [CalendarEventDraft] = []
    var error: Error?
    /// Thrown by `requestAccess` only — a failed prompt is not a denial.
    var accessError: Error?

    init(granted: Bool = true, events: [CalendarEventRecord] = []) {
        self.granted = granted
        self.records = events
    }

    func requestAccess() async throws -> Bool {
        if let accessError { throw accessError }
        return granted
    }

    func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventRecord] {
        if let error { throw error }
        return Array(records.prefix(limit))
    }

    func add(_ draft: CalendarEventDraft) async throws -> String {
        if let error { throw error }
        added.append(draft)
        return "event-\(added.count)"
    }
}

final class MockHealthReader: HealthReading, @unchecked Sendable {
    var samples: [HealthSample] = []
    var error: Error?
    var requested: (metric: String, days: Int)?
    func read(metric: String, days: Int) async throws -> [HealthSample] {
        requested = (metric, days)
        if let error { throw error }
        return samples
    }
}

final class MockSmsComposer: SmsComposing, @unchecked Sendable {
    var outcome: SmsComposeOutcome = .sent
    var error: Error?
    var composed: [(number: String, message: String)] = []
    func compose(number: String, message: String) async throws -> SmsComposeOutcome {
        composed.append((number, message))
        if let error { throw error }
        return outcome
    }
}

final class MockAppOpener: AppOpening, @unchecked Sendable {
    var outcome = AppOpenOutcome(launched: true, schemeURL: "spotify://", matched: "spotify")
    var requests: [(appName: String, schemeURL: String)] = []
    func open(appName: String, schemeURL: String) async -> AppOpenOutcome {
        requests.append((appName, schemeURL))
        return outcome
    }
}

final class MockShortcutRunner: ShortcutRunning, @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let input: String
        let timeoutSeconds: Int
        let awaitResult: Bool
    }

    var calls: [Call] = []
    var outcome = ShortcutOutcome(ran: true, launched: true, result: "")
    var names: [String]?
    var editorOpened: [(importURL: String, name: String)] = []
    var editorResult = true

    func run(name: String, input: String, timeoutSeconds: Int,
             awaitResult: Bool) async -> ShortcutOutcome {
        calls.append(Call(name: name, input: input, timeoutSeconds: timeoutSeconds,
                          awaitResult: awaitResult))
        return outcome
    }

    func installedNames() async -> [String]? { names }

    func openEditor(importURL: String, suggestedName: String) async -> Bool {
        editorOpened.append((importURL, suggestedName))
        return editorResult
    }
}

/// An engine that reports available (so the router gets past the gate) but
/// generates nothing — the wave that ports a real engine replaces this.
struct MockOnDeviceModel: OnDeviceModel {
    var availabilityValue = OnDeviceAvailability(available: true, engine: "mock")
    var chunks: [String] = []

    func availability() async -> OnDeviceAvailability { availabilityValue }

    func generate(_ request: LocalRequest) -> AsyncThrowingStream<String, Error> {
        let chunks = chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

// MARK: - Test fixtures

extension PhoneSkills.Boundaries {
    /// Every boundary replaced with a mock, so a test can build the whole
    /// catalogue without touching the device.
    @MainActor
    static func mocked() -> (PhoneSkills.Boundaries, MockedBoundaries) {
        let mocks = MockedBoundaries()
        var b = PhoneSkills.Boundaries()
        b.clipboard = mocks.clipboard
        b.urls = mocks.urls
        b.apps = mocks.apps
        b.notifier = mocks.notifier
        b.share = mocks.share
        b.deviceInfo = mocks.deviceInfo
        b.battery = mocks.battery
        b.haptics = mocks.haptics
        b.torch = mocks.torch
        b.location = mocks.location
        b.photos = mocks.photos
        b.speech = mocks.speech
        b.recorder = mocks.recorder
        b.player = mocks.player
        b.contacts = mocks.contacts
        b.calendars = mocks.calendars
        b.health = mocks.health
        b.shortcuts = mocks.shortcuts
        b.sms = mocks.sms
        return (b, mocks)
    }
}

/// Handles on every mock a `PhoneSkills.Boundaries.mocked()` installed.
final class MockedBoundaries {
    let clipboard = MockClipboard("hello")
    let urls = MockURLOpener()
    let apps = MockAppOpener()
    let notifier = MockNotifier()
    let share = MockSharePresenter()
    let deviceInfo = MockDeviceInfo()
    let battery = MockBattery()
    let haptics = MockHaptics()
    let torch = MockTorch()
    let location = MockLocationFixer()
    let photos = MockPhotoPicker(image: CapturedImage(data: Data([9, 9]), mime: "image/jpeg"))
    let speech = MockSpeech()
    let recorder = MockRecorder()
    let player = MockAudioPlayer()
    let contacts = MockContactsStore(contacts: [ContactRecord(name: "Mom", phones: ["+15105550100"])])
    let calendars = MockCalendar()
    let health = MockHealthReader()
    let shortcuts = MockShortcutRunner()
    let sms = MockSmsComposer()
}

// MARK: - Waiting

/// Spin until `condition` holds or the deadline passes, so a test never has to
/// sleep a fixed amount for work another Task is doing. Prefixed with the area
/// because a bare `waitUntil` collides module-wide.
@MainActor
func skillsWaitUntil(timeout: TimeInterval = 2,
                     _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// A store whose writes silently do nothing — a full disk, a protected-data
/// window, a suite that failed to open. Used to prove the registry notices.
final class RefusingKeyValueStore: KeyValueStore, @unchecked Sendable {
    func string(_ key: String) -> String? { nil }
    func bool(_ key: String) -> Bool? { nil }
    func int(_ key: String) -> Int? { nil }
    func data(_ key: String) -> Data? { nil }
    func set(_ value: Any?, forKey key: String) {}
}
