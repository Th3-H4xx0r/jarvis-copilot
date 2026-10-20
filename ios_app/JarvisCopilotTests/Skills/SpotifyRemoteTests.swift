import XCTest
@testable import JarvisCopilot

/// The server's hand-off to the Spotify app on this phone (Spotify's iOS SDK, App Remote): plays
/// sent through the Web API never start on his iPhone in the car (2026-10-18).
@MainActor
final class SpotifyRemoteTests: XCTestCase {

    private func skill() throws -> any LocalSkill {
        let (boundaries, _) = PhoneSkills.Boundaries.mocked()
        return try XCTUnwrap(PhoneSkills.all(boundaries).first { $0.name == SpotifyRemote.skillName })
    }

    func testItRunsWithThePhoneLockedInTheCar() throws {
        XCTAssertFalse(try skill().requiresForeground)
    }

    func testOnlyASpotifyURIWithATokenAndClientIsPlayed() async throws {
        let skill = try skill()
        for bad: [String: Any] in [
            ["uri": "https://example.com", "token": "t", "client_id": "c"],
            ["uri": "spotify:track:1", "token": "", "client_id": "c"],
            ["uri": "spotify:track:1", "token": "t"],
        ] {
            do {
                _ = try await skill.run(bad)
                XCTFail("played \(bad)")
            } catch {}
        }
    }

    // MARK: Playing, or waking Spotify on the song

    private final class FakeSpotifyApp: SpotifyAppConnection {
        var isConnected = false
        var connectError: Error?
        var wake: URL? = URL(string: "spotify-action://authorize?response_type=token&play_uri=spotify:track:1")
        var played: [String] = []
        var askedToWake: [String] = []

        func connect(token: String, timeout: Duration) async throws {
            if let connectError { throw connectError }
            isConnected = true
        }
        func play(_ uri: String) async throws { played.append(uri) }
        func wakeLink(playing uri: String) async -> URL? { askedToWake.append(uri); return wake }
        func disconnect() {}
    }

    private struct Refused: Error {}

    private func remote(_ app: FakeSpotifyApp, opened: @escaping (URL) -> Bool = { _ in true }) -> SpotifyRemote {
        SpotifyRemote(makeConnection: { _ in app }, openWakeLink: { opened($0) })
    }

    func testASpotifyAppThatConnectsPlaysTheSong() async throws {
        let app = FakeSpotifyApp()
        let outcome = try await remote(app).play(uri: "spotify:track:1", token: "t", clientID: "c")
        XCTAssertEqual(outcome, .played)
        XCTAssertEqual(app.played, ["spotify:track:1"])
        XCTAssertEqual(app.askedToWake, [])
    }

    func testASpotifyAppThatWontConnectIsWokenOnTheSong() async throws {
        // 2026-10-20 23:18: Spotify open on the car, not playing — six "Connection attempt
        // failed". It takes a connection only while it plays; its SDK's wake link starts the song.
        let app = FakeSpotifyApp()
        app.connectError = Refused()
        var opened: [URL] = []
        let outcome = try await remote(app) { opened.append($0); return true }
            .play(uri: "spotify:track:1", token: "t", clientID: "c")
        XCTAssertEqual(outcome, .woke)
        XCTAssertEqual(app.askedToWake, ["spotify:track:1"])
        XCTAssertEqual(opened, [app.wake])
        XCTAssertEqual(app.played, [])
    }

    func testWithNoWakeLinkTheConnectErrorStands() async {
        let app = FakeSpotifyApp()
        app.connectError = Refused()
        app.wake = nil
        do {
            _ = try await remote(app).play(uri: "spotify:track:1", token: "t", clientID: "c")
            XCTFail("said it played")
        } catch {
            XCTAssertTrue(error is Refused)
        }
    }

    func testAWakeLinkThatDoesntOpenIsAnError() async {
        let app = FakeSpotifyApp()
        app.connectError = Refused()
        do {
            _ = try await remote(app) { _ in false }.play(uri: "spotify:track:1", token: "t", clientID: "c")
            XCTFail("said it woke Spotify")
        } catch {}
    }

    // MARK: The SDK's wake link

    func testTheSDKsWakeLinkIsHandedBackNotOpened() async {
        // With the phone locked in the car UIApplication can't open it; the car's screen can.
        let link = URL(string: "spotify-action://authorize?response_type=token&client_id=c")!
        let caught = await SpotifyWakeLink.capture { done in
            UIApplication.shared.open(link, options: [:], completionHandler: done)
        }
        XCTAssertEqual(caught, link)
    }

    func testAnSDKThatOpensNothingGivesNoLink() async {
        let caught = await SpotifyWakeLink.capture { done in done(false) }
        XCTAssertNil(caught)
    }

    func testTheAppMayAskWhetherSpotifyCanBeWoken() throws {
        // The SDK checks canOpenURL("spotify-action:") first; an undeclared scheme says no.
        let schemes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])
        XCTAssertTrue(schemes.contains("spotify-action"))
    }
}
