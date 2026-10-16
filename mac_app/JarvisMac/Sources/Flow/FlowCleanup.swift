import Foundation
import Observation

/// Flow's optional clean-up: a Jarvis model (the server's, through jc-client's
/// proxy) removes the "uh"s, the repeats and the corrections said on the way,
/// fixes the punctuation and writes in the app's style. Off by default. Any
/// problem (not connected, slow answer, odd reply) and the words are pasted as
/// they were heard. Server side: webui/api/agent_notes_routes.py → agent/flow_cleanup.py.
/// After coucou's FlowCleanup (github.com/Louis-CFM/coucou, MIT).
enum FlowCleanup {
    /// Past this, the words are pasted as heard rather than keeping you waiting
    /// (a picked model can be a big one; the server gives it 10 s).
    static let timeout: TimeInterval = 12

    /// Whether a clean-up is worth the round trip.
    static func worthCleaning(_ text: String, style: FlowStyle, enabled: Bool) -> Bool {
        enabled && style != .verbatim && FlowText.wordCount(text) >= 3
    }

    /// A reply empty, or much longer or shorter than what was said, is not a
    /// clean-up (an answer to the words, a refusal).
    static func plausible(_ cleaned: String, from text: String) -> Bool {
        let before = FlowText.wordCount(text), after = FlowText.wordCount(cleaned)
        guard after > 0 else { return false }
        return Double(after) <= Double(before) * 1.4 + 4 && Double(after) >= Double(before) * 0.35
    }

    /// What goes to `/api/flow/cleanup`: the words, the style, the app, your
    /// dictionary, and the model picked in Flow settings (none: Jarvis picks).
    static func body(_ text: String, style: FlowStyle, app: String?, words: [String],
                     model: String?, provider: String?) -> [String: Any] {
        var body: [String: Any] = ["text": text, "style": style.rawValue, "app": app ?? "",
                                   "words": Array(words.prefix(200))]
        if let model, !model.isEmpty {
            body["model"] = model
            body["provider"] = provider ?? ""
        }
        return body
    }

    static func clean(_ text: String, style: FlowStyle, app: String?, words: [String], origin: String?,
                      model: String? = Prefs.flowCleanupModel, provider: String? = Prefs.flowCleanupProvider) async -> String {
        guard let origin, let url = URL(string: "\(origin)/api/flow/cleanup") else { return text }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Self.body(text, style: style, app: app, words: words, model: model, provider: provider)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return text }
        request.httpBody = data
        do {
            let (reply, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  json["cleaned"] as? Bool == true,
                  let cleaned = json["text"] as? String,
                  plausible(cleaned, from: text) else { return text }
            return cleaned
        } catch {
            NSLog("Jarvis Flow: clean-up skipped: \(error.localizedDescription)")
            return text
        }
    }
}

/// One of Jarvis's models, for the clean-up model picker.
struct FlowModelChoice: Hashable, Identifiable, Sendable {
    let id: String
    let label: String
}

/// A provider's models, as `/api/models` groups them.
struct FlowModelGroup: Hashable, Identifiable, Sendable {
    let provider: String
    let providerID: String
    let models: [FlowModelChoice]
    var id: String { providerID }
}

/// Jarvis's models (`/api/models`, through jc-client's proxy) for Flow
/// settings' clean-up model picker.
@MainActor
@Observable
final class FlowModelCatalog {
    static let shared = FlowModelCatalog()

    private(set) var groups: [FlowModelGroup] = []
    private(set) var loading = false
    private(set) var error: String?

    nonisolated static func parse(_ data: Data) -> [FlowModelGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return [] }
        return groups.compactMap { g in
            let models = (g["models"] as? [[String: Any]] ?? []).compactMap { m -> FlowModelChoice? in
                guard let id = m["id"] as? String, !id.isEmpty else { return nil }
                return FlowModelChoice(id: id, label: (m["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id)
            }
            guard !models.isEmpty else { return nil }
            let name = g["provider"] as? String ?? ""
            return FlowModelGroup(provider: name.isEmpty ? (g["provider_id"] as? String ?? "") : name,
                                  providerID: g["provider_id"] as? String ?? "", models: models)
        }
    }

    /// The label for a pick ("Claude Haiku 5 5"), once the list is in.
    func label(model: String, provider: String?) -> String? {
        groups.first { provider == nil || $0.providerID == provider }?.models.first { $0.id == model }?.label
    }

    func load() async {
        guard !loading else { return }
        guard let origin = AppModel.shared.apiOrigin, let url = URL(string: origin + "/api/models") else {
            error = String(localized: "Jarvis isn't connected (jc-client), so its models can't be listed.")
            return
        }
        loading = true
        defer { loading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                error = String(localized: "Jarvis didn't list its models.")
                return
            }
            groups = Self.parse(data)
            error = groups.isEmpty ? String(localized: "Jarvis has no models to pick from.") : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
