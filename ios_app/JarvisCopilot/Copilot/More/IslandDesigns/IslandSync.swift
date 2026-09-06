import Foundation

/// Where cached design definitions go so the widget extension can read them.
///
/// On iOS this is the App Group container; the Flutter build reached it through
/// a `MethodChannel`, and here it is a protocol so the native writer (or a test
/// double) can be injected. Every call is fire-and-forget — a cache write
/// failing must never break the settings screen.
protocol IslandDesignCache: Sendable {
    /// Push `[{id, version, json}]` payloads for the designs whose content changed.
    func cacheDesigns(_ payloads: [JSONObject]) async
    /// Drop every cached `design-<id>.json`.
    func clearCache() async
}

/// Caches design definitions, re-pushing only the ones whose CONTENT changed
/// since the last sync — keyed on `IslandDesign.contentSignature` (the whole
/// tree), NOT `version`, so a layout edit re-caches live even when Jarvis
/// doesn't bump the version. A steady catalog produces no writes at all.
actor IslandSync {
    private let cache: IslandDesignCache
    /// design id → last-pushed content signature.
    private var cached: [String: Int] = [:]

    init(cache: IslandDesignCache) { self.cache = cache }

    func sync(_ designs: [IslandDesign]) async {
        let ids = Set(designs.map(\.id))
        // A design disappeared from the catalog → clear the whole cache and
        // re-push, so stale `design-<id>.json` files don't linger on device.
        if cached.keys.contains(where: { !ids.contains($0) }) {
            await cache.clearCache()
            cached.removeAll()
        }

        let changed = designs.filter { cached[$0.id] != $0.contentSignature }
        guard !changed.isEmpty else { return }

        await cache.cacheDesigns(changed.map {
            ["id": $0.id, "version": $0.version, "json": $0.jsonString]
        })
        for design in changed { cached[design.id] = design.contentSignature }
    }

    func reset() { cached.removeAll() }

    /// Signatures currently believed to be on device (tests / diagnostics).
    var cachedSignatures: [String: Int] { cached }
}

/// A cache that drops everything on the floor — the default until the native
/// App Group writer lands, and what non-iOS contexts get.
struct NoopIslandDesignCache: IslandDesignCache {
    func cacheDesigns(_ payloads: [JSONObject]) async {}
    func clearCache() async {}
}
