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
}
