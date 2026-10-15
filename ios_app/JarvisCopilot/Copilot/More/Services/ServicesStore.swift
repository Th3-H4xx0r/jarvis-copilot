import Foundation
import Observation

/// The Services and Portfolio screens' state: the service pills, each one's
/// detail, the crypto watchlist and holdings, and the keys / settings config.
///
/// Push-driven. While a screen shows a list it wants that list's bridge topic
/// (`services` or `portfolio`); the server publishes each once per change. The
/// store fetches once when a list comes on screen and after a reconnect, and
/// never on a timer: the app is never suspended, so a timer would run all night.
@MainActor
@Observable
final class ServicesStore {
    static let shared = ServicesStore()

    enum Feed: String { case services, portfolio }

    /// A question to answer before an action runs: the action's own (asked
    /// before Face ID) or the server's (a 409 after it).
    struct PendingConfirmation: Identifiable, Equatable {
        let id = UUID()
        let serviceID: String
        let action: ServiceAction
        let question: String
        /// Face ID already passed for this tap: the resend doesn't ask again.
        let authenticated: Bool
    }

    // Services
    private(set) var services: [ServiceSnapshot] = []
    private(set) var pending: [String] = []
    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var details: [String: ServiceDetail] = [:]
    private(set) var detailErrors: [String: String] = [:]
    /// Actions in flight, by `ServiceAction.id`.
    private(set) var running: Set<String> = []
    var pendingConfirmation: PendingConfirmation?
    /// The transient banner (`moreToast`).
    var toast: String?

    // Portfolio
    private(set) var crypto: CryptoBoard?
    private(set) var portfolio: PortfolioBoard?
    private(set) var portfolioLoaded = false
    private(set) var portfolioError: String?

    // Config
    private(set) var config: ServicesConfig?
    private(set) var configError: String?
    private(set) var saving = false

    @ObservationIgnored private let api: ServicesAPI
    @ObservationIgnored private let topics: BridgeTopics
    @ObservationIgnored private let authenticate: (String) async -> Bool
    @ObservationIgnored private var watchers: [Feed: Set<String>] = [:]

    /// `authenticate` is Face ID (passcode fallback); tests pass a stand-in.
    /// `topics` nil = the app's bridge (a default argument can't read the
    /// main-actor `.shared`).
    init(api: ServicesAPI = ServicesAPI(), topics: BridgeTopics? = nil,
         authenticate: @escaping (String) async -> Bool = { await OwnerCheck.confirm(reason: $0) }) {
        let topics = topics ?? .shared
        self.api = api
        self.topics = topics
        self.authenticate = authenticate
        topics.on(Feed.services.rawValue) { [weak self] data in self?.applyServices(data) }
        topics.on(Feed.portfolio.rawValue) { [weak self] data in self?.applyPortfolio(data) }
        // The socket came back: whatever was pushed while it was down was missed.
        topics.onResync { [weak self] in
            guard let self else { return }
            if self.isWatched(.services) { Task { await self.refresh() } }
            if self.isWatched(.portfolio) { Task { await self.refreshPortfolio() } }
        }
    }

    func snapshot(_ id: String) -> ServiceSnapshot? { services.first { $0.id == id } }

    func isRunning(_ action: ServiceAction) -> Bool { running.contains(action.id) }

    /// Services with keys whose first poll hasn't come back, by display name when known.
    var pendingNames: [(id: String, name: String)] {
        pending.map { id in (id, config?.services.first { $0.id == id }?.displayName ?? id.capitalized) }
    }

    /// Services the config knows that have no key yet.
    var unconfigured: [ServiceConfigEntry] {
        (config?.services ?? []).filter { !$0.configured }
    }

    // MARK: visibility

    /// A screen showing `feed` came on screen or went away. The topic is wanted
    /// while any owner shows it, and the first owner to arrive fetches once — so
    /// pushing the detail over the list (which joins before the list lets go)
    /// doesn't refetch.
    func setVisible(_ on: Bool, feed: Feed, owner: String) {
        var owners = watchers[feed] ?? []
        let wasWatched = !owners.isEmpty
        if on {
            guard owners.insert(owner).inserted else { return }
        } else {
            guard owners.remove(owner) != nil else { return }
        }
        watchers[feed] = owners
        if on {
            topics.want(feed.rawValue, owner: owner, every: 0)
            if !wasWatched {
                Task {
                    switch feed {
                    case .services: await refresh()
                    case .portfolio: await refreshPortfolio()
                    }
                }
            }
        } else {
            topics.drop(feed.rawValue, owner: owner)
        }
    }

    private func isWatched(_ feed: Feed) -> Bool { !(watchers[feed] ?? []).isEmpty }

    // MARK: services

    func refresh() async {
        do {
            let overview = try await api.overview()
            services = overview.services
            pending = overview.pending
            loadError = nil
        } catch {
            if !wasCancelled(error) { loadError = apiErrorMessage(error) }
        }
        loaded = true
    }

    /// One `services` push: the whole list, as it stands. Pushes carry no
    /// `pending`; a service that has a snapshot now isn't pending any more.
    func applyServices(_ data: [String: Any]) {
        guard let raw = data["services"] as? [Any] else { return }
        let next = raw.compactMap { ($0 as? [String: Any]).map(ServiceSnapshot.init(json:)) }
        services = next
        let have = Set(next.map(\.id))
        pending.removeAll { have.contains($0) }
        loaded = true
        loadError = nil
    }

    func loadDetail(_ id: String) async {
        do {
            details[id] = try await api.detail(id)
            detailErrors[id] = nil
        } catch {
            if !wasCancelled(error) { detailErrors[id] = apiErrorMessage(error) }
        }
    }

    // MARK: actions

    /// The button was tapped. An action that asks first ("Cancel this
    /// deployment?") asks before Face ID; everything else goes to Face ID now.
    func tap(_ action: ServiceAction, service id: String) async {
        if let question = action.confirm {
            pendingConfirmation = PendingConfirmation(serviceID: id, action: action, question: question,
                                                      authenticated: false)
            return
        }
        await run(action, service: id, confirmed: false, authenticated: false)
    }

    /// The question was answered yes.
    func confirm(_ question: PendingConfirmation) async {
        if pendingConfirmation?.id == question.id { pendingConfirmation = nil }
        await run(question.action, service: question.serviceID, confirmed: true,
                  authenticated: question.authenticated)
    }

    func cancelPending() { pendingConfirmation = nil }

    private func run(_ action: ServiceAction, service id: String, confirmed: Bool, authenticated: Bool) async {
        // Busy from the tap on, Face ID included: a second tap can't raise a second prompt.
        guard running.insert(action.id).inserted else { return }
        defer { running.remove(action.id) }
        // When the tap happened, not when Face ID let it through: the server
        // refuses a request that's been waiting for minutes.
        let requestedAt = Date()
        if !authenticated {
            let name = snapshot(id)?.displayName ?? details[id]?.displayName ?? id
            guard await authenticate("\(action.title) on \(name)") else { return }
        }
        do {
            let reply = try await api.action(id, kind: action.kind, target: action.target,
                                             confirmed: confirmed, requestedAt: requestedAt)
            if let detail = reply.detail { details[id] = detail }
            if reply.status == 409, let question = reply.confirm, !confirmed {
                pendingConfirmation = PendingConfirmation(serviceID: id, action: action, question: question,
                                                          authenticated: true)
            } else if let result = reply.result {
                toast = result.line
            } else {
                toast = reply.error ?? "Not done."
            }
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    // MARK: portfolio

    func refreshPortfolio() async {
        do {
            let board = try await api.portfolio()
            crypto = board.crypto
            portfolio = board.portfolio
            portfolioError = nil
        } catch {
            if !wasCancelled(error) { portfolioError = apiErrorMessage(error) }
        }
        portfolioLoaded = true
    }

    /// One `portfolio` push: both boards as they stand (null = off / nothing set up).
    func applyPortfolio(_ data: [String: Any]) {
        guard data.keys.contains("crypto") || data.keys.contains("portfolio") else { return }
        crypto = CryptoBoard(json: data["crypto"])
        portfolio = PortfolioBoard(json: data["portfolio"])
        portfolioLoaded = true
        portfolioError = nil
    }

    // MARK: config

    func loadConfig() async {
        do {
            config = try await api.config()
            configError = nil
        } catch {
            if !wasCancelled(error) { configError = apiErrorMessage(error) }
        }
    }

    /// Saves what was typed for one service. Returns false (and sends nothing)
    /// when nothing changed.
    @discardableResult
    func saveService(_ entry: ServiceConfigEntry, draft: KeysDraft) async -> Bool {
        var body: [String: Any] = ["service": entry.id]
        let secrets = draft.secretsPayload(fields: entry.secrets)
        if !secrets.isEmpty { body["secrets"] = secrets }
        let settings = draft.settingsPayload(entry.settings)
        if !settings.isEmpty { body["settings"] = settings }
        guard body.count > 1 else {
            toast = "Nothing to save."
            return false
        }
        guard await save(body, done: "\(entry.displayName) saved.") else { return false }
        // The server polls it now and its first snapshot arrives as a push; until
        // then it shows as checking. Pushes don't carry the pending list, so it's
        // kept here from what the config answered.
        let configured = config?.services.first { $0.id == entry.id }?.configured ?? false
        if configured, snapshot(entry.id) == nil, !pending.contains(entry.id) {
            pending.append(entry.id)
        } else if !configured {
            pending.removeAll { $0 == entry.id }
        }
        return true
    }

    @discardableResult
    func saveExchange(_ entry: ExchangeConfigEntry, draft: KeysDraft) async -> Bool {
        let secrets = draft.secretsPayload(fields: entry.secrets)
        guard !secrets.isEmpty else {
            toast = "Nothing to save."
            return false
        }
        return await save(["exchange": entry.id, "secrets": secrets], done: "\(entry.displayName) saved.")
    }

    /// `changes`: only the watchlist settings that changed.
    @discardableResult
    func saveCrypto(_ changes: [String: Any]) async -> Bool {
        guard !changes.isEmpty else { return false }
        return await save(["crypto": changes], done: "Watchlist saved.")
    }

    private func save(_ body: [String: Any], done: String) async -> Bool {
        saving = true
        defer { saving = false }
        do {
            config = try await api.saveConfig(body)
            configError = nil
            toast = done
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    /// Adds a public wallet. Returns the server's reason when it refused (a bad
    /// address, one it couldn't read), nil when it was added.
    func addWallet(network: String, address: String, label: String) async -> String? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "Paste the wallet's address." }
        saving = true
        defer { saving = false }
        do {
            let wallets = try await api.addWallet(network: network, address: address, label: label)
            config?.wallets = wallets
            toast = "Wallet added. Its balance shows up in a moment."
            return nil
        } catch {
            return apiErrorMessage(error)
        }
    }

    @discardableResult
    func removeWallet(_ wallet: WalletEntry) async -> Bool {
        do {
            let wallets = try await api.removeWallet(network: wallet.network, address: wallet.address)
            config?.wallets = wallets
            toast = "Wallet removed."
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }
}
