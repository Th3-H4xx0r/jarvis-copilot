import Foundation

/// One entry in the server's model catalogue.
struct ChatModel: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let label: String
    /// The human-facing provider NAME ("Anthropic", "My Box") — what the picker
    /// groups its sections under.
    let provider: String
    /// The canonical provider id the server routes on ("anthropic",
    /// "custom:foo"), sent as `model_provider` with every turn.
    ///
    /// Kept apart from ``provider`` because they are genuinely different strings:
    /// sending the display name routed nowhere and the server quietly fell back
    /// to its own default model. Older servers send no `provider_id`, and the
    /// display name is then the only id there is — Flutter's
    /// `_ModelOption.providerForSave`.
    let providerID: String

    init(id: String, label: String? = nil, provider: String = "", providerID: String? = nil) {
        self.id = id
        self.label = (label?.isEmpty == false ? label : nil) ?? id
        self.provider = provider
        self.providerID = (providerID?.isEmpty == false ? providerID : nil) ?? provider
    }
}

/// `GET /api/models` — what's available and what the server is currently using.
struct ModelCatalog: Equatable, Sendable {
    var defaultModel: String = ""
    var activeModel: String?
    var activeProvider: String?
    var models: [ChatModel] = []

    /// Providers in the order the server listed them (the picker's section order).
    var providers: [String] {
        var seen = Set<String>()
        return models.compactMap { seen.insert($0.provider).inserted ? $0.provider : nil }
    }

    func models(for provider: String) -> [ChatModel] { models.filter { $0.provider == provider } }

    init(json object: [String: Any]) {
        defaultModel = object.string("default_model") ?? object.string("default") ?? ""
        activeModel = object.string("active_model") ?? object.dict("active")?.string("model")
        activeProvider = object.string("active_provider") ?? object.dict("active")?.string("provider")

        // Newer servers group by provider; older ones send one flat list. The
        // grouped shape carries `provider_id` once per GROUP, the flat one per
        // model (`webui/api/config.py get_available_models`).
        for group in object.list("groups") {
            let provider = group.string("provider") ?? ""
            let providerID = group.string("provider_id")
            for model in group.list("models") {
                guard let id = model.string("id"), !id.isEmpty else { continue }
                models.append(ChatModel(id: id, label: model.string("label"),
                                        provider: provider, providerID: providerID))
            }
        }
        if models.isEmpty {
            for item in (object["models"] as? [Any] ?? []) {
                if let dict = item as? [String: Any], let id = dict.string("id"), !id.isEmpty {
                    models.append(ChatModel(id: id, label: dict.string("label"),
                                            provider: dict.string("provider") ?? "",
                                            providerID: dict.string("provider_id")))
                } else if let id = item as? String, !id.isEmpty {
                    models.append(ChatModel(id: id))
                }
            }
        }
    }

    init() {}
}

/// `/api/models` — list available models and set the active one.
/// Ported from `api/models.dart`.
struct ModelsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func list() async throws -> ModelCatalog {
        ModelCatalog(json: try await api.get("/api/models").object())
    }

    func setActive(model: String?, provider: String?) async throws {
        var body: [String: Any] = [:]
        if let model { body["model"] = model }
        if let provider { body["provider"] = provider }
        _ = try await api.post("/api/model/active", json: body)
    }
}
