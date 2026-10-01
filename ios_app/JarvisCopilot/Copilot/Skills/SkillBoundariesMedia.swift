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

// MARK: - Other apps' playback

/// Plays, pauses and skips whatever app owns Now Playing through MediaRemote, the private
/// framework behind Control Center's player. There is no public API for another app's
/// playback, so it is loaded at runtime — and iOS may still drop the command, which is why
/// the skill checks `isOtherAudioPlaying` afterwards instead of trusting `send`.
final class DefaultMediaController: MediaControlling {
    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias InfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias AppFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFString?) -> Void) -> Void

    private static let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let framework, let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let sendCommand = symbol("MRMediaRemoteSendCommand", SendFn.self)
    private static let getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", InfoFn.self)
    private static let getApp = symbol("MRMediaRemoteGetNowPlayingApplicationDisplayID", AppFn.self)

    /// MediaRemote's `MRMediaRemoteCommand` numbers.
    private static func code(_ command: MediaCommand) -> UInt32 {
        switch command {
        case .play: return 0
        case .pause: return 1
        case .toggle: return 2
        case .next: return 4
        case .previous: return 5
        }
    }

    func othersPlaying() async -> Bool {
        AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    func send(_ command: MediaCommand) async -> Bool {
        guard let send = Self.sendCommand else { return false }
        return send(Self.code(command), nil)
    }

    func nowPlaying() async -> NowPlaying? {
        var info: NSDictionary?
        var app: String?
        if let getInfo = Self.getInfo {
            info = await Self.ask { reply in getInfo(.global()) { reply($0 as NSDictionary?) } }
        }
        if let getApp = Self.getApp {
            app = await Self.ask { reply in getApp(.global()) { reply($0 as String?) } }
        }
        let text = { (key: String) in info?["kMRMediaRemoteNowPlayingInfo\(key)"] as? String }
        let playing = NowPlaying(title: text("Title"), artist: text("Artist"), album: text("Album"), app: app)
        return playing == NowPlaying() ? nil : playing
    }

    /// MediaRemote answers on a queue — or, when iOS won't let us ask, never; a second is plenty.
    private static func ask<T>(_ start: (@escaping (T?) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var done = false
            let finish = { (value: T?) in
                lock.lock()
                defer { lock.unlock() }
                guard !done else { return }
                done = true
                continuation.resume(returning: value)
            }
            start(finish)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { finish(nil) }
        }
    }
}

// MARK: - Camera / library
