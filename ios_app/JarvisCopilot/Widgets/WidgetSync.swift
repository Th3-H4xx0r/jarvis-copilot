import Foundation
import WidgetKit

struct WidgetUpsert: Equatable {
    let saved: Data
    let warnings: [String]
}

/// The server's widget designs (`/api/widgets`), as the phone needs them.
protocol WidgetDesignsServing {
    func designs() async throws -> [Data]
    func upsert(_ design: Data) async throws -> WidgetUpsert
    func delete(_ id: String) async throws
    func postCatalog(_ entries: [[String: Any]]) async throws
}

struct WidgetDesignsAPI: WidgetDesignsServing {
    var api: JarvisAPI = .shared

    func designs() async throws -> [Data] {
        let body = try await api.get("/api/widgets/designs").object()
        return (body["designs"] as? [[String: Any]] ?? []).compactMap {
            try? JSONSerialization.data(withJSONObject: $0)
        }
    }

    func upsert(_ design: Data) async throws -> WidgetUpsert {
        let object = try JSONSerialization.jsonObject(with: design)
        let body = try await api.post("/api/widgets/designs", json: object).object()
        let saved = (body["design"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? design
        return WidgetUpsert(saved: saved, warnings: body["warnings"] as? [String] ?? [])
    }

    func delete(_ id: String) async throws {
        _ = try await api.delete("/api/widgets/designs/\(id)")
    }

    func postCatalog(_ entries: [[String: Any]]) async throws {
        _ = try await api.post("/api/widgets/catalog", json: ["catalog": entries])
    }
}

/// Keeps the phone's widget designs and the server's in step. The phone saves first and pushes
/// after, so the creator works offline; a design not yet accepted by the server is never
/// dropped by a pull, and is pushed again on the next sync.
@MainActor
final class WidgetSync {
    static let shared = WidgetSync(server: WidgetDesignsAPI())

    enum SaveOutcome: Equatable {
        case saved(warnings: [String])
        /// Kept on the phone; the server couldn't be reached and gets it later.
        case local(String)
        /// The server refused it (it stays on the phone, as saved).
        case rejected(String)
    }

    private let server: WidgetDesignsServing
    private let directory: URL?
    private let defaults: UserDefaults
    private let reload: () -> Void
    private let buttons: () -> [ControlButtonInfo]

    private static let pendingKey = "jc.widgets.pendingPush"
    private static let deletedKey = "jc.widgets.pendingDelete"
    private static let localOnlyKey = "jc.widgets.localOnly"

    /// Saves that finished while a pull's request was out: that pull's list can't know them.
    private var savedDuringPull: Set<String> = []
    private var pulling = false

    init(server: WidgetDesignsServing, directory: URL? = WidgetDesignCache.directory,
         defaults: UserDefaults = ControlButtonShelf.defaults,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetDataHub.widgetKind) },
         buttons: @escaping () -> [ControlButtonInfo] = { ControlButtonShelf.infos() }) {
        self.server = server
        self.directory = directory
        self.defaults = defaults
        self.reload = reload
        self.buttons = buttons
    }

    private var pending: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.pendingKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.pendingKey) }
    }

    private var pendingDeletes: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.deletedKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.deletedKey) }
    }

    /// Designs the server refused: they stay on this phone, as the user saved them.
    private var localOnly: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.localOnlyKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.localOnlyKey) }
    }

    /// Everything: push what's waiting, pull the server's, tell it what can be bound.
    func sync() async {
        await pushPending()
        await pull()
        await postCatalog()
    }

    /// The server's designs into the cache; the server's deletions out of it.
    func pull() async {
        pulling = true
        savedDuringPull = []
        defer { pulling = false }
        guard let designs = try? await server.designs() else { return }
        let waiting = pending.union(localOnly).union(savedDuringPull)
        var seen: Set<String> = []
        for json in designs {
            guard let id = (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["id"] as? String,
                  !pendingDeletes.contains(id) else { continue }
            seen.insert(id)
            if waiting.contains(id) { continue }
            try? WidgetDesignCache.save(json, in: directory)
        }
        for info in WidgetDesignCache.infos(in: directory) where !seen.contains(info.id) && !waiting.contains(info.id) {
            WidgetDesignCache.remove(info.id, in: directory)
        }
        reload()
    }

    @discardableResult
    func save(_ json: Data) async throws -> SaveOutcome {
        let info = try WidgetDesignCache.save(json, in: directory)
        pending.insert(info.id)
        if pulling { savedDuringPull.insert(info.id) }
        reload()
        do {
            let result = try await server.upsert(json)
            try? WidgetDesignCache.save(result.saved, in: directory)
            pending.remove(info.id)
            localOnly.remove(info.id)
            reload()
            return .saved(warnings: result.warnings)
        } catch APIError.http(let status, let message) where status == 400 || status == 422 {
            // The design itself is wrong: keep it here, don't keep retrying it.
            pending.remove(info.id)
            localOnly.insert(info.id)
            return .rejected(message)
        } catch {
            // Unreachable, signed out, the route not deployed yet: it goes on the next sync.
            return .local(error.localizedDescription)
        }
    }

    func delete(_ id: String) async {
        WidgetDesignCache.remove(id, in: directory)
        pending.remove(id)
        localOnly.remove(id)
        reload()
        do {
            try await server.delete(id)
        } catch APIError.http(status: 404, _) {
            // Never reached the server: nothing to delete there.
        } catch {
            pendingDeletes.insert(id)
        }
    }

    private func pushPending() async {
        for id in pendingDeletes {
            do {
                try await server.delete(id)
                pendingDeletes.remove(id)
            } catch APIError.http(status: 404, _) {
                pendingDeletes.remove(id)  // the server never had it
            } catch {}
        }
        for id in pending {
            guard let json = WidgetDesignCache.rawJSON(id, in: directory) else { pending.remove(id); continue }
            if let result = try? await server.upsert(json) {
                try? WidgetDesignCache.save(result.saved, in: directory)
                pending.remove(id)
            }
        }
    }

    /// What a design can bind and which buttons it can run, so Jarvis uses real keys and ids.
    func postCatalog() async {
        var entries = WidgetDataCatalog.entries.map(\.json)
        for button in buttons() {
            entries.append(["key": "controls.\(button.id)", "label": button.name, "area": "controls",
                            "kind": button.keepsState == true ? "toggle" : "button"])
        }
        try? await server.postCatalog(entries)
    }
}
