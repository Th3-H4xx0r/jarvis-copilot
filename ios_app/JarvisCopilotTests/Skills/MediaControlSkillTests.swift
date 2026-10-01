import XCTest
@testable import JarvisCopilot

/// `media_control`: play / pause / next / previous for whatever is playing. Apple Music is
/// driven directly; any other app goes through the "JC …" Shortcuts. Play and pause are
/// checked against whether another app is making sound, so a pause never starts music.
@MainActor
final class MediaControlSkillTests: XCTestCase {

    /// Scripted answers: `playing` is consumed one per question, the last one repeating.
    final class FakeMedia: MediaControlling, @unchecked Sendable {
        var playing: [Bool]
        var music: MusicAppState?
        var toMusic: [MediaCommand] = []
        var shortcuts: [MediaCommand] = []
        var shortcutResult: [String: Any] = ["ran": true, "shortcut": "JC Play Pause"]
        var song: NowPlaying?
        var songAfterSkip: NowPlaying?

        init(playing: Bool..., music: MusicAppState? = nil) {
            self.playing = playing
            self.music = music
        }

        func othersPlaying() async -> Bool { playing.count > 1 ? playing.removeFirst() : playing[0] }
        func musicState() async -> MusicAppState? { music }

        func sendToMusic(_ command: MediaCommand) async {
            toMusic.append(command)
            if let next = songAfterSkip { song = next }
        }

        func musicNowPlaying() async -> NowPlaying? { song }

        func runShortcut(_ command: MediaCommand) async -> [String: Any] {
            shortcuts.append(command)
            return shortcutResult
        }
    }

    private func run(_ media: FakeMedia, _ action: String) async throws -> [String: Any] {
        try await MediaSkills.mediaControl(media, settle: 0).run(["action": action])
    }

    func testSchemaOffersEveryActionAndRunsInTheBackground() {
        let skill = MediaSkills.mediaControl(FakeMedia(playing: false))
        XCTAssertEqual(skill.name, "media_control")
        XCTAssertFalse(skill.requiresForeground)
        let properties = skill.inputSchema["properties"] as? [String: Any]
        let action = properties?["action"] as? [String: Any]
        XCTAssertEqual(Set(action?["enum"] as? [String] ?? []),
                       ["play", "pause", "toggle", "next", "previous", "status"])
        XCTAssertEqual(skill.inputSchema["required"] as? [String], ["action"])
    }

    func testPauseWithNothingPlayingDoesNothing() async throws {
        let media = FakeMedia(playing: false, music: .paused)
        let out = try await run(media, "pause")
        XCTAssertEqual(media.toMusic, [])
        XCTAssertEqual(media.shortcuts, [])
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["changed"] as? Bool, false)
        XCTAssertEqual(out["playing"] as? Bool, false)
    }

    func testPlayWhileAlreadyPlayingDoesNothing() async throws {
        let media = FakeMedia(playing: true)
        let out = try await run(media, "play")
        XCTAssertEqual(media.shortcuts, [])
        XCTAssertEqual(out["changed"] as? Bool, false)
    }

    func testPausingAppleMusicGoesStraightToMusic() async throws {
        let media = FakeMedia(playing: true, false, music: .playing)
        let out = try await run(media, "pause")
        XCTAssertEqual(media.toMusic, [.pause])
        XCTAssertEqual(media.shortcuts, [])
        XCTAssertEqual(out["via"] as? String, "apple_music")
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["playing"] as? Bool, false)
    }

    func testPausingAnotherAppRunsTheShortcut() async throws {
        let media = FakeMedia(playing: true, false, music: .stopped)
        let out = try await run(media, "pause")
        XCTAssertEqual(media.toMusic, [])
        XCTAssertEqual(media.shortcuts, [.pause])
        XCTAssertEqual(out["via"] as? String, "shortcut")
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["playing"] as? Bool, false)
    }

    func testWithoutMusicAccessEverythingGoesThroughTheShortcut() async throws {
        let media = FakeMedia(playing: true, false, music: nil)
        _ = try await run(media, "pause")
        XCTAssertEqual(media.shortcuts, [.pause])
    }

    func testAShortcutQueuedBehindANotificationIsReportedAsQueued() async throws {
        let media = FakeMedia(playing: true)
        media.shortcutResult = ["queued": true, "note": "Sent to your phone — tap the notification to run it."]
        let out = try await run(media, "pause")
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["queued"] as? Bool, true)
        XCTAssertNotNil(out["note"])
        XCTAssertNil(out["error"])
    }

    func testAShortcutThatDidNotRunIsAFailure() async throws {
        let media = FakeMedia(playing: true)
        media.shortcutResult = ["ran": false, "error": "Could not open Shortcuts"]
        let out = try await run(media, "next")
        XCTAssertEqual(out["ok"] as? Bool, false)
        XCTAssertEqual(out["error"] as? String, "Could not open Shortcuts")
    }

    func testAudioThatLingersAfterAPauseIsNotAFailure() async throws {
        // Players hold the audio session for a moment after pausing; the command worked.
        let media = FakeMedia(playing: true, music: .playing)
        let out = try await run(media, "pause")
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["confirmed"] as? Bool, false)
        XCTAssertNil(out["error"])
    }

    func testASecondPauseWhileTheAudioLingersDoesNotToggleItBackOn() async throws {
        // "JC Play Pause" is a toggle, so trusting the lingering audio would resume the music.
        let media = FakeMedia(playing: true, music: .stopped)
        let skill = MediaSkills.mediaControl(media, settle: 0)
        _ = try await skill.run(["action": "pause"])
        let out = try await skill.run(["action": "pause"])
        XCTAssertEqual(media.shortcuts, [.pause])
        XCTAssertEqual(out["changed"] as? Bool, false)
    }

    func testOnceTheMomentPassesTheAudioIsBelievedAgain() async throws {
        var clock = Date(timeIntervalSince1970: 0)
        let media = FakeMedia(playing: true, music: .stopped)
        let skill = MediaSkills.mediaControl(media, settle: 0, now: { clock })
        _ = try await skill.run(["action": "pause"])
        clock += 60
        _ = try await skill.run(["action": "pause"])
        XCTAssertEqual(media.shortcuts, [.pause, .pause])
    }

    func testToggleFromSilenceResumesThroughTheShortcut() async throws {
        // Nothing is playing, so whichever app last had Now Playing should resume —
        // only the system Play/Pause (the Shortcut) knows which one that is.
        let media = FakeMedia(playing: false, true, music: .paused)
        let out = try await run(media, "toggle")
        XCTAssertEqual(media.toMusic, [])
        XCTAssertEqual(media.shortcuts, [.play])
        XCTAssertEqual(out["playing"] as? Bool, true)
    }

    func testNextOnAppleMusicSaysWhatIsPlayingNow() async throws {
        let media = FakeMedia(playing: true, music: .playing)
        media.song = NowPlaying(title: "Song A", artist: "X", album: nil, app: "com.apple.Music")
        media.songAfterSkip = NowPlaying(title: "Song B", artist: "X", album: nil, app: "com.apple.Music")
        let out = try await run(media, "next")
        XCTAssertEqual(media.toMusic, [.next])
        XCTAssertEqual(out["via"] as? String, "apple_music")
        XCTAssertEqual((out["now_playing"] as? [String: Any])?["title"] as? String, "Song B")
    }

    func testSkippingInAnotherAppRunsTheShortcut() async throws {
        let media = FakeMedia(playing: true, music: .stopped)
        let next = try await run(media, "next")
        _ = try await run(media, "previous")
        XCTAssertEqual(media.toMusic, [])
        XCTAssertEqual(media.shortcuts, [.next, .previous])
        XCTAssertEqual(next["via"] as? String, "shortcut")
        XCTAssertEqual(next["ok"] as? Bool, true)
    }

    func testStatusNamesTheSongWhenAppleMusicIsPlaying() async throws {
        let media = FakeMedia(playing: true, music: .playing)
        media.song = NowPlaying(title: "Song A", artist: "Band", album: "LP", app: "com.apple.Music")
        let out = try await run(media, "status")
        XCTAssertEqual(media.toMusic, [])
        XCTAssertEqual(out["playing"] as? Bool, true)
        XCTAssertEqual(out["player"] as? String, "Apple Music")
        let now = out["now_playing"] as? [String: Any]
        XCTAssertEqual(now?["title"] as? String, "Song A")
        XCTAssertEqual(now?["artist"] as? String, "Band")
    }

    func testStatusSaysAnotherAppWhenMusicIsNotTheOnePlaying() async throws {
        let out = try await run(FakeMedia(playing: true, music: .paused), "status")
        XCTAssertEqual(out["player"] as? String, "another app")
        XCTAssertNil(out["now_playing"])
    }

    func testAnUnknownActionIsABadArgument() async {
        do {
            _ = try await run(FakeMedia(playing: false), "rewind")
            XCTFail("expected a bad argument")
        } catch let error as SkillError {
            guard case .badArgument = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRingMediaGesturesRunTheNativeSkill() {
        for (id, action) in [("play_pause", "toggle"), ("next_track", "next"), ("previous_track", "previous")] {
            let option = RingActionCatalogue.option(id)
            XCTAssertEqual(option?.skill, "media_control", id)
            XCTAssertEqual(option?.arguments["action"], action, id)
        }
    }

    func testThePhoneAdvertisesIt() {
        let (boundaries, _) = PhoneSkills.Boundaries.mocked()
        XCTAssertTrue(PhoneSkills.all(boundaries).contains { $0.name == "media_control" })
    }
}
