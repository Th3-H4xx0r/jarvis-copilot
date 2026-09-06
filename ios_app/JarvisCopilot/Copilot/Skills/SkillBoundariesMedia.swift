import AVFoundation
import Foundation
import UserNotifications

/// Production implementations of the notification / speech / audio / camera
/// boundaries.

// MARK: - Local notifications

/// `notify`, `set_alarm` and the deferred-action banner all go through here.
final class DefaultNotifier: Notifying {
    /// The `userInfo` key the deferred-action payload travels under.
    static let payloadKey = "jcActionPayload"

    func requestAuthorization() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            // Throwing here means the prompt itself failed (no usage string,
            // provisional-auth error); that must not read as "the user said no".
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    @discardableResult
    func post(_ request: LocalNotificationRequest) async throws -> String {
        guard try await requestAuthorization() else {
            throw SkillError.permissionDenied("notifications")
        }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        if request.sound { content.sound = .default }
        if request.timeSensitive { content.interruptionLevel = .timeSensitive }
        if let payload = request.payload { content.userInfo = [Self.payloadKey: payload] }

        var trigger: UNNotificationTrigger?
        if let at = request.at {
            guard at.timeIntervalSinceNow > 0 else {
                throw SkillError.badArgument("that time has already passed")
            }
            // A calendar trigger fires at the wall-clock time (the Flutter
            // client's `absoluteTime` interpretation); an interval trigger would
            // drift if the user changed time zones before it fired.
            let parts = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: at)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        }
        let identifier = request.identifier ?? UUID().uuidString
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        return identifier
    }

    func cancel(identifiers: [String]) async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pending() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }
}

// MARK: - Text to speech

final class DefaultSpeechSynthesizer: SpeechSynthesizing {
    /// The synthesiser has to outlive the call or iOS cuts the utterance off.
    @MainActor private static let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, voice: String, locale: String) async throws -> Bool {
        guard !text.isEmpty else { throw SkillError.badArgument("text required") }
        return await MainActor.run {
            let utterance = AVSpeechUtterance(string: text)
            // A voice identifier wins; otherwise fall back to the locale, which
            // is what the Flutter client's `{name, locale}` pair amounted to.
            if !voice.isEmpty, let match = AVSpeechSynthesisVoice.speechVoices().first(where: {
                $0.identifier == voice || $0.name.caseInsensitiveCompare(voice) == .orderedSame
            }) {
                utterance.voice = match
            } else if !locale.isEmpty {
                utterance.voice = AVSpeechSynthesisVoice(language: locale)
            }
            Self.synthesizer.speak(utterance)
            return true
        }
    }
}

// MARK: - Recording

final class DefaultAudioRecorder: AudioRecording {
    /// A clip capture is the session's THIRD client, so it goes through
    /// `AudioSessionArbiter` like the other two rather than writing
    /// `AVAudioSession` itself.
    ///
    /// Writing it directly was a silent way to break both of them: the category
    /// it set (`.playAndRecord`/`.default`) outlived the clip, so the next voice
    /// turn inherited a session with no echo cancellation and no speakerphone
    /// route (the reply came out of the earpiece and the barge-in detector cut
    /// off our own voice), and a `setActive` here could equally be undone by
    /// whoever wrote last. The arbiter holds the union instead: a turn already in
    /// progress keeps `.videoChat` (which records perfectly well), and the
    /// release at the end deactivates nothing while the keepalive still needs the
    /// session.
    func record(seconds: Int) async throws -> RecordedAudio {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SkillError.permissionDenied("microphone")
        }
        try await MainActor.run { try AudioSessionArbiter.shared.hold(.recording) }
        do {
            let audio = try await capture(seconds: seconds)
            await releaseSession()
            return audio
        } catch {
            // Never leave the claim behind: a held `.recording` would pin the
            // whole process to `.playAndRecord` for the rest of the launch.
            await releaseSession()
            throw error
        }
    }

    private func capture(seconds: Int) async throws -> RecordedAudio {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jc-rec-\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ])
        guard recorder.record() else { throw SkillError.failed("recorder refused to start") }
        defer { try? FileManager.default.removeItem(at: url) }
        try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
        recorder.stop()
        let data = try Data(contentsOf: url)
        return RecordedAudio(data: data, mime: "audio/mp4", seconds: seconds)
    }

    private func releaseSession() async {
        await MainActor.run { try? AudioSessionArbiter.shared.release(.recording) }
    }
}

// MARK: - Playback

final class DefaultAudioPlayer: AudioPlaying {
    /// Retained for the life of the clip; a local `AVAudioPlayer` would be
    /// deallocated mid-playback.
    @MainActor private static var player: AVAudioPlayer?

    func play(data: Data, volume: Double) async throws {
        try await MainActor.run {
            let player = try AVAudioPlayer(data: data)
            player.volume = Float(min(max(volume, 0), 1))
            Self.player = player
            guard player.play() else { throw SkillError.failed("playback refused to start") }
        }
    }

    func play(url: URL, volume: Double) async throws {
        let (data, _) = try await URLSession.shared.data(from: url)
        try await play(data: data, volume: volume)
    }
}

// MARK: - Camera / library

/// `take_photo` / `pick_photo` need a UI presenter (`UIImagePickerController` or
/// `PHPickerViewController`), which the skills wave deliberately doesn't own.
///
/// TODO(ui-wave): replace with a presenter that pushes the picker from the
/// active scene and resumes a continuation with the chosen image. The skill,
/// its schema and its result shape are already final — only this boundary
/// changes.
final class UnavailablePhotoPicker: PhotoPicking {
    func pick(_ source: PhotoSource) async throws -> CapturedImage? {
        throw SkillError.unavailable(
            "the camera/library picker is not wired up in this build yet")
    }
}
