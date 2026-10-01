import XCTest
@testable import JarvisCopilot

/// `media_control`: play / pause / next / previous for whatever app is playing,
/// with play and pause checked against whether another app is making sound, so
/// a pause never starts music that wasn't on.
@MainActor
final class MediaControlSkillTests: XCTestCase {

    /// Scripted answers: `playing` is consumed one per question, the last one repeating.
    final class FakeMedia: MediaControlling, @unchecked Sendable {
        var playing: [Bool]
        var accepts = true
        var sent: [MediaCommand] = []
        var info: NowPlaying?
        var infoAfterSend: NowPlaying?

        init(playing: Bool...) { self.playing = playing }

        func othersPlaying() async -> Bool {
            playing.count > 1 ? playing.removeFirst() : playing[0]
        }

        func send(_ command: MediaCommand) async -> Bool {
            sent.append(command)
            if let next = infoAfterSend { info = next }
            return accepts
        }

        func nowPlaying() async -> NowPlaying? { info }
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

    func testPauseWithNothingPlayingSendsNothing() async throws {
        let media = FakeMedia(playing: false)
        let out = try await run(media, "pause")
        XCTAssertEqual(media.sent, [])
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["changed"] as? Bool, false)
        XCTAssertEqual(out["playing"] as? Bool, false)
    }

    func testPlayWhileAlreadyPlayingSendsNothing() async throws {
        let media = FakeMedia(playing: true)
        let out = try await run(media, "play")
        XCTAssertEqual(media.sent, [])
        XCTAssertEqual(out["changed"] as? Bool, false)
    }

    func testPauseWhilePlayingSendsPauseAndConfirmsSilence() async throws {
        let media = FakeMedia(playing: true, false)
        let out = try await run(media, "pause")
        XCTAssertEqual(media.sent, [.pause])
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["changed"] as? Bool, true)
        XCTAssertEqual(out["playing"] as? Bool, false)
    }

    func testPauseThatDoesNotTakeIsReportedAsFailed() async throws {
        let media = FakeMedia(playing: true)
        let out = try await run(media, "pause")
        XCTAssertEqual(media.sent, [.pause])
        XCTAssertEqual(out["ok"] as? Bool, false)
        XCTAssertEqual(out["playing"] as? Bool, true)
        XCTAssertNotNil(out["error"])
    }

    func testToggleSendsTheExplicitOppositeCommand() async throws {
        let playing = FakeMedia(playing: true, false)
        _ = try await run(playing, "toggle")
        XCTAssertEqual(playing.sent, [.pause])

        let silent = FakeMedia(playing: false, true)
        let out = try await run(silent, "toggle")
        XCTAssertEqual(silent.sent, [.play])
        XCTAssertEqual(out["playing"] as? Bool, true)
    }

    func testNextReportsWhatIsPlayingAfterTheSkip() async throws {
        let media = FakeMedia(playing: true)
        media.info = NowPlaying(title: "Song A", artist: "X", album: nil, app: "com.spotify.client")
        media.infoAfterSend = NowPlaying(title: "Song B", artist: "X", album: nil, app: "com.spotify.client")
        let out = try await run(media, "next")
        XCTAssertEqual(media.sent, [.next])
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual((out["now_playing"] as? [String: Any])?["title"] as? String, "Song B")
    }

    func testPreviousSendsPrevious() async throws {
        let media = FakeMedia(playing: true)
        _ = try await run(media, "previous")
        XCTAssertEqual(media.sent, [.previous])
    }

    func testARefusedCommandIsAFailure() async throws {
        let media = FakeMedia(playing: true)
        media.accepts = false
        let out = try await run(media, "next")
        XCTAssertEqual(out["ok"] as? Bool, false)
        XCTAssertNotNil(out["error"])
    }

    func testStatusSaysWhatIsPlaying() async throws {
        let media = FakeMedia(playing: true)
        media.info = NowPlaying(title: "Song A", artist: "Band", album: "LP", app: "com.apple.Music")
        let out = try await run(media, "status")
        XCTAssertEqual(media.sent, [])
        XCTAssertEqual(out["playing"] as? Bool, true)
        let now = out["now_playing"] as? [String: Any]
        XCTAssertEqual(now?["title"] as? String, "Song A")
        XCTAssertEqual(now?["artist"] as? String, "Band")
        XCTAssertEqual(now?["app"] as? String, "com.apple.Music")
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

    func testThePhoneAdvertisesIt() {
        let (boundaries, _) = PhoneSkills.Boundaries.mocked()
        XCTAssertTrue(PhoneSkills.all(boundaries).contains { $0.name == "media_control" })
    }
}
