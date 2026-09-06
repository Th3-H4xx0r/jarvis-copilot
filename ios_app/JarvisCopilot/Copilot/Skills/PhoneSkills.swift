import Foundation

/// Everything the phone itself can do, and the wiring that puts it on the
/// existing Jarvis bridge.
///
/// This is the assembly point the Flutter client's `skills/common.dart`
/// `everything` getter played: it names the boundary implementations once, and
/// every skill above stays a pure function of its boundary.
@MainActor
enum PhoneSkills {

    /// The platform implementations a build uses. Swap any of them in a test (or
    /// in a preview) without touching a skill.
    struct Boundaries {
        var clipboard: any Clipboarding = DefaultClipboard()
        var urls: any URLOpening = DefaultURLOpener()
        var apps: any AppOpening = DefaultAppOpener()
        var notifier: any Notifying = DefaultNotifier()
        var share: any SharePresenting = DefaultSharePresenter()
        var deviceInfo: any DeviceInfoProviding = DefaultDeviceInfo()
        var battery: any BatteryReading = DefaultBattery()
        var haptics: any Vibrating = DefaultHaptics()
        var torch: any Torching = DefaultTorch()
        var location: any LocationFixing = DefaultLocationFixer()
        var photos: any PhotoPicking = UnavailablePhotoPicker()
        var speech: any SpeechSynthesizing = DefaultSpeechSynthesizer()
        var recorder: any AudioRecording = DefaultAudioRecorder()
        var player: any AudioPlaying = DefaultAudioPlayer()
        var contacts: any ContactsStore = DefaultContactsStore()
        var calendars: any CalendarAccessing = DefaultCalendarAccess()
        var health: any HealthReading = Self.defaultHealthReader()
        var shortcuts: any ShortcutRunning = DefaultShortcutRunner()
        var sms: any SmsComposing = Self.defaultSmsComposer()

        init() {}

        private static func defaultHealthReader() -> any HealthReading {
            #if canImport(HealthKit)
            return DefaultHealthReader()
            #else
            return UnavailableHealthReader()
            #endif
        }

        private static func defaultSmsComposer() -> any SmsComposing {
            #if canImport(MessageUI)
            return MainActor.assumeIsolated { DefaultSmsComposer() }
            #else
            return UnavailableSmsComposer()
            #endif
        }
    }

    /// The full catalogue, in the order it is advertised.
    static func all(_ b: Boundaries = Boundaries()) -> [any LocalSkill] {
        [
            SystemSkills.openURL(b.urls),
            SystemSkills.openApp(b.apps, shortcuts: b.shortcuts),
            SystemSkills.notify(b.notifier),
            SystemSkills.clipboardRead(b.clipboard),
            SystemSkills.clipboardWrite(b.clipboard),
            SystemSkills.shareText(b.share),
            SystemSkills.shareImage(b.share),
            SystemSkills.deviceInfo(b.deviceInfo),
            SystemSkills.batteryLevel(b.battery),
            SystemSkills.vibrate(b.haptics),
            SystemSkills.flashlightOn(b.torch),
            SystemSkills.flashlightOff(b.torch),
            SystemSkills.makeCall(b.urls),
            MediaSkills.getLocation(b.location),
            MediaSkills.takePhoto(b.photos),
            MediaSkills.pickPhoto(b.photos),
            MediaSkills.textToSpeech(b.speech),
            MediaSkills.recordAudio(b.recorder),
            MediaSkills.playAudio(b.player),
            DataSkills.readContacts(b.contacts),
            DataSkills.addCalendarEvent(b.calendars),
            DataSkills.listCalendarEvents(b.calendars),
            DataSkills.setAlarm(b.notifier),
            DataSkills.readHealth(b.health),
            IOSSkills.sendSMS(b.sms),
            IOSSkills.runShortcut(b.shortcuts),
            IOSSkills.shortcutsList(b.shortcuts),
            IOSSkills.createShortcut(b.shortcuts),
            IOSSkills.phoneControl(b.shortcuts, contacts: b.contacts, sms: b.sms),
            IOSSkills.phoneCapabilities(),
        ]
    }

    /// Populate the skill registry and put the phone in `DeviceRegistry` so the
    /// existing bridge advertises it. Idempotent.
    ///
    /// TODO(app-wave): call this once at launch (`JarvisCopilotApp.init` or the
    /// first `.task`), and after it call `BridgeClient.shared.sendRegistration()`
    /// if the socket is already up so the new skills are advertised immediately.
    @discardableResult
    static func install(boundaries: Boundaries = Boundaries(),
                        registry: SkillRegistry = .shared,
                        devices: DeviceRegistry = .shared,
                        runner: InvokeRunner? = nil) -> PhoneDevice {
        registry.register(all(boundaries))
        // A registry other than the shared one needs its own runner, or the ACL
        // and the log would be read off a catalogue the phone isn't using.
        let runner = runner ?? (registry === SkillRegistry.shared
                                ? .shared : InvokeRunner(registry: registry))
        let phone = PhoneDevice(registry: registry, runner: runner)
        devices.register(phone)
        return phone
    }
}

/// Fallback when MessageUI isn't available (macOS / Catalyst).
final class UnavailableSmsComposer: SmsComposing {
    func compose(number: String, message: String) async throws -> SmsComposeOutcome {
        .unavailable("the Messages composer needs iOS")
    }
}
