import AppKit
import Observation

/// Listens to Apple Music and Spotify on this Mac, keeps `now` current and
/// sends the controls. Only reads what the players announce; the controls run
/// AppleScript on a click (macOS asks once per player).
@MainActor
@Observable
final class MusicController {
    static let shared = MusicController()

    private(set) var now: NowPlaying?
    private(set) var shuffle = false
    private(set) var repeating = false
    var volume: Double = 60 {
        didSet { if Int(volume) != Int(oldValue) { _ = now.map { run(.volume(Int(volume)), $0.player) } } }
    }
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        let dnc = DistributedNotificationCenter.default()
        for (name, player) in [("com.apple.Music.playerInfo", NowPlaying.Player.music),
                               ("com.spotify.client.PlaybackStateChanged", .spotify)] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let info = (note.userInfo as? [String: Any]) ?? [:]
                MainActor.assumeIsolated { self?.take(player, info) }
            }
        }
    }

    private func take(_ player: NowPlaying.Player, _ info: [String: Any]) {
        guard var next = NowPlaying(player: player, info: info, at: Date()) else {
            if now?.player == player { now = nil }
            return
        }
        if player == .music {
            // Music's notification carries no position: ask once.
            if let pos = run(.position, player).flatMap(Double.init) { next.anchor(position: pos, at: Date()) }
        }
        if player == .spotify, next.id != now?.id || now?.artworkURL == nil {
            next.artworkURL = run(.artwork, player).flatMap(URL.init(string:))
        } else if player == .spotify {
            next.artworkURL = now?.artworkURL
        }
        // A paused player never replaces one that's playing.
        if let current = now, current.player != player, current.isPlaying, !next.isPlaying { return }
        now = next
    }

    func send(_ c: MusicScript.Command) {
        guard let player = now?.player else { return }
        _ = run(c, player)
        if case .seek(let s) = c { now?.anchor(position: s, at: Date()) }
        if c == .playPause { now?.isPlaying.toggle() }
        if case .shuffle(let on) = c { shuffle = on }
        if case .repeating(let on) = c { repeating = on }
    }

    @discardableResult
    private func run(_ c: MusicScript.Command, _ player: NowPlaying.Player) -> String? {
        let src = MusicScript.command(c, player: player)
        guard !src.isEmpty,
              !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty else { return nil }
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil ? out?.stringValue : nil
    }
}
