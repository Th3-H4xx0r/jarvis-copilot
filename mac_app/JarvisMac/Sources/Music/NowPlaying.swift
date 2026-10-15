import Foundation

/// What Apple Music or Spotify is playing, from the notification each posts on
/// every change (`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`).
/// Position is anchored: the last known position and when it was known, run
/// forward while playing. After coucou's MusicController (github.com/Louis-CFM/coucou, MIT).
struct NowPlaying: Equatable {
    enum Player: String { case music, spotify
        var app: String { self == .music ? "Music" : "Spotify" }
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    }

    let player: Player
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    var isPlaying: Bool
    var artworkURL: URL?
    private var anchorPosition: Double
    private var anchorTime: Date

    init?(player: Player, info: [String: Any], at now: Date) {
        let state = info["Player State"] as? String ?? ""
        guard state == "Playing" || state == "Paused", let title = info["Name"] as? String else { return nil }
        self.player = player
        self.title = title
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        id = (info["Persistent ID"] as? String) ?? (info["Track ID"] as? String) ?? "\(title)|\(artist)"
        let ms = (info["Total Time"] as? NSNumber) ?? (info["Duration"] as? NSNumber)
        duration = (ms?.doubleValue ?? 0) / 1000
        isPlaying = state == "Playing"
        anchorPosition = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        anchorTime = now
    }

    mutating func anchor(position: Double, at now: Date) {
        anchorPosition = position
        anchorTime = now
    }

    func position(at now: Date) -> Double {
        let p = anchorPosition + (isPlaying ? now.timeIntervalSince(anchorTime) : 0)
        return duration > 0 ? min(max(0, p), duration) : max(0, p)
    }

    func progress(at now: Date) -> Double { duration > 0 ? position(at: now) / duration : 0 }

    /// Apple's right-hand time: what's left, with a minus ("-1:29"). Rounded
    /// up, so elapsed + remaining always add up to the track's length.
    func remainingLabel(at now: Date) -> String { Self.remaining(duration, position(at: now)) }

    static func remaining(_ duration: Double, _ position: Double) -> String {
        duration > 0 ? "-" + clock((duration - position).rounded(.up)) : ""
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// The AppleScript each control sends to the player that's playing.
enum MusicScript {
    enum Command: Equatable {
        case playPause, next, previous, seek(Double), volume(Int), shuffle(Bool), repeating(Bool), position, artwork
    }

    static func command(_ c: Command, player: NowPlaying.Player) -> String {
        let tell = "tell application \"\(player.app)\" to "
        switch c {
        case .playPause: return tell + "playpause"
        case .next: return tell + "next track"
        case .previous: return tell + "previous track"
        case .seek(let s): return tell + "set player position to \(Self.number(max(0, s)))"
        case .volume(let v): return tell + "set sound volume to \(min(100, max(0, v)))"
        case .shuffle(let on):
            return tell + (player == .music ? "set shuffle enabled to \(on)" : "set shuffling to \(on)")
        case .repeating(let on):
            return tell + (player == .music ? "set song repeat to \(on ? "all" : "off")" : "set repeating to \(on)")
        case .position: return tell + "player position"
        case .artwork:
            return player == .spotify ? tell + "artwork url of current track" : ""
        }
    }

    private static func number(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
    }
}
