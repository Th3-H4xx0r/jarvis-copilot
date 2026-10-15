import AppKit
import Observation

/// Listens to Apple Music and Spotify on this Mac and keeps `now` current from
/// what the players announce. AppleScript runs only on a button press or while
/// the Music tab is open (position, artwork), always off the main thread, so a
/// track change never triggers an Automation prompt or freezes the island.
@MainActor
@Observable
final class MusicController {
    static let shared = MusicController()

    private(set) var now: NowPlaying?
    private(set) var shuffle = false
    private(set) var repeating = false
    var volume: Double = 60 {
        didSet {
            guard Int(volume) != Int(oldValue), let player = now?.player else { return }
            volumeTask?.cancel()
            let level = Int(volume)
            volumeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))   // one script per drag pause, not per step
                guard !Task.isCancelled else { return }
                await self?.run(.volume(level), player)
            }
        }
    }
    @ObservationIgnored private var started = false
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var volumeTask: Task<Void, Never>?

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

    /// The Music tab is on screen: fill in position and artwork now.
    func setVisible(_ on: Bool) {
        visible = on
        if on { enrich() }
    }

    private func take(_ player: NowPlaying.Player, _ info: [String: Any]) {
        guard var next = NowPlaying(player: player, info: info, at: Date()) else {
            if now?.player == player { now = nil }
            return
        }
        if player == .spotify, next.id == now?.id { next.artworkURL = now?.artworkURL }
        // A paused player never replaces one that's playing.
        if let current = now, current.player != player, current.isPlaying, !next.isPlaying { return }
        now = next
        if visible { enrich() }
    }

    /// Music's notification carries no position, Spotify's no artwork: ask.
    private func enrich() {
        guard let current = now else { return }
        let id = current.id, player = current.player
        let needsArt = player == .spotify && current.artworkURL == nil
        Task { [weak self] in
            let pos = player == .music ? await self?.run(.position, player).flatMap(Double.init) : nil
            let art = needsArt ? await self?.run(.artwork, player).flatMap(URL.init(string:)) : nil
            guard let self, self.now?.id == id else { return }
            if let pos { self.now?.anchor(position: pos, at: Date()) }
            if let art { self.now?.artworkURL = art }
        }
    }

    func send(_ c: MusicScript.Command) {
        guard let player = now?.player else { return }
        Task { [weak self] in await self?.run(c, player) }
        if case .seek(let s) = c { now?.anchor(position: s, at: Date()) }
        if c == .playPause { now?.isPlaying.toggle() }
        if case .shuffle(let on) = c { shuffle = on }
        if case .repeating(let on) = c { repeating = on }
    }

    @discardableResult
    private func run(_ c: MusicScript.Command, _ player: NowPlaying.Player) async -> String? {
        let src = MusicScript.command(c, player: player)
        guard !src.isEmpty,
              !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty else { return nil }
        return await Scripts.run(src).output
    }
}
