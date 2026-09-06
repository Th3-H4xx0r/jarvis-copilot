import Foundation
import Observation

/// Page state for the Kanban board: board switcher, grouped columns, the column
/// filter, every task mutation, and the live-update subscription.
///
/// Live updates come from `/api/kanban/events/stream`. If that stream errors or
/// ends we fall back to a 30 s poll, exactly as the Flutter page did — a board
/// that stops updating silently is worse than a polling one.
@Observable
@MainActor
final class KanbanStore {
    private let api: KanbanAPI
    private let pollInterval: TimeInterval
    /// Injected so tests drive the poll without wall-clock waits.
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    private let loadTask = TaskHandle()
    private let eventsTask = TaskHandle()
    private let pollTask = TaskHandle()

    /// The board being viewed; nil ⇒ whatever the server considers current.
    private(set) var boardSlug: String?
    private(set) var boards: [KanbanBoard] = []
    private(set) var currentSlug: String?
    private(set) var board: JSONObject = [:]
    private(set) var grouped: [String: [KanbanTask]] = [:]

    /// nil ⇒ "All"; otherwise a single column.
    var columnFilter: String?

    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// One-shot banner text (dispatcher result, mutation failure, …).
    var toast: String?
    /// True once the SSE stream gave up and the 30 s poll took over.
    private(set) var isPolling = false
    /// Bumped on every applied live event — lets a view animate on change.
    private(set) var liveEventCount = 0

    init(api: KanbanAPI = KanbanAPI(),
         pollInterval: TimeInterval = 30,
         sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.api = api
        self.pollInterval = pollInterval
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    deinit {
        loadTask.cancel()
        eventsTask.cancel()
        pollTask.cancel()
    }

    // MARK: Derived state

    /// Columns rendered top-to-bottom: all of them, or just the filtered one.
    var visibleColumns: [String] {
        guard let columnFilter else { return Kanban.columns }
        return Kanban.columns.filter { $0 == columnFilter }
    }

    /// Non-empty visible columns with their tasks, in board order. Empty groups
    /// are hidden (matching the Flutter list).
    var sections: [(column: String, tasks: [KanbanTask])] {
        visibleColumns.compactMap { column in
            let tasks = grouped[column] ?? []
            return tasks.isEmpty ? nil : (column, tasks)
        }
    }

    var allTasks: [KanbanTask] { Kanban.columns.flatMap { grouped[$0] ?? [] } }
    /// The filter picked a column with no tasks in it.
    var filteredToEmptyColumn: Bool { hasLoaded && sections.isEmpty && !allTasks.isEmpty }
    var isEmpty: Bool { hasLoaded && allTasks.isEmpty }

    func board(for slug: String) -> KanbanBoard? { boards.first { $0.slug == slug } }
    var activeBoard: KanbanBoard? {
        if let boardSlug { return board(for: boardSlug) }
        if let currentSlug { return board(for: currentSlug) }
        return boards.first { $0.isCurrent }
    }

    func count(in column: String) -> Int { grouped[column]?.count ?? 0 }

    // MARK: Lifecycle

    func onAppear() {
        subscribe()
        load()
    }

    func onDisappear() {
        eventsTask.cancel()
        pollTask.cancel()
        isPolling = false
    }

    func load() {
        isLoading = true
        errorMessage = nil
        loadTask.replace(Task { [weak self] in await self?.refresh() })
    }

    /// Refresh the switcher alongside the board itself. The switcher is
    /// best-effort — the board load below is what matters.
    func refresh() async {
        if let list = try? await api.boards() {
            boards = list
            currentSlug = list.first(where: \.isCurrent)?.slug
        }
        do {
            let payload = try await api.board(slug: boardSlug)
            board = payload
            grouped = Kanban.groupTasksByColumn(Kanban.flattenTasks(payload), Kanban.columns)
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    // MARK: Live updates

    private func subscribe() {
        // The stream is opened through a captured copy of the (value-type) API
        // so `self` can be re-checked INSIDE the loop: a `guard let self`
        // hoisted above it pins the store for the whole life of the stream and
        // `deinit` never runs.
        let api = self.api
        eventsTask.replace(Task { [weak self] in
            do {
                for try await _ in api.events() {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    self.liveEventCount += 1
                    await self.refresh()
                }
                // Stream ended cleanly — the server closed it; keep the board
                // fresh with a poll instead of going stale.
                if !Task.isCancelled { self?.startPolling() }
            } catch {
                if !Task.isCancelled { self?.startPolling() }
            }
        })
    }

    private func startPolling() {
        guard !pollTask.isActive else { return }
        isPolling = true
        pollTask.replace(Task { [weak self] in
            // Re-resolved every tick: hoisting the guard above the loop would
            // keep the store alive for as long as the poll runs.
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.sleeper(self.pollInterval)
                if Task.isCancelled { return }
                await self.refresh()
            }
        })
    }

    /// Await the in-flight event/poll work (tests).
    func waitForLiveUpdates() async {
        await eventsTask.wait()
        await pollTask.wait()
    }

    // MARK: Board mutations

    func switchBoard(_ slug: String) async {
        do {
            _ = try await api.switchBoard(slug)
            boardSlug = nil     // the current pointer now points at `slug`
            await refresh()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    @discardableResult
    func createBoard(title: String, description: String) async -> Bool {
        do {
            _ = try await api.createBoard(title: title, description: description)
            boardSlug = nil
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    @discardableResult
    func renameBoard(_ slug: String, name: String, description: String?) async -> Bool {
        var body: JSONObject = ["name": name]
        if let description { body["description"] = description }
        do {
            _ = try await api.renameBoard(slug, body: body)
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    @discardableResult
    func archiveBoard(_ slug: String) async -> Bool {
        do {
            _ = try await api.archiveBoard(slug)
            if boardSlug == slug { boardSlug = nil }
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    // MARK: Task mutations

    @discardableResult
    func createTask(title: String, body: String, column: String,
                    assignee: String, priority: Int) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast = "Title is required"
            return false
        }
        var payload: JSONObject = [
            "title": trimmed,
            "body": body.trimmingCharacters(in: .whitespacesAndNewlines),
            "status": column,
            "priority": priority,
        ]
        let who = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        if !who.isEmpty { payload["assignee"] = who }
        do {
            _ = try await api.createTask(payload, board: boardSlug)
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    @discardableResult
    func editTask(_ id: String, title: String, body: String,
                  assignee: String, priority: Int) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast = "Title is required"
            return false
        }
        do {
            _ = try await api.patchTask(id, [
                "title": trimmed,
                "body": body.trimmingCharacters(in: .whitespacesAndNewlines),
                "assignee": assignee.trimmingCharacters(in: .whitespacesAndNewlines),
                "priority": priority,
            ], board: boardSlug)
            await refresh()
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    /// Move a task between columns. `running` is not a valid manual target.
    func move(_ id: String, to column: String) async {
        do {
            _ = try await api.patchTask(id, ["status": column], board: boardSlug)
            await refresh()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    func block(_ id: String, reason: String) async {
        do {
            _ = try await api.block(id, reason: reason, board: boardSlug)
            await refresh()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    func unblock(_ id: String) async {
        do {
            _ = try await api.unblock(id, board: boardSlug)
            await refresh()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    func comment(_ id: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await api.comment(id, text: trimmed, board: boardSlug)
            await refresh()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    /// "Delete" archives, which is what the bridge supports.
    func deleteTask(_ id: String) async {
        do {
            _ = try await api.deleteTask(id, board: boardSlug)
            await refresh()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    // MARK: Dispatcher

    /// Claim ready+assigned tasks and spawn workers.
    func runDispatcher(dryRun: Bool = false, max: Int = 8) async {
        do {
            let result = try await api.dispatch(slug: boardSlug, dryRun: dryRun, max: max)
            toast = Kanban.dispatchMessage(result)
            await refresh()
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    /// Per-task run. The dispatcher only claims ready+ASSIGNED tasks, so guide
    /// the user to assign first rather than firing a no-op.
    func run(_ task: KanbanTask) async {
        guard !task.assignee.isEmpty else {
            toast = "Assign a profile to this task first (Edit → Assignee), then Run."
            return
        }
        await runDispatcher()
    }

    /// A child store for one task's detail sheet.
    func detailStore(for task: KanbanTask) -> KanbanTaskDetailStore {
        KanbanTaskDetailStore(api: api, task: task, board: boardSlug, sleeper: sleeper)
    }
}

/// Detail-sheet state: full detail, worker log, comment composer, run/stop.
///
/// Polls every 2.5 s while the task is running OR the log is open so the
/// Run↔Stop control and the streaming log stay live without leaving the sheet.
@Observable
@MainActor
final class KanbanTaskDetailStore {
    private let api: KanbanAPI
    private let board: String?
    private let pollInterval: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let pollTask = TaskHandle()

    /// The board task, used until the first detail fetch lands.
    private let seed: KanbanTask

    private(set) var detail = KanbanTaskDetail()
    private(set) var isLoadingDetail = true
    private(set) var log: String?
    private(set) var isLoadingLog = false
    private(set) var logError: String?
    private(set) var isBusy = false
    private(set) var isPostingComment = false
    var toast: String?

    init(api: KanbanAPI = KanbanAPI(), task: KanbanTask, board: String?,
         pollInterval: TimeInterval = 2.5,
         sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.api = api
        self.seed = task
        self.board = board
        self.pollInterval = pollInterval
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    deinit { pollTask.cancel() }

    /// The freshest task map — the polled detail's task, else the board task.
    var task: KanbanTask { detail.task ?? seed }
    var isRunning: Bool { task.isRunning }
    var comments: [KanbanComment] { detail.comments }
    var links: JSONObject { detail.links }

    func onAppear() {
        Task { [weak self] in await self?.loadDetail() }
    }

    func onDisappear() { pollTask.cancel() }

    func loadDetail(silent: Bool = false) async {
        if !silent { isLoadingDetail = true }
        // Best-effort: fall back to whatever the board task already carried.
        if let fresh = try? await api.taskDetail(seed.id, board: board) {
            detail = fresh
        }
        if !silent { isLoadingDetail = false }
        // Auto-open the log while running so it streams without a tap.
        if isRunning && log == nil && !isLoadingLog {
            await loadLog(silent: true)
        }
        syncPoll()
    }

    func loadLog(silent: Bool = false) async {
        if !silent { isLoadingLog = true }
        do {
            log = try await api.taskLog(seed.id, board: board)
            logError = nil
        } catch {
            logError = apiErrorMessage(error)
        }
        if !silent { isLoadingLog = false }
        syncPoll()
    }

    func run(_ dispatch: @escaping () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        await dispatch()
        isBusy = false
        // The dispatcher claims within a couple of seconds — poll to pick up the
        // running state and start streaming the log.
        await loadDetail(silent: true)
    }

    /// Stop = move out of `running`; the bridge nulls the claim and reclaims.
    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        do {
            _ = try await api.patchTask(seed.id, ["status": "todo"], board: board)
            toast = "Task stopped (moved to Todo)"
        } catch {
            toast = apiErrorMessage(error)
        }
        isBusy = false
        await loadDetail(silent: true)
    }

    @discardableResult
    func postComment(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPostingComment else { return false }
        isPostingComment = true
        defer { isPostingComment = false }
        do {
            _ = try await api.comment(seed.id, text: trimmed, board: board)
            await loadDetail(silent: true)
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    private func syncPoll() {
        let shouldPoll = isRunning || log != nil
        if shouldPoll {
            guard !pollTask.isActive else { return }
            pollTask.replace(Task { [weak self] in
                // Guard inside the loop: hoisted, it would pin the detail store
                // for as long as the sheet's poll runs (i.e. forever).
                while !Task.isCancelled {
                    guard let self else { return }
                    try? await self.sleeper(self.pollInterval)
                    if Task.isCancelled { return }
                    await self.loadDetail(silent: true)
                    if self.log != nil || self.isRunning { await self.loadLog(silent: true) }
                }
            })
        } else {
            pollTask.cancel()
        }
    }
}
