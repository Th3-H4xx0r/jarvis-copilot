import XCTest
@testable import Jarvis

/// Now playing from Apple Music and Spotify (their distributed notifications),
/// the progress bar's math, and the AppleScript the controls send.
final class MusicTests: XCTestCase {

    func testAppleMusicNotificationDecodes() {
        let n = NowPlaying(player: .music, info: [
            "Name": "Teardrop", "Artist": "Massive Attack", "Album": "Mezzanine",
            "Player State": "Playing", "Total Time": 330_000, "Persistent ID": "ABC",
        ], at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(n?.title, "Teardrop")
        XCTAssertEqual(n?.artist, "Massive Attack")
        XCTAssertEqual(n?.duration, 330)
        XCTAssertEqual(n?.isPlaying, true)
        XCTAssertNil(NowPlaying(player: .music, info: ["Player State": "Stopped"], at: Date()))
    }

    func testSpotifyNotificationDecodes() {
        let n = NowPlaying(player: .spotify, info: [
            "Name": "Windowlicker", "Artist": "Aphex Twin", "Album": "Windowlicker",
            "Player State": "Paused", "Duration": 367_000, "Playback Position": 42.5,
            "Track ID": "spotify:track:1",
        ], at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(n?.duration, 367)
        XCTAssertEqual(n?.isPlaying, false)
        XCTAssertEqual(n?.position(at: Date(timeIntervalSince1970: 500)), 42.5)  // paused: frozen
    }

    func testPositionRunsFromItsAnchorWhilePlayingAndStopsAtTheEnd() {
        var n = NowPlaying(player: .spotify, info: ["Name": "A", "Player State": "Playing",
                                                    "Duration": 100_000, "Playback Position": 10.0],
                           at: Date(timeIntervalSince1970: 0))!
        XCTAssertEqual(n.position(at: Date(timeIntervalSince1970: 5)), 15, accuracy: 0.001)
        XCTAssertEqual(n.position(at: Date(timeIntervalSince1970: 500)), 100)
        XCTAssertEqual(n.progress(at: Date(timeIntervalSince1970: 40)), 0.5, accuracy: 0.001)
        n.anchor(position: 70, at: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(n.position(at: Date(timeIntervalSince1970: 41)), 71, accuracy: 0.001)
    }

    func testControlScripts() {
        XCTAssertEqual(MusicScript.command(.playPause, player: .music), "tell application \"Music\" to playpause")
        XCTAssertEqual(MusicScript.command(.next, player: .spotify), "tell application \"Spotify\" to next track")
        XCTAssertEqual(MusicScript.command(.seek(61.25), player: .spotify),
                       "tell application \"Spotify\" to set player position to 61.25")
        XCTAssertEqual(MusicScript.command(.volume(140), player: .music),
                       "tell application \"Music\" to set sound volume to 100")
        XCTAssertEqual(MusicScript.command(.shuffle(true), player: .music),
                       "tell application \"Music\" to set shuffle enabled to true")
        XCTAssertEqual(MusicScript.command(.shuffle(false), player: .spotify),
                       "tell application \"Spotify\" to set shuffling to false")
        XCTAssertEqual(MusicScript.command(.repeating(true), player: .music),
                       "tell application \"Music\" to set song repeat to all")
        XCTAssertEqual(MusicScript.command(.repeating(false), player: .spotify),
                       "tell application \"Spotify\" to set repeating to false")
    }

    func testTimeLabels() {
        XCTAssertEqual(NowPlaying.clock(65), "1:05")
        XCTAssertEqual(NowPlaying.clock(3_725), "1:02:05")
        XCTAssertEqual(NowPlaying.clock(-3), "0:00")
    }
}
