import Foundation
import Observation

/// Page state for the Tasks (cron) screen.
///
/// A 4 s poll runs *only* while something is actually running, so the RUNNING
/// badge stays live without hammering the server the rest of the time.
@Observable
@MainActor
final class CronsStore {
    private let api: CronsAPI
    private let pollInterval: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    private let loadTask = TaskHandle()
    private let pollTask = TaskHandle()

    private(set) var jobs: [CronJob] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var toast: String?

    /// Job ids whose `run()` is in flight — drives the per-card spinner before
    /// the server-side status flips to RUNNING.
    private(set) var startingRuns: Set<String> = []

    /// The union of skills across every loaded job, so editing a job keeps its
    /// own skills selectable in the chip picker.
    private(set) var knownSkills: Set<String> = []

    init(api: CronsAPI = CronsAPI(),
         pollInterval: TimeInterval = 4,
         sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.api = api
        self.pollInterval = pollInterval
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    deinit {
        loadTask.cancel()
        pollTask.cancel()
    }

    var isEmpty: Bool { hasLoaded && jobs.isEmpty }
    var isPolling: Bool { pollTask.isActive }

    /// Anything running (server-side or a run we just fired).
    var anyRunning: Bool {
        jobs.contains { $0.isRunning || startingRuns.contains($0.id) }
    }

    func isStarting(_ job: CronJob) -> Bool { startingRuns.contains(job.id) }

    /// Skills offered by the form: everything seen so far plus the job's own.
    func skillOptions(including selected: Set<String> = []) -> [String] {
        Array(knownSkills.union(selected)).sorted()
    }

    // MARK: Lifecycle

    func load() {
        isLoading = true
        errorMessage = nil
        loadTask.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        do {
            let loaded = try await api.list()
            jobs = loaded
            harvestSkills(loaded)
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
        syncPoll()
    }

    func onDisappear() { pollTask.cancel() }

    /// Await the in-flight poll tick (tests).
    func waitForPoll() async { await pollTask.wait() }

    private func harvestSkills(_ jobs: [CronJob]) {
        for job in jobs { knownSkills.formUnion(job.skills) }
    }

    private func syncPoll() {
        if anyRunning {
            guard !pollTask.isActive else { return }
            pollTask.replace(Task { [weak self] in
                // Guard inside the loop: hoisted, the strong `self` lives as
                // long as the poll and the store's `deinit` never runs.
                while !Task.isCancelled {
                    guard let self else { return }
                    try? await self.sleeper(self.pollInterval)
                    if Task.isCancelled { return }
                    await self.refresh()
                }
            })
        } else {
            pollTask.cancel()
        }
    }

    // MARK: Mutations

    /// Run a job straight from its card: spinner on, poll kicked immediately.
    func run(_ job: CronJob) async {
        startingRuns.insert(job.id)
        syncPoll()
        do {
            try await api.run(job.id)
            toast = "Run started"
        } catch {
            toast = apiErrorMessage(error)
        }
        startingRuns.remove(job.id)
        await refresh()
    }

    func pause(_ job: CronJob) async {
        await mutate("Task paused") { try await self.api.pause(job.id) }
    }

    func resume(_ job: CronJob) async {
        await mutate("Task resumed") { try await self.api.resume(job.id) }
    }

    /// Pause or resume depending on the job's current state.
    func togglePause(_ job: CronJob) async {
        if job.isPaused { await resume(job) } else { await pause(job) }
    }

    func delete(_ job: CronJob) async {
        await mutate("Task deleted") { try await self.api.delete(job.id) }
    }

    /// Create or update from the form. `existing` nil ⇒ create.
    ///
    /// Blank optionals (name/model/profile) are dropped so the server keeps its
    /// defaults rather than being handed an empty string.
    @discardableResult
    func save(prompt: String, schedule: String, name: String, deliver: String,
              skills: Set<String>, model: String, profile: String,
              toastNotifications: Bool, existing: CronJob? = nil) async -> Bool {
        var body: JSONObject = [
            "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "schedule": schedule.trimmingCharacters(in: .whitespacesAndNewlines),
            "deliver": deliver,
            "skills": Array(skills).sorted(),
            "toast_notifications": toastNotifications,
        ]
        for (key, value) in [("name", name), ("model", model), ("profile", profile)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { body[key] = trimmed }
        }
        do {
            if let existing {
                body["job_id"] = existing.id
                try await api.update(body)
            } else {
                try await api.create(body)
            }
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    private func mutate(_ okMessage: String, _ op: () async throws -> Void) async {
        do {
            try await op()
            toast = okMessage
            await refresh()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    /// A child store for one job's run history.
    func historyStore(for job: CronJob) -> CronHistoryStore {
        CronHistoryStore(api: api, jobID: job.id)
    }
}

/// Run history for one job; each run's output is fetched lazily on expand.
@Observable
@MainActor
final class CronHistoryStore {
    private let api: CronsAPI
    let jobID: String

    private(set) var runs: [CronRun] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var outputs: [String: String] = [:]
    private(set) var loadingRuns: Set<String> = []

    init(api: CronsAPI = CronsAPI(), jobID: String) {
        self.api = api
        self.jobID = jobID
    }

    func load() async {
        isLoading = true
        do {
            runs = try await api.history(jobID)
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
    }

    func output(for run: CronRun) -> String? { outputs[run.id] }
    func isLoadingOutput(_ run: CronRun) -> Bool { loadingRuns.contains(run.id) }

    /// Fetch a run's output once; already-loaded / in-flight runs are no-ops.
    func loadOutput(_ run: CronRun) async {
        guard outputs[run.id] == nil, !loadingRuns.contains(run.id) else { return }
        loadingRuns.insert(run.id)
        do {
            outputs[run.id] = try await api.runOutput(jobID, filename: run.id)
        } catch {
            outputs[run.id] = "Failed to load output: \(apiErrorMessage(error))"
        }
        loadingRuns.remove(run.id)
    }
}
