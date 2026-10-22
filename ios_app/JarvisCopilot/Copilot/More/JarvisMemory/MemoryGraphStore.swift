import Foundation
import Observation

/// State behind the memory map: the graph on the canvas, its force layout, the
/// filters, and the fix tools that change the graph on the server.
///
/// The layout is `@ObservationIgnored` on purpose — it changes every frame while
/// it runs, and the canvas redraws from the TimelineView tick, not from
/// observation. `isSettled` is the one observed bit: it is what pauses the
/// TimelineView, so a resting map costs nothing.
@Observable
@MainActor
final class MemoryGraphStore {
    /// Layout steps per drawn frame: settles in ~2-3 s at 60 fps.
    static let stepsPerFrame = 2
    /// Steps run before a fresh graph is first drawn, so it opens mostly laid out
    /// and the animation (and its battery) is short.
    static let warmupSteps = 60

    private let api: JarvisMemoryAPI
    private let now: () -> Date
    /// Monotonic: a slow response for old filters must not replace a newer one.
    private var generation = 0

    private(set) var graph = MemoryGraph()
    @ObservationIgnored var layout = MemoryGraphSimulation()
    private(set) var isSettled = true
    /// Bumped whenever the layout moved while paused (a merge, a pin), so the
    /// canvas redraws once without the TimelineView running.
    private(set) var layoutVersion = 0

    private(set) var filters = MemoryGraphFilters()
    /// The recall the map is lit up for, if any.
    private(set) var recall: MemoryRecall?
    private(set) var loading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var expanding: String?
    var toast: String?
    /// Set while the node sheet is up: fix-tool errors then show in the sheet
    /// (`sheetToast`), not in the map's toast hidden under it.
    var sheetOpen = false
    var sheetToast: String?

    static let recallGoneMessage = "That recall is gone — its memories changed since. Showing the whole map."

    init(api: JarvisMemoryAPI = JarvisMemoryAPI(), now: @escaping () -> Date = Date.init) {
        self.api = api
        self.now = now
    }

    var isHighlighting: Bool { !graph.highlight.isEmpty }

    // MARK: Loading

    /// The You view under the current filters (or the recall's lit view).
    func load() async {
        if let recall { await showRecall(recall); return }
        _ = await loadYou()
    }

    /// False only when this request failed (a superseded one is not a failure).
    private func loadYou() async -> Bool {
        generation += 1
        let id = generation
        loading = true
        defer { if id == generation { loading = false } }
        do {
            let payload = try await api.graph(center: MemoryGraph.meID, filters: filters, now: now())
            guard id == generation else { return true }
            install(payload)
            hasLoaded = true
            return true
        } catch {
            guard id == generation, !wasCancelled(error) else { return true }
            fail(apiErrorMessage(error))
            hasLoaded = true
            return false
        }
    }

    /// With a graph on screen an error is a toast (the graph stays); with none,
    /// it fills the canvas with a retry.
    private func fail(_ message: String) {
        if graph.isEmpty { error = message } else { toast = message }
    }

    /// Fix-tool errors: in the sheet while it is up.
    private func report(_ message: String) {
        if sheetOpen { sheetToast = message } else { toast = message }
    }

    func loadIfNeeded() async {
        if !hasLoaded && !loading { await load() }
    }

    /// A failed reload puts the chips back to what the map still shows.
    func setFilters(_ new: MemoryGraphFilters) async {
        guard new != filters else { return }
        let (oldFilters, oldRecall) = (filters, recall)
        filters = new
        recall = nil
        if !(await loadYou()) {
            filters = oldFilters
            recall = oldRecall
        }
    }

    /// Open the map lit up on what one recall used. A recall the server no
    /// longer has says so and leaves the plain You view up.
    func showRecall(_ recall: MemoryRecall) async {
        let previous = self.recall
        self.recall = recall
        generation += 1
        let id = generation
        loading = true
        defer { if id == generation { loading = false } }
        do {
            let payload = try await api.highlight(recallID: recall.id)
            guard id == generation else { return }
            install(payload)
            hasLoaded = true
        } catch {
            guard id == generation, !wasCancelled(error) else { return }
            if case APIError.http(status: 404, message: _) = error {
                self.recall = nil
                toast = Self.recallGoneMessage
                // Whatever was lit belonged to another recall; show the plain view.
                if graph.isEmpty || isHighlighting || previous != nil { _ = await loadYou() }
                hasLoaded = true
                return
            }
            self.recall = previous
            fail(apiErrorMessage(error))
            hasLoaded = true
        }
    }

    /// Back to the plain You view.
    func clearRecall() async {
        let previous = recall
        recall = nil
        if !(await loadYou()) { recall = previous }
    }

    private func install(_ payload: MemoryGraphPayload) {
        error = nil
        graph.replace(with: payload)
        layout = MemoryGraphSimulation()
        layout.sync(with: graph)
        layout.run(steps: Self.warmupSteps)
        isSettled = layout.isSettled
        layoutVersion += 1
    }

    // MARK: Expand

    /// Merge the node's neighbours into the canvas; existing nodes stay put.
    /// A reload while it is on the wire wins: the late answer is dropped.
    func expand(_ id: String) async {
        guard id != MemoryGraph.meID, expanding == nil else { return }
        expanding = id
        defer { expanding = nil }
        let started = generation
        do {
            let payload = try await api.graph(center: id, filters: filters, now: now())
            guard generation == started else { return }
            let added = graph.merge(payload)
            relayout()
            if added.isEmpty { toast = "Nothing more linked to it" }
        } catch {
            guard generation == started, !wasCancelled(error) else { return }
            toast = apiErrorMessage(error)
        }
    }

    /// A memory's link to `id` was removed: one memory lighter, on the node and
    /// its edge to You (the edge weight is its memory count).
    func memoryUnlinked(from id: String) {
        graph.memoryUnlinked(from: id)
        layout.sync(with: graph)   // new radius; nothing added, so it stays at rest
        layoutVersion += 1
    }

    // MARK: Layout ticks

    /// One drawn frame. Only the map's TimelineView calls this, and only while it
    /// runs (visible, app in front, not settled).
    func tick() {
        guard !isSettled else { return }
        for _ in 0..<Self.stepsPerFrame { layout.step() }
        if layout.isSettled { isSettled = true }
    }

    private func relayout() {
        layout.sync(with: graph)
        isSettled = layout.isSettled
        layoutVersion += 1
    }

    // MARK: Fix tools

    /// Merge `from` into `into` on the server, then on the canvas.
    @discardableResult
    func merge(_ from: String, into: String) async -> Bool {
        do {
            let survivor = try await api.mergeEntity(from: from, into: into)
            graph.mergeNode(from, into: survivor.id.isEmpty ? into : survivor.id,
                            survivor: survivor.id.isEmpty ? nil : survivor)
            relayout()
            return true
        } catch {
            report(apiErrorMessage(error))
            return false
        }
    }

    /// Answers the surviving entity: a different id when the new name belonged to
    /// another entity of the same type, which the server merges into.
    @discardableResult
    func rename(_ id: String, to label: String) async -> MemoryEntity? {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return await save(id) { try await self.api.updateEntity(id, label: name) }
    }

    @discardableResult
    func setAliases(_ id: String, _ aliases: [String]) async -> MemoryEntity? {
        let clean = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return await save(id) { try await self.api.updateEntity(id, aliases: clean) }
    }

    @discardableResult
    func setPinned(_ id: String, _ pinned: Bool) async -> MemoryEntity? {
        await save(id) { try await self.api.updateEntity(id, pinned: pinned) }
    }

    private func save(_ id: String, _ call: () async throws -> MemoryEntity) async -> MemoryEntity? {
        do {
            let entity = try await call()
            if !entity.id.isEmpty, entity.id != id {
                graph.mergeNode(id, into: entity.id, survivor: entity)
                relayout()
            } else {
                var saved = entity
                if saved.id.isEmpty { saved.id = id }
                graph.update(saved)
                layoutVersion += 1
            }
            return entity
        } catch {
            report(apiErrorMessage(error))
            return nil
        }
    }
}

/// The node sheet's own data: the entity, its memories and neighbours.
@Observable
@MainActor
final class MemoryEntitySheetModel {
    let id: String
    private let api: JarvisMemoryAPI

    private(set) var detail: MemoryEntityDetail?
    private(set) var loading = false
    private(set) var error: String?
    var toast: String?

    init(id: String, api: JarvisMemoryAPI = JarvisMemoryAPI()) {
        self.id = id
        self.api = api
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            detail = try await api.entity(id)
            error = nil
        } catch {
            if !wasCancelled(error) { self.error = apiErrorMessage(error) }
        }
    }

    /// A wrong link: the memory stays, it just stops pointing at this entity.
    @discardableResult
    func unlink(_ memoryID: String) async -> Bool {
        do {
            try await api.unlink(memoryID: memoryID, entityID: id)
            detail?.memories.removeAll { $0.id == memoryID }
            return true
        } catch {
            toast = apiErrorMessage(error)
            return false
        }
    }

    /// A fix saved through the graph store; keep the header in step.
    func apply(_ entity: MemoryEntity) {
        guard entity.id == id, detail != nil else { return }
        detail?.entity = entity
    }
}

/// The chat's "memories used" chips: one recalls request when a chat opens,
/// and one more after each finished turn whose reply has no chip yet (a new
/// chat makes its session right before sending, so the open-time fetch is
/// empty). Never a request per message, never a poll.
@Observable
@MainActor
final class ChatRecallStore {
    private let api: JarvisMemoryAPI
    private(set) var recalls: [MemoryRecall] = []
    @ObservationIgnored private var loadedSession: String?
    /// The last reply a finished-turn fetch was made for.
    @ObservationIgnored private var fetchedForReply: UUID?
    @ObservationIgnored private var cache: (ids: [UUID], session: String?, recalls: [String],
                                            chips: [UUID: MemoryRecall])?

    init(api: JarvisMemoryAPI = JarvisMemoryAPI()) { self.api = api }

    /// Called when a chat opens. The same chat again is a no-op; a new (unsaved)
    /// chat has nothing to ask about.
    func load(sessionID: String?) async {
        guard sessionID != loadedSession || (sessionID == nil && !recalls.isEmpty) else { return }
        loadedSession = sessionID
        fetchedForReply = nil
        recalls = []
        guard let sessionID, !sessionID.isEmpty else { return }
        await fetch(sessionID)
    }

    /// A turn finished streaming. Fetch once if its reply has no chip yet.
    func turnFinished(rows: [ChatRow], sessionID: String?) async {
        guard let sessionID, !sessionID.isEmpty,
              let last = rows.last, !last.message.isUser,
              rows.contains(where: \.message.isUser),
              fetchedForReply != last.id,
              chips(for: rows, sessionID: sessionID)[last.id] == nil else { return }
        fetchedForReply = last.id
        if loadedSession != sessionID {
            loadedSession = sessionID
            recalls = []
        }
        await fetch(sessionID)
    }

    private func fetch(_ sessionID: String) async {
        do {
            let found = try await api.recalls(limit: 100, sessionID: sessionID)
            guard loadedSession == sessionID else { return }
            recalls = found
        } catch {
            JcLog.dropped(JcLog.more, "chat recalls", error)
        }
    }

    /// Message id → recall, for the rows on screen. Recomputed only when the
    /// rows themselves or the recalls change: a streamed token changes neither,
    /// so a reply streaming in doesn't re-read the thread per token. Only user
    /// messages' text is read.
    func chips(for rows: [ChatRow], sessionID: String?) -> [UUID: MemoryRecall] {
        guard !recalls.isEmpty else { return [:] }
        let ids = rows.map(\.id)
        let recallIDs = recalls.map(\.id)
        if let cache, cache.ids == ids, cache.session == sessionID, cache.recalls == recallIDs {
            return cache.chips
        }
        let turns = rows.map { row in
            MemoryRecallTurn(isUser: row.message.isUser,
                             text: row.message.isUser ? row.message.plainText : "",
                             time: row.message.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        var out: [UUID: MemoryRecall] = [:]
        for (index, recall) in MemoryRecallMatch.chips(turns: turns, recalls: recalls) {
            out[rows[index].id] = recall
        }
        cache = (ids, sessionID, recallIDs, out)
        return out
    }
}
