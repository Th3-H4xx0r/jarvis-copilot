import Foundation

/// The Toyota side of the Car page: the account, the car, and the one command running now.
@MainActor
final class ToyotaStore: ObservableObject {
    static let shared = ToyotaStore()

    struct Outcome: Equatable {
        let command: ToyotaCommand
        let text: String
        let ok: Bool
        /// No answer in time: the car may still do it — shown amber, not red.
        var pending = false
    }

    @Published private(set) var account: ToyotaAccount?
    @Published private(set) var car: ToyotaCar?
    /// Why the car couldn't be read (the page still shows the account).
    @Published private(set) var problem: String?
    @Published private(set) var busy: ToyotaCommand?
    @Published private(set) var outcome: Outcome?
    /// No sensor reports the hazards, so the page remembers turning them on — for 15 minutes.
    @Published private(set) var hazardsOnSince: Date?

    let api: ToyotaAPI
    private let now: () -> Date
    static let hazardsMemory: TimeInterval = 15 * 60

    init(api: ToyotaAPI = ToyotaAPI(), now: @escaping () -> Date = Date.init) {
        self.api = api
        self.now = now
    }

    var isSignedIn: Bool { account?.isSignedIn == true }

    var hazardsOn: Bool {
        guard let since = hazardsOnSince else { return false }
        return now().timeIntervalSince(since) < Self.hazardsMemory
    }

    func load() async {
        do {
            let state = try await api.state()
            account = state.account
            car = state.car
            problem = state.error
        } catch {
            if wasCancelled(error) { return }
            problem = apiErrorMessage(error)
        }
    }

    /// Pull to refresh: wakes the car when signed in, then reads it again.
    func refresh() async {
        var wakeProblem: String?
        if isSignedIn {
            do { try await api.refresh() } catch {
                if wasCancelled(error) { return }
                wakeProblem = ToyotaAPI.isPending(error)
                    ? "The car hasn't answered yet; showing its last report." : apiErrorMessage(error)
            }
        }
        await load()
        // load() replaces `problem`; a failed wake must still show.
        if let wakeProblem, problem == nil { problem = wakeProblem }
    }

    /// The button a command lives on is busy (Start while Stop shows, say).
    func isBusy(_ command: ToyotaCommand) -> Bool { busy?.slot == command.slot }
    func outcome(for command: ToyotaCommand) -> Outcome? { outcome?.command.slot == command.slot ? outcome : nil }

    /// One command at a time: a second hold while one runs is ignored, so a slow car never
    /// gets the same command twice.
    func run(_ command: ToyotaCommand) async {
        guard busy == nil, isSignedIn else { return }
        busy = command
        outcome = nil
        do {
            let text = try await api.run(command)
            if command == .hazardsOn { rememberHazards() }
            if command == .hazardsOff { hazardsOnSince = nil }
            finish(Outcome(command: command, text: text, ok: true))
            await load()
        } catch {
            if ToyotaAPI.isPending(error) {
                finish(Outcome(command: command, text: ToyotaAPI.Pending().errorDescription ?? "", ok: false, pending: true))
                await load()
                return
            }
            finish(Outcome(command: command, text: apiErrorMessage(error), ok: false))
            // 409: Toyota signed Jarvis out — show the account as it is now.
            if case .http(409, _) = error as? APIError { await load() }
        }
    }

    func saveClimate(_ draft: ToyotaCar.Climate) async throws {
        let saved = try await api.saveClimate(draft)
        car?.climate = saved ?? draft
    }

    func signIn(email: String, password: String) async throws -> ToyotaAPI.SignInStep {
        let step = try await api.signIn(email: email, password: password)
        if step == .done { await load() }
        return step
    }

    func submitCode(flowID: String, code: String) async throws -> ToyotaAPI.SignInStep {
        let step = try await api.submitCode(flowID: flowID, code: code)
        if step == .done { await load() }
        return step
    }

    func signOut() async throws {
        try await api.signOut()
        await load()
    }

    /// The button flips back to "Hazards" by itself once the memory runs out.
    private func rememberHazards() {
        let since = now()
        hazardsOnSince = since
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.hazardsMemory))
            if self?.hazardsOnSince == since { self?.hazardsOnSince = nil }
        }
    }

    private func finish(_ result: Outcome) {
        busy = nil
        outcome = result
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.outcome == result { self?.outcome = nil }
        }
    }
}
