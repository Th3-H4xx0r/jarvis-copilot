import Foundation
import Observation

/// Page state for the Dynamic Island settings screen.
///
/// One radio group picks what shows: **Auto** (rules decide) or a specific entry
/// pinned, including the built-in Voice + Coding islands. A management list
/// toggles each entry's inclusion in the Auto pool and deletes custom designs.
/// Designs themselves are authored by Jarvis via the dynamic-island skill, not
/// here.
@Observable
@MainActor
final class IslandDesignsStore {
    /// Radio value standing for "Auto" (no pinned id).
    static let autoKey = "__auto__"

    private let api: IslandDesignsAPI
    // Internal rather than private so the wiring test can assert that the screen
    // really ships with both: without `sync` the widget reads a stale App Group
    // copy, and without `onChanged` a selection change waits out the
    // coordinator's idle-throttled poll.
    let sync: IslandSync?
    /// Poked after a mutation so the island switches immediately rather than
    /// waiting for the coordinator's throttled poll.
    let onChanged: (@Sendable () -> Void)?
    private let task = TaskHandle()

    private(set) var catalog = IslandCatalog.empty
    private(set) var isLoading = true
    /// A mutation is in flight — every control disables while true.
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    var toast: String?

    init(api: IslandDesignsAPI = IslandDesignsAPI(),
         sync: IslandSync? = nil,
         onChanged: (@Sendable () -> Void)? = nil) {
        self.api = api
        self.sync = sync
        self.onChanged = onChanged
    }

    /// The store the app ships: designs cached into the App Group the widget
    /// reads, and every mutation followed by an immediate island refresh.
    ///
    /// A factory rather than `init` defaults because both values are built from
    /// main-actor state, which a default argument expression cannot reach.
    static func production(api: IslandDesignsAPI = IslandDesignsAPI()) -> IslandDesignsStore {
        IslandDesignsStore(
            api: api,
            sync: IslandSync(cache: AppGroupIslandDesignCache()),
            onChanged: {
                Task { @MainActor in await LiveActivityCoordinator.shared.refreshIslandNow() }
            })
    }

    deinit { task.cancel() }

    var entries: [IslandCatalogEntry] { catalog.entries }
    var customEntries: [IslandCatalogEntry] { catalog.customEntries }
    /// Which radio row is selected.
    var selectedKey: String {
        catalog.selection.isAuto ? Self.autoKey : (catalog.selection.pinnedID ?? Self.autoKey)
    }

    func canDelete(_ entry: IslandCatalogEntry) -> Bool { !entry.builtin }

    func load() {
        task.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            catalog = try await api.catalog()
            // Keep the widget's App Group copy in step with what we just loaded.
            if let sync { await sync.sync(catalog.designs) }
        } catch {
            errorMessage = "Could not load designs. Check the server connection."
        }
        isLoading = false
    }

    // MARK: Mutations

    /// Pick Auto or pin one entry.
    func select(_ key: String) async {
        await guarded {
            if key == Self.autoKey {
                try await self.api.setSelection("auto")
            } else {
                try await self.api.setSelection("pinned", pinnedID: key)
            }
        }
    }

    /// Include/exclude an entry from the Auto rotation.
    func setEnabled(_ id: String, _ enabled: Bool) async {
        await guarded { try await self.api.setRules(id, enabled: enabled) }
    }

    func setPriority(_ id: String, _ priority: Int) async {
        await guarded { try await self.api.setRules(id, priority: priority) }
    }

    func delete(_ entry: IslandCatalogEntry) async {
        await guarded { try await self.api.deleteDesign(entry.id) }
    }

    /// Serialise mutations, poke the coordinator, then reload the catalog.
    private func guarded(_ op: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        do {
            try await op()
            onChanged?()
            await refresh()
        } catch {
            toast = "That didn’t go through. Try again."
        }
        isBusy = false
    }
}
