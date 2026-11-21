import Foundation
import Observation

/// Runs one load at a time. A plain call that lands while a load runs just waits for it
/// (polls and taps don't stack up); a `fresh` call (after Save, a pair, pull-to-refresh)
/// waits and then loads again, so it never settles for data fetched before its change.
@MainActor
final class GameLoadGate {
    private var inFlight: Task<Void, Never>?

    func run(fresh: Bool, _ load: @escaping @MainActor () async -> Void) async {
        if let current = inFlight {
            await current.value
            if !fresh { return }
            if let newer = inFlight, newer != current {
                await newer.value          // a load that started after ours already
                return
            }
        }
        let task = Task { @MainActor in await load() }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }
}

extension Notification.Name {
    /// Pull-to-refresh on the Game Streaming page: the setup section reloads too.
    static let gameStreamingRefresh = Notification.Name("gameStreaming.refresh")
}

/// The Game Streaming card and page share this: the latest `/status`, the streams
/// this phone has launched (kept on the device), the picked game, and the actions.
/// One per app.
@MainActor
@Observable
final class GameStreamingStore {
    static let shared = GameStreamingStore()

    private(set) var status: GameStreamingStatus?
    private(set) var recents: [GameRecent] = []
    private(set) var loading = false
    private(set) var error: String?
    /// The game the page's picker chose; the target buttons stream this.
    var chosenGame: String = ""

    @ObservationIgnored private let client: GameStreamingAPI
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let gate = GameLoadGate()
    /// How long one status load may take before it gives up (the server answers in ≤10 s).
    @ObservationIgnored var loadTimeout: Double = 15
    private static let recentsKey = "gameStreaming.recents.v1"
    private static let maxRecents = 8

    init(client: GameStreamingAPI = GameStreamingClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recentsKey),
           let list = try? JSONDecoder().decode([GameRecent].self, from: data) {
            recents = list
        }
    }

    /// The most recent stream this phone launched.
    var lastRecent: GameRecent? { recents.first }

    /// Load `/status`. Calls that land while one is running share it instead of stacking
    /// up (the page polls every 5 s); `fresh` (after a change) always gets a new load.
    /// `loading` is cleared on every path and a load is capped at `loadTimeout`.
    func refresh(fresh: Bool = false) async {
        await gate.run(fresh: fresh) { [weak self] in await self?.load() }
    }

    /// Refresh now, then every `interval` seconds for as long as the calling task lives
    /// (the page's `.task`, so it stops when the page goes away).
    func keepFresh(every interval: Double = 5) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let client = self.client
        do {
            let s = try await GameStreamingTimeout.run(seconds: loadTimeout) { try await client.status() }
            status = s
            if chosenGame.isEmpty || !s.apps.contains(where: { $0.name == chosenGame }) {
                chosenGame = defaultGame(s)
            }
            error = nil
        } catch is CancellationError {
            // navigated away mid-request: keep what we had
        } catch {
            self.error = Self.message(error)
        }
    }

    private func defaultGame(_ s: GameStreamingStatus) -> String {
        if let last = recents.first, s.apps.contains(where: { $0.name == last.game }) { return last.game }
        return s.apps.first?.name ?? ""
    }

    @discardableResult
    func start(target: String, game: String) async -> GameActionResult {
        do {
            let outcome = try await client.start(target: target, game: game)
            record(game: game, target: target)
            await refresh(fresh: true)
            switch outcome {
            case .pending: return .ok("Pending — it'll connect when the PC is up")
            case .started(let note): return .ok(note)
            }
        } catch {
            return .failed(Self.message(error))
        }
    }

    @discardableResult
    func stop() async -> GameActionResult {
        do {
            try await client.stop(target: nil)
            await refresh(fresh: true)
            return .ok(nil)
        } catch {
            return .failed(Self.message(error))
        }
    }

    /// The devices waiting to pair (the pair sheet polls this), capped like a refresh.
    func pairings() async -> GamePairingsReply {
        let client = self.client
        do {
            return try await GameStreamingTimeout.run(seconds: loadTimeout) { try await client.pairings() }
        } catch {
            return GamePairingsReply(reachable: false, detail: Self.message(error))
        }
    }

    func pair(device: String, pin: String, pairingID: String? = nil) async -> GamePairOutcome {
        do {
            let outcome = try await client.pair(device: device, pin: pin, pairingID: pairingID)
            if case .paired = outcome { await refresh(fresh: true) }
            return outcome
        } catch {
            return .failed(Self.message(error))
        }
    }

    @discardableResult
    func unpair(_ paired: GamePaired) async -> GameActionResult {
        do {
            try await client.unpair(device: paired.uuid.isEmpty ? paired.name : paired.uuid)
            await refresh(fresh: true)
            return .ok(nil)
        } catch {
            return .failed(Self.message(error))
        }
    }

    private func record(game: String, target: String) {
        var list = recents.filter { !($0.game == game && $0.target == target) }
        list.insert(GameRecent(game: game, target: target, at: Date()), at: 0)
        recents = Array(list.prefix(Self.maxRecents))
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: Self.recentsKey)
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
