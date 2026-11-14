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
    /// `/api/integrations` for a regular integration, `/api/power` for a Power one
    /// (same `/<id>/ui` and `/<id>/ui/action` shapes).
    let basePath: String
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
    /// The newest press made while another script ran; it runs next (latest wins).
    private var queued: IntegrationUIAction?
    /// Bumped by every action, so a load that started before it can't overwrite
    /// the newer state it brought back.
    private var generation = 0

    init(integrationID: String, presentation: Presentation,
         basePath: String = "/api/integrations", api: JarvisAPI = .shared) {
        self.integrationID = integrationID
        self.presentation = presentation
        self.basePath = basePath
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
        guard running == nil else { return }
        apply(rootJSON: card.rootJSON, version: card.version, confirms: card.confirms,
              state: card.state, error: card.error)
    }

    var context: JCBindingContext { JCBindingContext(data: state) }

    // MARK: Loading

    func load() async {
        loading = true
        defer { loading = false }
        let started = generation
        do {
            let body = try await api.get("\(basePath)/\(escaped)/ui", timeout: 45).object()
            // An action ran meanwhile: its state is newer than this load's.
            guard started == generation, running == nil else { return }
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
        // A failed load keeps the last good state on screen under its error (the
        // server's "last good" is empty after a restart).
        if let state, error == nil || !state.isEmpty { self.state = state }
        self.error = error
        hasLoaded = true
        saveCache()
    }

    // MARK: Inputs

    /// What an input control shows: its edited value, else its bound/literal value.
    /// `key` is the control id, or `id#rowid` for a control inside a list row.
    func value(of key: String, bound: JCJSON?) -> JCJSON? { inputs[key] ?? bound }

    func setInput(_ key: String, _ value: JCJSON) { inputs[key] = value }

    /// The key an input control keeps its value under: per row inside a list.
    nonisolated static func inputKey(_ id: String, row: [String: JCJSON]?) -> String {
        guard let row, let rid = (row["id"] ?? row["key"] ?? row["name"])?.asString else { return id }
        return "\(id)#\(rid)"
    }

    /// The person backed out of a confirm: a picker/slider/etc. goes back to the state.
    func cancelPending() {
        if let action = pendingConfirm, action.revertsInput { inputs[action.inputKey] = nil }
        pendingConfirm = nil
    }

    /// What every input control on the tree shows now, for the scripts' `inputs`:
    /// edited values, else the bound value, else the control's own default.
    private func currentInputs() -> [String: Any] {
        var out: [String: Any] = [:]
        guard let root else { return out }
        let ctx = context
        func walk(_ n: JCNode, inList: Bool) {
            if !inList, let id = n.string("id"),
               ["textField", "picker", "slider", "stepper", "date"].contains(n.type) {
                let shown = inputs[id] ?? n.ref("value")?.resolve(ctx) ?? Self.defaultValue(n, ctx)
                if let shown { out[id] = shown.foundation }
            }
            for (key, value) in n.props {
                let nested = inList || n.type == "list" && key == "row"
                if let child = value.asNode(), !child.type.isEmpty { walk(child, inList: nested) }
                for child in value.asNodeArray() ?? [] where !child.type.isEmpty { walk(child, inList: nested) }
            }
        }
        walk(root, inList: false)
        return out
    }

    /// A control's value when neither the person nor the state set one.
    nonisolated static func defaultValue(_ n: JCNode, _ ctx: JCBindingContext) -> JCJSON? {
        switch n.type {
        case "picker":
            let first = (n.ref("options")?.array(ctx) ?? n.props["options"]?.asArray ?? []).first
            return first.flatMap { $0.asObject?["value"] ?? $0.asObject?["label"] ?? $0 }
        case "slider", "stepper": return .number(n.double("min") ?? 0)
        case "date": return .string(IntegrationUIDates.format(Date(), mode: n.string("mode") ?? "date"))
        case "textField": return .string("")
        default: return nil
        }
    }

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
        // Never dropped: the newest press waits for the running one, then runs.
        guard running == nil else {
            queued = action
            return
        }
        generation += 1
        running = action.busyKey
        var body: [String: Any] = [
            "action": action.name,
            "inputs": currentInputs(),
            "version": version,
        ]
        body["control"] = action.control ?? NSNull()
        body["value"] = action.value?.foundation ?? NSNull()
        body["row"] = action.row.map { JCJSON.object($0).foundation } ?? NSNull()
        do {
            let reply = try await api.post("\(basePath)/\(escaped)/ui/action",
                                           json: body, timeout: 90).object()
            let failure = IntegrationUIDecode.text(reply["error"])
            let ok = (reply["ok"] as? Bool) ?? (failure == nil)
            // A failure leaves the screen as it was (the server's "last good" may be empty).
            if ok, let next = IntegrationUIDecode.state(reply["state"]) { state = next }
            error = failure
            if ok {
                toast = IntegrationUIDecode.text(reply["toast"])
                // The control now shows the state, when it is bound to it.
                if action.clearsInputOnSuccess { inputs[action.inputKey] = nil }
                if action.submitsForm {
                    inputs = inputs.filter { !action.formFields.contains($0.key) }
                }
            } else if action.revertsInput {
                inputs[action.inputKey] = nil
            }
            saveCache()
            running = nil
            // Jarvis changed the layout since this one loaded.
            if let newer = reply["version"] as? Int, newer != 0, newer != version { await load() }
        } catch {
            self.error = apiErrorMessage(error)
            if action.revertsInput { inputs[action.inputKey] = nil }
            running = nil
        }
        if let next = queued {
            queued = nil
            await perform(next)
        }
    }

    // MARK: Cache

    private var cacheURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("IntegrationUI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = integrationID.replacingOccurrences(of: "/", with: "_")
        let kind = basePath == "/api/integrations" ? "" : "power-"   // a Power id may equal a space id
        return dir.appendingPathComponent("\(kind)\(safe)-\(presentation.rawValue).json")
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
    /// A picker/slider/stepper/date shows its new value while the script runs; it goes
    /// back to the state's value when the script fails or the person cancels.
    var revertsInput = false
    /// The control's `value` is bound to state: after success the state says what it is.
    var clearsInputOnSuccess = true

    var id: String { busyKey }
    /// Where the control keeps its input: per row inside a list.
    var inputKey: String {
        IntegrationUIStore.inputKey(control ?? name, row: row)
    }
    /// What shows the spinner: the control (per row), else the action (per row).
    var busyKey: String { inputKey }
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
