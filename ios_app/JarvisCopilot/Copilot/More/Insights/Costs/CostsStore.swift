import Foundation
import Observation

/// Page state for Insights → Costs.
///
/// One overview fetch drives the whole tab; the stacked chart's grouping is
/// computed once per load (not per render). Mutations (keys, prices, budget)
/// throw the server's message to the sheet that made them and reload the
/// overview on success, so every number on the page moves together.
@Observable
@MainActor
final class CostsStore {
    private let api: CostsAPI
    private let task = TaskHandle()

    private(set) var overview = CostsOverview()
    /// The stacked-chart grouping for `overview`, rebuilt on every load.
    private(set) var stack = CostsStack()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// A pull-to-refresh is running the collector.
    private(set) var isSyncing = false

    /// The window, shared with the Usage tab's period selector.
    private(set) var days = 30

    init(api: CostsAPI = CostsAPI()) { self.api = api }

    deinit { task.cancel() }

    var hasContent: Bool { !overview.isEmpty }
    var isEmpty: Bool { hasLoaded && overview.isEmpty }

    /// Change the window. Reloads only once the tab has been opened, so a
    /// period change on the Usage tab doesn't fetch costs nobody looked at.
    func setDays(_ value: Int) {
        guard value != days else { return }
        days = value
        if hasLoaded || isLoading { load() }
    }

    func load() {
        isLoading = true
        errorMessage = nil
        task.replace(Task { [weak self] in await self?.reload() })
    }

    /// Fetch the overview for the current window.
    func reload() async {
        let window = days
        do {
            let loaded = try await api.overview(days: window)
            guard window == days else { return }   // superseded by a period change
            apply(loaded)
            errorMessage = nil
        } catch {
            if wasCancelled(error) { return }
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    /// Pull-to-refresh: run the collector (every service), then reload. A
    /// failed sync still reloads — what's stored is still worth showing.
    func refresh() async {
        isSyncing = true
        defer { isSyncing = false }
        var syncError: String?
        do {
            try await api.refresh()
        } catch {
            if !wasCancelled(error) { syncError = apiErrorMessage(error) }
        }
        await reload()
        if let syncError, errorMessage == nil { errorMessage = "Couldn't sync: \(syncError)" }
    }

    /// Test seam + the reload path: install an overview and its grouping.
    func apply(_ loaded: CostsOverview) {
        overview = loaded
        var names: [String: String] = [:]
        for s in loaded.services + loaded.available { names[s.id] = s.name }
        stack = CostsUI.stack(daily: loaded.daily, names: names)
    }

    // MARK: Derived

    var delta: Double? {
        CostsUI.deltaPercent(current: overview.totals.period, previous: overview.totals.previousPeriod)
    }

    var budgetState: CostsBudgetState? {
        CostsUI.budgetState(totals: overview.totals, budget: overview.budget)
    }

    /// Palette slot for a service row's dot and sparkline.
    func slot(for serviceID: String) -> Int? { stack.slot(for: serviceID) }

    // MARK: Mutations (each reloads on success)

    func detail(_ id: String) async throws -> CostServiceDetail {
        try await api.service(id, days: days)
    }

    /// The reply's detail is for the window the request named (`days` then).
    func connect(_ id: String, fields: [String: String]) async throws -> CostConnectReply {
        let reply = try await api.connect(id, fields: fields, days: days)
        await reload()
        return reply
    }

    func disconnect(_ id: String) async throws {
        try await api.disconnect(id)
        await reload()
    }

    func setPlan(_ id: String, amount: Double?, interval: String, plan: String?) async throws {
        try await api.setSubscription(id, amount: amount, interval: interval, plan: plan)
        await reload()
    }

    func addSubscription(name: String, amount: Double, interval: String) async throws {
        _ = try await api.addSubscription(name: name, amount: amount, interval: interval)
        await reload()
    }

    func setBudget(_ monthly: Double?) async throws {
        try await api.setBudget(monthly)
        await reload()
    }

    func syncService(_ id: String) async throws {
        try await api.refresh(id)
        await reload()
    }
}

/// State for one service's sheet: its detail, and whichever action is running.
@Observable
@MainActor
final class CostServiceModel {
    let serviceID: String
    private let store: CostsStore

    private(set) var detail: CostServiceDetail?
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// The action in flight ("connect", "plan", "clear", "disconnect", "sync").
    private(set) var busy: String?
    /// The last action started, so its outcome shows under the right form.
    private(set) var lastAction: String?
    /// The last action's outcome, shown under the form that ran it.
    private(set) var actionError: String?
    private(set) var actionNote: String?

    init(serviceID: String, store: CostsStore) {
        self.serviceID = serviceID
        self.store = store
    }

    /// The card to show: the fresh detail's, else the overview's.
    var service: CostService? { detail?.service ?? store.overview.service(serviceID) }

    var period: [String] {
        guard let detail else { return [] }
        return CostsUI.detailPeriod(detail, overview: store.overview)
    }

    var days: [CostDetailDay] {
        guard let detail else { return [] }
        return CostsUI.detailDays(detail, period: period)
    }

    /// The chart's bars: daily, or weekly past `CostsUI.weeklyAfterDays`.
    var bars: [CostDetailBar] { CostsUI.detailBars(days) }

    var slot: Int? { store.slot(for: serviceID) }

    func load() async {
        isLoading = detail == nil
        do {
            detail = try await store.detail(serviceID)
            loadError = nil
        } catch {
            if !wasCancelled(error) { loadError = apiErrorMessage(error) }
        }
        isLoading = false
    }

    /// Run one action, reporting its error; reload the detail when it worked
    /// (unless `reloadsDetail` is false: the action brought its own, or there's
    /// nothing left to show). The action returns its outcome line (`failed`
    /// shows it as an error). Returns whether the request itself succeeded.
    @discardableResult
    func run(_ name: String, reloadsDetail: Bool = true,
             _ action: () async throws -> (message: String?, failed: Bool)) async -> Bool {
        busy = name
        lastAction = name
        actionError = nil
        actionNote = nil
        defer { busy = nil }
        do {
            let outcome = try await action()
            if outcome.failed { actionError = outcome.message } else { actionNote = outcome.message }
            if reloadsDetail { await load() }
            return true
        } catch {
            if !wasCancelled(error) { actionError = apiErrorMessage(error) }
            return false
        }
    }

    func connect(_ fields: [String: String]) async -> Bool {
        await run("connect", reloadsDetail: false) {
            let reply = try await store.connect(serviceID, fields: fields)
            // The connect reply carries the detail; fetch only if it didn't, or
            // the period changed while the sync ran.
            if let fresh = reply.detail, fresh.days == store.days {
                detail = fresh
                loadError = nil
            } else {
                await load()
            }
            return (reply.result.message, reply.result.failed)
        }
    }

    func savePlan(amount: Double, interval: String, plan: String?) async -> Bool {
        await run("plan") {
            try await store.setPlan(serviceID, amount: amount, interval: interval, plan: plan)
            return ("Price saved", false)
        }
    }

    func clearPlan() async -> Bool {
        await run("clear") {
            try await store.setPlan(serviceID, amount: nil, interval: "month", plan: nil)
            return ("Price cleared", false)
        }
    }

    /// A custom subscription IS its price: clearing it deletes the entry, so
    /// there's no detail to fetch afterwards (the sheet closes).
    func removeSubscription() async -> Bool {
        await run("clear", reloadsDetail: false) {
            try await store.setPlan(serviceID, amount: nil, interval: "month", plan: nil)
            return ("Subscription removed", false)
        }
    }

    func disconnect() async -> Bool {
        await run("disconnect") {
            try await store.disconnect(serviceID)
            return ("Billing key removed", false)
        }
    }

    func sync() async -> Bool {
        await run("sync") {
            try await store.syncService(serviceID)
            return ("Synced", false)
        }
    }
}
