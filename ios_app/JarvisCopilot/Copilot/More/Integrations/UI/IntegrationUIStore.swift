import Foundation
import Observation

/// One integration's own UI: the layout Jarvis designed for it, the state its `load`
/// script built, and the actions that run its scripts.
///
/// The UI never changes data itself. Every tap, toggle or submit is posted to the
/// server, which runs that action's script; what comes back is the new state. While
/// a script runs, the control that started it shows a spinner.
///
/// Layout + state are cached on disk per integration, so a page or card draws at
/// once and is still readable offline.
@Observable
@MainActor
final class IntegrationUIStore {
    enum Presentation: String { case card, page }

    let integrationID: String
    let presentation: Presentation
    private let api: JarvisAPI

    /// The tree for this presentation; nil until loaded, or when there is none.
    private(set) var root: JCNode?
    /// The same tree as JSON, kept for the disk cache (JCNode only decodes).
    private var rootJSON: Any?
    private(set) var version = 0
    private(set) var state: [String: JCJSON] = [:]
    /// Confirm text per action, from the scripts that declare one.
    private(set) var confirms: [String: String] = [:]
    /// Edited values of the input controls, by control id. A control nobody has
    /// touched shows its bound value instead.
    private(set) var inputs: [String: JCJSON] = [:]
    /// The control (or action, for controls without an id) whose script is running.
    private(set) var running: String?
    private(set) var loading = false
    private(set) var hasLoaded = false
    /// The load script's or the last action's failure, shown above the UI.
    private(set) var error: String?
    var toast: String?
    /// An action waiting for the person to confirm it.
    var pendingConfirm: IntegrationUIAction?

    init(integrationID: String, presentation: Presentation, api: JarvisAPI = .shared) {
        self.integrationID = integrationID
        self.presentation = presentation
        self.api = api
        restoreCache()
    }

    /// A card seeded from `/api/integration-cards`, which already ran `load`.
    convenience init(card: IntegrationUICard, api: JarvisAPI = .shared) {
        self.init(integrationID: card.id, presentation: .card, api: api)
        update(from: card)
    }

    /// A newer `/api/integration-cards` reply for the same card.
    func update(from card: IntegrationUICard) {
        apply(rootJSON: card.rootJSON, version: card.version, confirms: card.confirms,
              state: card.state, error: card.error)
    }

    var context: JCBindingContext { JCBindingContext(data: state) }

    // MARK: Loading

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let body = try await api.get("/api/integrations/\(escaped)/ui", timeout: 45).object()
            let definition = body["definition"] as? [String: Any]
            let presentations = definition?["presentations"] as? [String: Any]
            apply(rootJSON: presentations?[presentation.rawValue],
                  version: (body["version"] as? Int) ?? (definition?["version"] as? Int) ?? 0,
                  confirms: IntegrationUIDecode.confirms(definition?["scripts"]),
                  state: IntegrationUIDecode.state(body["state"]),
                  error: IntegrationUIDecode.text(body["error"]))
        } catch {
            // The cached layout stays; only say what failed.
            self.error = apiErrorMessage(error)
            hasLoaded = true
        }
    }

    private func apply(rootJSON: Any?, version: Int, confirms: [String: String],
                       state: [String: JCJSON]?, error: String?) {
        self.rootJSON = rootJSON
        root = rootJSON.flatMap(IntegrationUIDecode.node)
        self.version = version
        self.confirms = confirms
        // A failed load keeps the last good state on screen under its error.
        if let state { self.state = state }
        self.error = error
        hasLoaded = true
        saveCache()
    }

    // MARK: Inputs

    /// What an input control shows: its edited value, else its bound/literal value.
    func value(of id: String, bound: JCJSON?) -> JCJSON? { inputs[id] ?? bound }

    func setInput(_ id: String, _ value: JCJSON) { inputs[id] = value }

    // MARK: Actions

    /// Asks first when the action's script declares `confirm`.
    func request(_ action: IntegrationUIAction) {
        if let text = confirms[action.name], !text.isEmpty {
            pendingConfirm = action
        } else {
            Task { await perform(action) }
        }
    }

    func perform(_ action: IntegrationUIAction) async {
        guard running == nil else { return }
        running = action.busyKey
        defer { running = nil }
        var body: [String: Any] = [
            "action": action.name,
            "inputs": inputs.mapValues(\.foundation),
            "version": version,
        ]
        body["control"] = action.control ?? NSNull()
        body["value"] = action.value?.foundation ?? NSNull()
        body["row"] = action.row.map { JCJSON.object($0).foundation } ?? NSNull()
        do {
            let reply = try await api.post("/api/integrations/\(escaped)/ui/action",
                                           json: body, timeout: 90).object()
            if let next = IntegrationUIDecode.state(reply["state"]) { state = next }
            let failure = IntegrationUIDecode.text(reply["error"])
            error = failure
            if failure == nil {
                toast = IntegrationUIDecode.text(reply["toast"])
                // Done with what was typed for it: the control shows the state now.
                if let control = action.control { inputs[control] = nil }
                if action.submitsForm {
                    inputs = inputs.filter { !action.formFields.contains($0.key) }
                }
            }
            saveCache()
            // Jarvis changed the layout since this one loaded.
            if let newer = reply["version"] as? Int, newer != 0, newer != version { await load() }
        } catch {
            self.error = apiErrorMessage(error)
        }
    }

    // MARK: Cache

    private var cacheURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("IntegrationUI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = integrationID.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe)-\(presentation.rawValue).json")
    }

    private struct Cached: Codable {
        var root: Data?
        var version: Int
        var confirms: [String: String]
        var state: Data
    }

    private func saveCache() {
        guard let url = cacheURL else { return }
        let rootData = rootJSON.flatMap { value -> Data? in
            JSONSerialization.isValidJSONObject(value) ? try? JSONSerialization.data(withJSONObject: value) : nil
        }
        guard let stateData = try? JSONSerialization.data(
            withJSONObject: state.mapValues(\.foundation)) else { return }
        let cached = Cached(root: rootData, version: version, confirms: confirms, state: stateData)
        if let data = try? JSONEncoder().encode(cached) { try? data.write(to: url, options: .atomic) }
    }

    private func restoreCache() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(Cached.self, from: data) else { return }
        rootJSON = cached.root.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        root = rootJSON.flatMap(IntegrationUIDecode.node)
        version = cached.version
        confirms = cached.confirms
        state = IntegrationUIDecode.state(try? JSONSerialization.jsonObject(with: cached.state)) ?? [:]
        hasLoaded = root != nil
    }

    private var escaped: String {
        integrationID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? integrationID
    }
}

/// One press: which script, from which control, with what value and list row.
struct IntegrationUIAction: Identifiable {
    let name: String
    var control: String?
    var value: JCJSON?
    var row: [String: JCJSON]?
    /// A button / text-field submit: the text fields of the tree are cleared after it.
    var submitsForm = false
    var formFields: Set<String> = []

    var id: String { busyKey }
    /// What shows the spinner: the control, else the action within its row.
    var busyKey: String {
        if let control { return control }
        if let row, let rid = row["id"]?.asString { return "\(name)#\(rid)" }
        return name
    }
}

/// An entry of `GET /api/integration-cards`.
struct IntegrationUICard: Identifiable {
    let id: String
    let name: String
    let icon: String
    let version: Int
    let rootJSON: Any?
    let state: [String: JCJSON]?
    let confirms: [String: String]
    let error: String?

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? id
        icon = json["icon"] as? String ?? ""
        version = json["version"] as? Int ?? 0
        rootJSON = json["card"]
        state = IntegrationUIDecode.state(json["state"])
        confirms = IntegrationUIDecode.confirms(json["confirms"])
            .merging(IntegrationUIDecode.confirms(json["scripts"])) { a, _ in a }
        error = IntegrationUIDecode.text(json["error"])
    }
}

enum IntegrationUIDecode {
    static func node(_ value: Any) -> JCNode? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(JCNode.self, from: data)
    }

    static func state(_ value: Any?) -> [String: JCJSON]? {
        guard let object = value as? [String: Any] else { return nil }
        return object.mapValues { JCJSON(foundation: $0) }
    }

    /// `{"name": "text"}` (cards) or `{"name": {"confirm": "text"}}` (a definition's scripts).
    static func confirms(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (name, entry) in object {
            if let text = entry as? String, !text.isEmpty { out[name] = text }
            if let script = entry as? [String: Any], let text = script["confirm"] as? String,
               !text.isEmpty { out[name] = text }
        }
        return out
    }

    static func text(_ value: Any?) -> String? {
        guard let s = value as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
