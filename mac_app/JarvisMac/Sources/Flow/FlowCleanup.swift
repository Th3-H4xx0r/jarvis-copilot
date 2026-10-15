import Foundation

/// Flow's optional clean-up: a Jarvis model (the server's, through jc-client's
/// proxy) removes the "uh"s, the repeats and the corrections said on the way,
/// fixes the punctuation and writes in the app's style. Off by default. Any
/// problem (not connected, slow answer, odd reply) and the words are pasted as
/// they were heard. Server side: webui/api/agent_notes_routes.py → agent/flow_cleanup.py.
/// After coucou's FlowCleanup (github.com/Louis-CFM/coucou, MIT).
enum FlowCleanup {
    /// Past this, the words are pasted as heard rather than keeping you waiting.
    static let timeout: TimeInterval = 6

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

    static func clean(_ text: String, style: FlowStyle, app: String?, words: [String], origin: String?) async -> String {
        guard let origin, let url = URL(string: "\(origin)/api/flow/cleanup") else { return text }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "style": style.rawValue, "app": app ?? "",
                                   "words": Array(words.prefix(200))]
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
