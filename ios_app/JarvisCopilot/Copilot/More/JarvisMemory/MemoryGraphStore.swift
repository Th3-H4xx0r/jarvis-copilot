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

    init(api: JarvisMemoryAPI = JarvisMemoryAPI(), now: @escaping () -> Date = Date.init) {
        self.api = api
        self.now = now
    }

    var isHighlighting: Bool { !graph.highlight.isEmpty }

    // MARK: Loading

    /// The You view under the current filters (or the recall's lit view).
    func load() async {
        if let recall { await showRecall(recall); return }
        generation += 1
        let id = generation
        loading = true
        defer { if id == generation { loading = false } }
        do {
            let payload = try await api.graph(center: MemoryGraph.meID, filters: filters, now: now())
            guard id == generation else { return }
            install(payload)
        } catch {
            guard id == generation, !wasCancelled(error) else { return }
            self.error = apiErrorMessage(error)
        }
        hasLoaded = true
    }

    func loadIfNeeded() async {
        if !hasLoaded && !loading { await load() }
    }

    func setFilters(_ new: MemoryGraphFilters) async {
        guard new != filters else { return }
        filters = new
        recall = nil
        await load()
    }

    /// Open the map lit up on what one recall used.
    func showRecall(_ recall: MemoryRecall) async {
        self.recall = recall
        generation += 1
        let id = generation
        loading = true
        defer { if id == generation { loading = false } }
        do {
            let payload = try await api.highlight(recallID: recall.id)
            guard id == generation else { return }
            install(payload)
        } catch {
            guard id == generation, !wasCancelled(error) else { return }
            self.error = apiErrorMessage(error)
        }
        hasLoaded = true
    }

    /// Back to the plain You view.
    func clearRecall() async {
        recall = nil
        await load()
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
    func expand(_ id: String) async {
        guard id != MemoryGraph.meID, expanding == nil else { return }
        expanding = id
        defer { expanding = nil }
        do {
            let payload = try await api.graph(center: id, filters: filters, now: now())
            let added = graph.merge(payload)
            relayout()
            if added.isEmpty { toast = "Nothing more linked to it" }
        } catch {
            toast = apiErrorMessage(error)
        }
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
            toast = apiErrorMessage(error)
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
            toast = apiErrorMessage(error)
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
    func unlink(_ memoryID: String) async {
        do {
            try await api.unlink(memoryID: memoryID, entityID: id)
            detail?.memories.removeAll { $0.id == memoryID }
        } catch {
            toast = apiErrorMessage(error)
        }
    }

    /// A fix saved through the graph store; keep the header in step.
    func apply(_ entity: MemoryEntity) {
        guard entity.id == id, detail != nil else { return }
        detail?.entity = entity
    }
}

/// The chat's "memories used" chips: one recalls request per opened chat.
@Observable
@MainActor
final class ChatRecallStore {
    private let api: JarvisMemoryAPI
    private(set) var recalls: [MemoryRecall] = []
    @ObservationIgnored private var loadedSession: String?
    @ObservationIgnored private var cache: (ids: [UUID], session: String?, count: Int, chips: [UUID: MemoryRecall])?

    init(api: JarvisMemoryAPI = JarvisMemoryAPI()) { self.api = api }

    /// Called when a chat opens. The same chat again is a no-op; a new (unsaved)
    /// chat has nothing to ask about.
    func load(sessionID: String?) async {
        guard sessionID != loadedSession || (sessionID == nil && !recalls.isEmpty) else { return }
        loadedSession = sessionID
        recalls = []
        guard let sessionID, !sessionID.isEmpty else { return }
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
    /// so a reply streaming in doesn't re-read the whole thread per token.
    func chips(for rows: [ChatRow], sessionID: String?) -> [UUID: MemoryRecall] {
        guard !recalls.isEmpty else { return [:] }
        let ids = rows.map(\.id)
        if let cache, cache.ids == ids, cache.session == sessionID, cache.count == recalls.count {
            return cache.chips
        }
        let turns = rows.map { MemoryRecallTurn(isUser: $0.message.isUser, text: $0.message.plainText) }
        var out: [UUID: MemoryRecall] = [:]
        for (index, recall) in MemoryRecallMatch.chips(turns: turns, recalls: recalls) {
            out[rows[index].id] = recall
        }
        cache = (ids, sessionID, recalls.count, out)
        return out
    }
}
