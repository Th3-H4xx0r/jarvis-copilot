import Foundation

/// What a widget's buttons run their Ask Jarvis on, overriding each button's own choice.
/// Kept in the design as `"agent"`: `{"kind":"default"}`, `{"kind":"harness","id":…}` or
/// `{"kind":"model","id":…,"provider":…}`. No `agent` = each button's own choice.
enum WidgetAgent: Codable, Equatable, Hashable, Sendable {
    /// His one Default (model or harness), whatever the button picked.
    case `default`
    case harness(String)
    case model(id: String, provider: String?)

    private enum Keys: String, CodingKey { case kind, id, provider }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "default":
            self = .default
        case "harness":
            self = .harness(try c.decode(String.self, forKey: .id))
        case "model":
            self = .model(id: try c.decode(String.self, forKey: .id),
                          provider: try c.decodeIfPresent(String.self, forKey: .provider))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown agent kind \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .default:
            try c.encode("default", forKey: .kind)
        case .harness(let id):
            try c.encode("harness", forKey: .kind)
            try c.encode(id, forKey: .id)
        case .model(let id, let provider):
            try c.encode("model", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(provider, forKey: .provider)
        }
    }
}
