import Foundation
import Observation

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

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let s = try await client.status()
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
            await refresh()
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
            await refresh()
            return .ok(nil)
        } catch {
            return .failed(Self.message(error))
        }
    }

    func pair(device: String, pin: String) async -> GamePairOutcome {
        do {
            let outcome = try await client.pair(device: device, pin: pin)
            if case .paired = outcome { await refresh() }
            return outcome
        } catch {
            return .failed(Self.message(error))
        }
    }

    @discardableResult
    func unpair(_ paired: GamePaired) async -> GameActionResult {
        do {
            try await client.unpair(device: paired.uuid.isEmpty ? paired.name : paired.uuid)
            await refresh()
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
