import Foundation

/// One row in the Skills list — a `LocalSkill` flattened to the values the view
/// needs, so the list logic is pure and testable without the registry.
struct SkillListItem: Identifiable, Equatable, Sendable {
    var name: String
    var detail: String
    /// Opens a URL / app / system UI, so the invoke runner defers it when the
    /// app is backgrounded. Worth a different glyph — these are the skills that
    /// can't run silently.
    var requiresForeground: Bool
    var enabled: Bool
    /// `LocalSkill` carries no category today, so this is always nil and the list
    /// groups alphabetically. Kept as the seam for when skills gain one — the
    /// grouping already switches on it.
    var category: String?

    var id: String { name }

    init(name: String, detail: String, requiresForeground: Bool = false,
         enabled: Bool = true, category: String? = nil) {
        self.name = name
        self.detail = detail
        self.requiresForeground = requiresForeground
        self.enabled = enabled
        self.category = category
    }
}

/// A titled run of rows: a category when the skills carry one, otherwise the
/// initial letter.
struct SkillSection: Identifiable, Equatable, Sendable {
    var title: String
    var items: [SkillListItem]

    var id: String { title }
}

enum SkillsGrouping {

    /// Case-insensitive substring match over the name AND the description — the
    /// description is where "copy", "clipboard", "torch" actually live, and the
    /// user searching for a capability shouldn't need the skill's exact name.
    static func matches(_ item: SkillListItem, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return item.name.lowercased().contains(needle)
            || item.detail.lowercased().contains(needle)
    }

    static func filter(_ items: [SkillListItem], query: String) -> [SkillListItem] {
        items.filter { matches($0, query: query) }
    }

    /// Group for display: by category when EVERY row has one, else by the
    /// initial letter. Sections and rows are both sorted; a name that doesn't
    /// start with a letter lands in "#".
    static func sections(_ items: [SkillListItem]) -> [SkillSection] {
        guard !items.isEmpty else { return [] }
        let byCategory = items.allSatisfy { ($0.category?.isEmpty == false) }
        var buckets: [String: [SkillListItem]] = [:]
        for item in items {
            let key = byCategory ? (item.category ?? "") : initial(of: item.name)
            buckets[key, default: []].append(item)
        }
        return buckets.keys.sorted().map { key in
            SkillSection(title: key, items: buckets[key]!.sorted { $0.name < $1.name })
        }
    }

    /// The uppercase first letter of a name, or "#" when it doesn't start with one.
    static func initial(of name: String) -> String {
        guard let first = name.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    /// "12 of 18 on" — the header counter.
    static func summary(_ items: [SkillListItem]) -> String {
        let on = items.filter(\.enabled).count
        return "\(on) of \(items.count) on"
    }
}

// MARK: - Test-run argument form

/// One input derived from a skill's JSON Schema.
struct SkillArgField: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case text, number, integer, boolean, choice
    }

    var key: String
    var kind: Kind
    var detail: String
    var required: Bool
    /// Non-empty only for `.choice`.
    var options: [String]

    var id: String { key }

    init(key: String, kind: Kind, detail: String = "", required: Bool = false,
         options: [String] = []) {
        self.key = key
        self.kind = kind
        self.detail = detail
        self.required = required
        self.options = options
    }
}

/// Turns a skill's `input_schema` into a small form and back into an args map,
/// so "Test skill" can drive any registered skill without hand-written UI per
/// skill. Only the shapes `SkillSchema` actually produces are supported —
/// anything else falls back to a free-text field, which the skill can still
/// parse.
enum SkillArgsForm {

    /// Fields in display order: required first, then alphabetical.
    static func fields(from schema: [String: Any]) -> [SkillArgField] {
        guard let properties = schema["properties"] as? [String: Any] else { return [] }
        let required = Set((schema["required"] as? [Any])?.map { SkillArgs.text($0) } ?? [])
        let fields: [SkillArgField] = properties.compactMap { key, value in
            guard let spec = value as? [String: Any] else {
                return SkillArgField(key: key, kind: .text, required: required.contains(key))
            }
            return SkillArgField(key: key,
                                 kind: kind(of: spec),
                                 detail: SkillArgs.text(spec["description"]),
                                 required: required.contains(key),
                                 options: (spec["enum"] as? [Any])?.map { SkillArgs.text($0) } ?? [])
        }
        return fields.sorted {
            $0.required == $1.required ? $0.key < $1.key : ($0.required && !$1.required)
        }
    }

    private static func kind(of spec: [String: Any]) -> SkillArgField.Kind {
        if spec["enum"] is [Any] { return .choice }
        switch SkillArgs.text(spec["type"]) {
        case "boolean": return .boolean
        case "integer": return .integer
        case "number":  return .number
        default:        return .text
        }
    }

    /// Build the invoke args from what the user typed. A blank field is OMITTED
    /// rather than sent as "" — a skill's own defaults are usually better than an
    /// empty string, and that's what the agent's calls look like too.
    static func arguments(_ values: [String: String], fields: [SkillArgField]) -> [String: Any] {
        var out: [String: Any] = [:]
        for field in fields {
            let raw = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            switch field.kind {
            case .boolean:
                out[field.key] = ["true", "yes", "1", "on"].contains(raw.lowercased())
            case .integer:
                if let n = Int(raw) { out[field.key] = n }
            case .number:
                if let n = Double(raw) { out[field.key] = n }
            case .text, .choice:
                out[field.key] = raw
            }
        }
        return out
    }

    /// Pretty-printed JSON for the result panel; falls back to a description when
    /// the payload isn't JSON-encodable (a skill may return a `Date`, say).
    static func prettyJSON(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}
