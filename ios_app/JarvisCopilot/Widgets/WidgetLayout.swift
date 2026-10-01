import Foundation

/// One block in the widget builder: a stat, a chart, a 3D model, a button… bound to a value from
/// the data hub, compiled to the renderer's node tree.
struct WidgetBlock: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case stat, text, symbol, gauge, progress, chart, sparkline, model, button, toggle, spacer, divider

        var id: String { rawValue }

        var label: String {
            switch self {
            case .stat: return "Number"
            case .text: return "Text"
            case .symbol: return "Symbol"
            case .gauge: return "Ring gauge"
            case .progress: return "Progress bar"
            case .chart: return "Chart"
            case .sparkline: return "Sparkline"
            case .model: return "3D model"
            case .button: return "Button"
            case .toggle: return "Switch"
            case .spacer: return "Space"
            case .divider: return "Divider"
            }
        }

        var symbol: String {
            switch self {
            case .stat: return "number"
            case .text: return "textformat"
            case .symbol: return "star"
            case .gauge: return "gauge.with.dots.needle.67percent"
            case .progress: return "chart.bar.fill"
            case .chart: return "chart.xyaxis.line"
            case .sparkline: return "waveform.path.ecg"
            case .model: return "cube"
            case .button: return "hand.tap"
            case .toggle: return "switch.2"
            case .spacer: return "arrow.left.and.right"
            case .divider: return "minus"
            }
        }

        /// Whether the block shows a value from the data hub.
        var binds: Bool { [.stat, .text, .gauge, .progress, .chart, .sparkline].contains(self) }
    }

    var id = UUID().uuidString
    var kind: Kind
    /// A data hub key (`health.steps`).
    var source: String?
    /// A caption, or the text itself for a text block with no source.
    var label: String?
    var symbol: String?
    /// "#RRGGBB".
    var color: String?
    /// Font size, or a model's or chart's height.
    var size: Double?
    /// line, bar or area.
    var chartStyle: String?
    /// A Control Center button id.
    var button: String?
    /// A wearable key, for a 3D model.
    var device: String?
    /// "{}" placeholder, e.g. "{} bpm".
    var format: String?
    /// Full scale of a gauge or progress bar.
    var max: Double?

    /// The value binding.
    private var ref: Any? {
        guard let source, !source.isEmpty else { return nil }
        var out: [String: Any] = ["src": source]
        if let format, !format.isEmpty { out["fmt"] = format }
        return out
    }

    private var style: [String: Any] {
        var out: [String: Any] = [:]
        if let color { out["color"] = color }
        if let size { out["size"] = size }
        return out
    }

    private func caption(_ child: [String: Any]) -> [String: Any] {
        guard let label, !label.isEmpty else { return child }
        return ["type": "vstack", "align": "leading", "spacing": 2, "children": [
            ["type": "text", "value": label, "style": ["size": 11, "opacity": 0.6, "weight": "semibold"]],
            child,
        ]]
    }

    func compile() -> [String: Any] {
        var node: [String: Any]
        switch kind {
        case .stat:
            node = ["type": "stat", "value": ref ?? "—"]
            if let unit = source.flatMap(WidgetDataCatalog.entry)?.unit, format == nil { node["unit"] = unit }
            if !style.isEmpty { node["style"] = style }
            return caption(node)
        case .text:
            node = ["type": "text", "value": ref ?? (label ?? ""), "lineLimit": 4]
            if !style.isEmpty { node["style"] = style }
            return node
        case .symbol:
            node = ["type": "symbol", "name": symbol ?? "star.fill"]
            node["style"] = style.merging(["size": size ?? 22]) { a, _ in a }
            return node
        case .gauge:
            node = ["type": "gauge", "value": ref ?? 0, "scale": max ?? 100, "label": ref ?? ""]
            if let color { node["rings"] = [["value": ref ?? 0, "tint": color]] }
            return caption(node)
        case .progress:
            node = ["type": "progress", "value": ref ?? 0, "scale": max ?? 100]
            if let color { node["tint"] = color }
            return caption(node)
        case .chart:
            node = ["type": "chart", "series": ref ?? [], "style": chartStyle ?? "line", "height": size ?? 60]
            if let color { node["color"] = color }
            return caption(node)
        case .sparkline:
            node = ["type": "sparkline", "points": ref ?? [], "kind": chartStyle == "area" ? "area" : "line"]
            if let color { node["tint"] = color }
            return caption(node)
        case .model:
            return ["type": "model", "device": device ?? "x5ring", "style": ["height": size ?? 80]]
        case .button:
            node = ["type": "button", "button": button ?? ""]
            if let label, !label.isEmpty { node["label"] = label }
            if let symbol { node["symbol"] = symbol }
            return node
        case .toggle:
            node = ["type": "toggle", "button": button ?? ""]
            if let label, !label.isEmpty { node["label"] = label }
            return node
        case .spacer:
            return ["type": "spacer"]
        case .divider:
            return ["type": "divider"]
        }
    }
}

struct WidgetRow: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var blocks: [WidgetBlock]
    var spacing: Double = 8

    func compile() -> [String: Any] {
        ["type": "hstack", "align": "center", "spacing": spacing, "children": blocks.map { $0.compile() }]
    }
}

struct WidgetLayout: Codable, Equatable {
    var rows: [WidgetRow] = []
    var spacing: Double = 8

    func compile() -> [String: Any] {
        ["type": "vstack", "align": "leading", "spacing": spacing, "children": rows.map { $0.compile() }]
    }
}

/// A widget design as the builder edits it: a rows-of-blocks layout for each size it designs.
/// Compiles to the design JSON the widget and the server use, carrying itself under `builder`
/// so the creator can open it again.
struct WidgetDesignDraft: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var icon: String
    var tint: String?
    /// By `WidgetSize.rawValue`.
    var layouts: [String: WidgetLayout]

    static func blank(name: String) -> WidgetDesignDraft {
        WidgetDesignDraft(id: slug(name), name: name, icon: "square.grid.2x2", tint: nil,
                          layouts: [WidgetSize.small.rawValue: WidgetLayout()])
    }

    /// A design id from a name: lowercase words joined by "-", plus a short tail so two designs
    /// with the same name don't collide.
    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.joined(separator: "-")
        let tail = String(UUID().uuidString.lowercased().prefix(4))
        let head = String(words.prefix(48))
        return head.isEmpty ? "widget-\(tail)" : "\(head)-\(tail)"
    }

    func layout(_ size: WidgetSize) -> WidgetLayout? { layouts[size.rawValue] }

    /// Every data key the layouts bind.
    var sources: [String] {
        layouts.values.flatMap { $0.rows.flatMap { $0.blocks.compactMap(\.source) } }
    }

    func compile() -> Data {
        var presentations: [String: Any] = [:]
        for (size, layout) in layouts where !layout.rows.isEmpty || size == WidgetSize.small.rawValue {
            presentations[size] = layout.compile()
        }
        var design: [String: Any] = ["schema": 1, "id": id, "name": name, "icon": icon,
                                     "presentations": presentations]
        if let tint { design["tint"] = tint }
        if let builder = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) { design["builder"] = builder }
        return (try? JSONSerialization.data(withJSONObject: design, options: [.sortedKeys])) ?? Data()
    }

    /// The builder layout saved in a design; nil for a design written by hand (or by Jarvis).
    init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let builder = object["builder"],
              let data = try? JSONSerialization.data(withJSONObject: builder),
              let draft = try? JSONDecoder().decode(WidgetDesignDraft.self, from: data) else { return nil }
        self = draft
    }

    init(id: String, name: String, icon: String, tint: String?, layouts: [String: WidgetLayout]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tint = tint
        self.layouts = layouts
    }
}
