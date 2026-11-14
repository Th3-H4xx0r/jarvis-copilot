import SwiftUI

/// Draws an integration's UI tree. The shared `JCDesignRenderer` (the island's and
/// the widgets') does the layout and display nodes; this adds what only an app page
/// has — a grid with column spans, sections, scrolling strips, tappable rows,
/// buttons and inputs — through the renderer's `extra` hook. Every one of those
/// controls runs a script on the server; none of them changes data here.
@MainActor
enum IntegrationUIRenderer {
    static func view(_ root: JCNode, store: IntegrationUIStore) -> AnyView {
        let renderer = JCDesignRenderer(tint: JcTheme.accent, maxDepth: 24, maxNodes: .max)
        let fields = textFieldIDs(in: root)
        renderer.extra = { [weak renderer] node, ctx, depth in
            guard let renderer else { return nil }
            return MainActor.assumeIsolated {
                IntegrationUINodes(renderer: renderer, store: store, formFields: fields)
                    .view(node, ctx, depth)
            }
        }
        return renderer.render(root, store.context)
    }

    /// Every text field in the tree: what a button's press submits and then clears.
    static func textFieldIDs(in node: JCNode) -> Set<String> {
        var out: Set<String> = []
        func walk(_ n: JCNode) {
            if n.type == "textField", let id = n.string("id") { out.insert(id) }
            for (_, value) in n.props {
                if let child = value.asNode(), !child.type.isEmpty { walk(child) }
                for child in value.asNodeArray() ?? [] where !child.type.isEmpty { walk(child) }
            }
        }
        walk(node)
        return out
    }
}

@MainActor
private struct IntegrationUINodes {
    let renderer: JCDesignRenderer
    let store: IntegrationUIStore
    let formFields: Set<String>

    func view(_ n: JCNode, _ ctx: JCBindingContext, _ depth: Int) -> AnyView? {
        let child: (JCNode?) -> AnyView = { renderer.render($0, ctx, depth: depth + 1) }
        switch n.type {
        case "grid":
            return AnyView(IntegrationUIGrid(node: n, render: child))
        case "section":
            // A card is already a card: its sections draw plain inside it.
            return AnyView(IntegrationUISection(node: n, ctx: ctx, plain: store.presentation == .card,
                                                render: child))
        case "list" where n.node("row")?.type == "row":
            return AnyView(IntegrationUIRowList(node: n, ctx: ctx, render: { row, rowCtx in
                renderer.render(row, rowCtx, depth: depth + 1)
            }))
        case "hscroll":
            return AnyView(
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: jcSpacing(n)) {
                        ForEach(jcIndexed(n.nodes("children")), id: \.0) { _, c in child(c) }
                    }
                })
        case "row":
            return AnyView(IntegrationUIRow(node: n, ctx: ctx, store: store))
        case "button":
            guard n.string("action") != nil else { return nil }
            return AnyView(IntegrationUIButton(node: n, ctx: ctx, store: store, formFields: formFields))
        case "toggle":
            guard n.string("action") != nil else { return nil }
            return AnyView(IntegrationUIToggle(node: n, ctx: ctx, store: store))
        case "textField":
            return AnyView(IntegrationUITextField(node: n, ctx: ctx, store: store, formFields: formFields))
        case "picker":
            return AnyView(IntegrationUIPicker(node: n, ctx: ctx, store: store))
        case "slider":
            return AnyView(IntegrationUISlider(node: n, ctx: ctx, store: store))
        case "stepper":
            return AnyView(IntegrationUIStepper(node: n, ctx: ctx, store: store))
        case "date":
            return AnyView(IntegrationUIDate(node: n, ctx: ctx, store: store))
        case "stat":
            // The widget's stat overlays its caption in a few points; a page has room
            // to stack it under the number.
            return AnyView(IntegrationUIStat(node: n, ctx: ctx))
        // Display blocks in the app's type scale rather than the widget's.
        case "text":
            return AnyView(IntegrationUIText(node: n, ctx: ctx))
        case "titleSubtitle":
            return AnyView(IntegrationUITitleSubtitle(node: n, ctx: ctx))
        case "keyValue":
            return AnyView(IntegrationUIKeyValue(node: n, ctx: ctx))
        case "badge":
            let color = n.ref("color")?.color(ctx) ?? JcTheme.accent
            return AnyView(StatusPill(n.ref("text")?.string(ctx) ?? "", color: color, dense: true))
        case "gauge":
            return AnyView(IntegrationUIGauge(node: n, ctx: ctx))
        case "divider":
            return AnyView(Rectangle().fill(JcTheme.border).frame(height: 1))
        case "symbolValue":
            return AnyView(
                HStack(spacing: 8) {
                    if let symbol = n.ref("symbol")?.string(ctx) {
                        Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(JcTheme.muted)
                    }
                    Text(n.ref("value")?.string(ctx) ?? "")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                        .lineLimit(2)
                })
        default:
            return nil
        }
    }
}

// MARK: - Layout

/// Columns with spans: children are packed left to right into rows of `columns`.
private struct IntegrationUIGrid: View {
    let node: JCNode
    let render: (JCNode?) -> AnyView

    private struct Cell { let index: Int; let node: JCNode; let span: Int }

    private var columns: Int { max(1, min(6, node.int("columns") ?? 2)) }

    private var rows: [[Cell]] {
        var out: [[Cell]] = [[]]
        var used = 0
        for (i, child) in node.nodes("children").enumerated() {
            let span = max(1, min(columns, child.int("span") ?? 1))
            if used + span > columns, !(out.last?.isEmpty ?? true) {
                out.append([])
                used = 0
            }
            out[out.count - 1].append(Cell(index: i, node: child, span: span))
            used += span
        }
        return out.filter { !$0.isEmpty }
    }

    var body: some View {
        let spacing = CGFloat(node.double("spacing") ?? 10)
        Grid(alignment: .topLeading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.index) { cell in
                        render(cell.node)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .gridCellColumns(cell.span)
                    }
                    let rest = columns - row.reduce(0) { $0 + $1.span }
                    if rest > 0 {
                        Color.clear.frame(height: 0).gridCellColumns(rest)
                    }
                }
            }
        }
    }
}

/// The app's section: a small uppercase label over a card.
private struct IntegrationUISection: View {
    let node: JCNode
    let ctx: JCBindingContext
    let plain: Bool
    let render: (JCNode?) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = node.ref("title")?.string(ctx), !title.isEmpty {
                JcSectionLabel(title) {
                    if let subtitle = node.ref("subtitle")?.string(ctx) { Text(subtitle) }
                }
            }
            if plain || node.bool("plain") == true {
                content
            } else {
                JcCard { content }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: CGFloat(node.double("spacing") ?? 10)) {
            ForEach(jcIndexed(node.nodes("children")), id: \.0) { _, c in render(c) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The big number, its unit beside it and its caption under it.
private struct IntegrationUIStat: View {
    let node: JCNode
    let ctx: JCBindingContext

    var body: some View {
        let color = node.style?.color.flatMap(jcParseColor) ?? JcTheme.text
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(node.ref("value")?.string(ctx) ?? "—")
                    .font(.system(size: CGFloat(node.style?.size ?? 26), weight: .bold).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = node.ref("unit")?.string(ctx), !unit.isEmpty {
                    Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
            }
            if let caption = node.ref("caption")?.string(ctx), !caption.isEmpty {
                Text(caption).font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(1)
            }
        }
    }
}

private struct IntegrationUITitleSubtitle: View {
    let node: JCNode
    let ctx: JCBindingContext

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.ref("title")?.string(ctx) ?? "")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text).lineLimit(2)
            if let subtitle = node.ref("subtitle")?.string(ctx), !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(2)
            }
        }
    }
}

/// Read-out rows: the label on the left, the value muted on the right, hairlines between.
private struct IntegrationUIKeyValue: View {
    let node: JCNode
    let ctx: JCBindingContext

    var body: some View {
        let pairs = (node.ref("pairs")?.array(ctx) ?? node.props["pairs"]?.asArray ?? []).compactMap { $0.asObject }
        VStack(spacing: 0) {
            ForEach(jcIndexed(pairs), id: \.0) { i, pair in
                HStack(alignment: .firstTextBaseline) {
                    Text(JCValueRef(pair["label"] ?? .null).string(ctx) ?? "")
                        .font(.system(size: 15)).foregroundStyle(JcTheme.text).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(JCValueRef(pair["value"] ?? .null).string(ctx) ?? "—")
                        .font(.system(size: 15)).foregroundStyle(JcTheme.muted)
                        .lineLimit(1).multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 10)
                if i < pairs.count - 1 { Rectangle().fill(JcTheme.border).frame(height: 1) }
            }
        }
    }
}

/// A ring (or nested rings) sized for a page, its label in the middle.
private struct IntegrationUIGauge: View {
    let node: JCNode
    let ctx: JCBindingContext

    private var rings: [(value: Double, tint: Color)] {
        let scale = jcScale(node)
        if let list = node.ref("rings")?.array(ctx) ?? node.props["rings"]?.asArray, !list.isEmpty {
            return list.compactMap { $0.asObject }.map { o in
                (jcClamp01((JCValueRef(o["value"] ?? .null).double(ctx) ?? 0) / scale),
                 JCValueRef(o["tint"] ?? .null).color(ctx) ?? JcTheme.accent)
            }
        }
        return [(jcClamp01((node.ref("value")?.double(ctx) ?? 0) / scale),
                 node.ref("tint")?.color(ctx) ?? JcTheme.accent)]
    }

    var body: some View {
        let size = CGFloat(node.double("size") ?? 72)
        let line = max(5, size / 11)
        VStack(spacing: 6) {
            ZStack {
                ForEach(Array(rings.enumerated()), id: \.offset) { i, ring in
                    let d = size - CGFloat(i) * (line * 2 + 4)
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: line).frame(width: d, height: d)
                    Circle().trim(from: 0, to: CGFloat(ring.value))
                        .stroke(ring.tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: d, height: d)
                }
                if let label = node.ref("label")?.string(ctx) {
                    Text(label).font(.system(size: size * 0.2, weight: .bold).monospacedDigit())
                        .foregroundStyle(JcTheme.text).minimumScaleFactor(0.5).lineLimit(1)
                        .padding(.horizontal, line * 2)
                }
            }
            .frame(width: size + line, height: size + line)
            if let caption = node.ref("caption")?.string(ctx), !caption.isEmpty {
                Text(caption).font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(1)
            }
        }
    }
}

/// A list of rows, with the app's hairlines between them.
private struct IntegrationUIRowList: View {
    let node: JCNode
    let ctx: JCBindingContext
    let render: (JCNode?, JCBindingContext) -> AnyView

    var body: some View {
        let rows = (node.ref("data")?.array(ctx) ?? []).compactMap { $0.asObject }
        let count = max(0, min(node.int("max") ?? rows.count, rows.count))
        if rows.isEmpty {
            render(node.node("empty"), ctx)
        } else {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    render(node.node("row"), ctx.withRow(rows[i]))
                    if i < count - 1 { Rectangle().fill(JcTheme.border).frame(height: 1) }
                }
            }
        }
    }
}

private struct IntegrationUIText: View {
    let node: JCNode
    let ctx: JCBindingContext

    var body: some View {
        let raw = node.ref("value")?.string(ctx) ?? ""
        let size = CGFloat(node.style?.size ?? 15)
        let color = node.style?.color.flatMap(jcParseColor) ?? JcTheme.text
        Group {
            if node.bool("markdown") == true,
               let attributed = try? AttributedString(
                markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(raw)
            }
        }
        .font(.system(size: size, weight: node.style?.weight.map(jcWeight) ?? .regular))
        .foregroundStyle(color.opacity(node.style?.opacity ?? 1))
        .lineLimit(node.int("lineLimit").flatMap { $0 > 0 ? $0 : nil })
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(node.string("align") == "center" ? .center : .leading)
    }
}

// MARK: - Controls

/// A control whose `value` reads state: once its script succeeds, the state shows it.
private func bindsValue(_ n: JCNode) -> Bool {
    guard let o = n.props["value"]?.asObject else { return false }
    return o["$"] != nil || o["$row"] != nil
}

@MainActor
private func isBusy(_ store: IntegrationUIStore, _ action: IntegrationUIAction) -> Bool {
    store.running == action.busyKey
}

/// A list row: icon or checkbox, title + subtitle, trailing text; tap runs `action`,
/// long-press offers the `swipe` actions.
private struct IntegrationUIRow: View {
    let node: JCNode
    let ctx: JCBindingContext
    let store: IntegrationUIStore

    private var checked: Bool? {
        guard node.props["check"] != nil else { return nil }
        return node.ref("check")?.resolve(ctx)?.asBool ?? false
    }

    private var action: IntegrationUIAction? {
        guard let name = node.string("action") else { return nil }
        return IntegrationUIAction(name: name, control: node.string("id"),
                                   value: checked.map { .bool(!$0) }, row: ctx.row)
    }

    private var swipes: [(label: String, action: String, role: String?)] {
        (node.props["swipe"]?.asArray ?? []).compactMap { entry in
            guard let o = entry.asObject, let label = o["label"]?.asString,
                  let action = o["action"]?.asString else { return nil }
            return (label, action, o["role"]?.asString)
        }
    }

    var body: some View {
        Group {
            if let action {
                Button { store.request(action) } label: { content }
                    .buttonStyle(.plain)
                    .disabled(store.running != nil)
            } else {
                content
            }
        }
        .contextMenu {
            ForEach(Array(swipes.enumerated()), id: \.offset) { _, swipe in
                Button(role: swipe.role == "destructive" ? .destructive : nil) {
                    store.request(IntegrationUIAction(name: swipe.action, control: nil, row: ctx.row))
                } label: { Text(swipe.label) }
                .disabled(store.running != nil)
            }
        }
    }

    private var content: some View {
        let title = node.ref("title")?.string(ctx) ?? ""
        let subtitle = node.ref("subtitle")?.string(ctx)
        let trailing = node.ref("trailing")?.string(ctx)
        let busy = action.map { isBusy(store, $0) } ?? false
        return HStack(spacing: 12) {
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(checked ? JcTheme.accent : JcTheme.muted)
            } else if let symbol = node.ref("symbol")?.string(ctx), !symbol.isEmpty {
                JcIconSquare(symbol: symbol)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(checked == true ? JcTheme.muted : JcTheme.text)
                    .strikethrough(checked == true, color: JcTheme.muted)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if busy {
                JcLoader(size: 16)
            } else if let trailing, !trailing.isEmpty {
                Text(trailing).font(.system(size: 14)).foregroundStyle(JcTheme.muted).lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct IntegrationUIButton: View {
    let node: JCNode
    let ctx: JCBindingContext
    let store: IntegrationUIStore
    let formFields: Set<String>

    var body: some View {
        let label = node.ref("label")?.string(ctx) ?? ""
        let symbol = node.ref("symbol")?.string(ctx)
        let role = node.string("role") ?? "primary"
        let tint: Color = role == "destructive" ? JcTheme.danger : role == "secondary" ? JcTheme.text : JcTheme.accent
        let full = node.bool("full") ?? false
        let action = IntegrationUIAction(name: node.string("action") ?? "", control: node.string("id"),
                                         row: ctx.row, submitsForm: true, formFields: formFields)
        Button { store.request(action) } label: {
            HStack(spacing: 6) {
                if isBusy(store, action) {
                    JcLoader(size: 12).foregroundStyle(tint)
                } else if let symbol, !symbol.isEmpty {
                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                }
                if !label.isEmpty { Text(label).lineLimit(1) }
            }
        }
        .buttonStyle(.jcGlass(tint: tint, compact: !full, full: full))
        .disabled(store.running != nil)
    }
}

private struct IntegrationUIToggle: View {
    let node: JCNode
    let ctx: JCBindingContext
    let store: IntegrationUIStore

    var body: some View {
        // Shows the state's value: the script decides, the switch follows it.
        let on = node.ref("value")?.resolve(ctx)?.asBool ?? false
        let action = IntegrationUIAction(name: node.string("action") ?? "", control: node.string("id"),
                                         value: .bool(!on), row: ctx.row)
        HStack {
            Text(node.ref("label")?.string(ctx) ?? "")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(JcTheme.text)
            Spacer(minLength: 8)
            if isBusy(store, action) { JcLoader(size: 16) }
            Toggle("", isOn: Binding(get: { on }, set: { _ in store.request(action) }))
                .labelsHidden()
                .tint(JcTheme.accent)
                .disabled(store.running != nil)
        }
    }
}

private struct IntegrationUITextField: View {
    let node: JCNode
    let ctx: JCBindingContext
    let store: IntegrationUIStore
    let formFields: Set<String>

    var body: some View {
        let id = node.string("id") ?? "field"
        let key = IntegrationUIStore.inputKey(id, row: ctx.row)
        let text = Binding<String>(
            get: { store.value(of: key, bound: node.ref("value")?.resolve(ctx))?.asString ?? "" },
            set: { store.setInput(key, .string($0)) })
        let plain = node.string("keyboard") == "email" || node.string("keyboard") == "url"
        TextField(node.ref("placeholder")?.string(ctx) ?? "", text: text)
            .font(.system(size: 15))
            .foregroundStyle(JcTheme.text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(plain ? .never : .sentences)
            .submitLabel(node.string("submit") == nil ? .done : .go)
            .onSubmit {
                guard let submit = node.string("submit") else { return }
                store.request(IntegrationUIAction(name: submit, control: id, value: .string(text.wrappedValue),
                                                  row: ctx.row, submitsForm: true, formFields: formFields))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous))
            .overlay(alignment: .trailing) {
                if store.running == key { JcLoader(size: 16).padding(.trailing, 10) }
            }
    }

    private var keyboard: UIKeyboardType {
        switch node.string("keyboard") {
        // Has a return key, so `submit` can fire and the keyboard can close.
        case "number": return .numbersAndPunctuation
        case "email": return .emailAddress
        case "url": return .URL
        default: return .default
        }
    }
}

/// `options`: `[{label, value}]` or plain strings, literal or bound.
private struct IntegrationUIPicker: View {
    let node: JCNode
    let ctx: JCBindingContext
    let store: IntegrationUIStore

    private struct Option { let key: String; let label: String; let raw: JCJSON }

    private var options: [Option] {
        let raw = node.ref("options")?.array(ctx) ?? node.props["options"]?.asArray ?? []
        return raw.compactMap { item in
            if let o = item.asObject, let value = o["value"] ?? o["label"] {
                let key = value.asString ?? ""
                return Option(key: key, label: o["label"]?.asString ?? key, raw: value)
            }
            guard let key = item.asString else { return nil }
            return Option(key: key, label: key, raw: item)
        }
    }

    var body: some View {
        let id = node.string("id") ?? "picker"
        let inputKey = IntegrationUIStore.inputKey(id, row: ctx.row)
        let opts = options
        let current = store.value(of: inputKey, bound: node.ref("value")?.resolve(ctx))?.asString ?? opts.first?.key ?? ""
        let selection = Binding<String>(get: { current }, set: { key in
            // Re-tapping the chosen segment is not a new choice.
            guard key != current, let picked = opts.first(where: { $0.key == key }) else { return }
            store.setInput(inputKey, picked.raw)
            if let action = node.string("action") {
                store.request(IntegrationUIAction(name: action, control: id, value: picked.raw, row: ctx.row,
                                                  revertsInput: true, clearsInputOnSuccess: bindsValue(node)))
            }
        })
        if node.string("variant") == "menu" {
            Menu {
                Picker("", selection: selection) {
                    ForEach(opts, id: \.key) { Text($0.label).tag($0.key) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(opts.first { $0.key == current }?.label ?? current)
                        .font(.system(size: 15, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(JcTheme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.compactRadius, style: .continuous))
            }
            .disabled(store.running != nil)
        } else {
            JcSegmentedPicker(opts.map { (value: $0.key, label: $0.label) }, selection: selection)
                .disabled(store.running != nil)
        }
    }
}

private struct IntegrationUISlider: View {
    let node: JCNode
    let ctx: JCBindingContext
    let store: IntegrationUIStore
    @State private var dragging: Double?

    var body: some View {
        let id = node.string("id") ?? "slider"
        let key = IntegrationUIStore.inputKey(id, row: ctx.row)
        let lo = node.double("min") ?? 0
        let hi = max(lo + 0.000_1, node.double("max") ?? 100)
        let step = node.double("step")
        let stored = store.value(of: key, bound: node.ref("value")?.resolve(ctx))?.asDouble ?? lo
        let shown = dragging ?? stored
        let binding = Binding<Double>(get: { shown }, set: { dragging = $0 })
        let editing: (Bool) -> Void = { active in
            guard !active, let final = dragging else { return }
            dragging = nil
            store.setInput(key, .number(final))
            if let action = node.string("action") {
                store.request(IntegrationUIAction(name: action, control: id, value: .number(final), row: ctx.row,
                                                  revertsInput: true, clearsInputOnSuccess: bindsValue(node)))
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            if let label = node.ref("label")?.string(ctx), !label.isEmpty {
                Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
            }
            sliderRow(binding: binding, lo: lo, hi: hi, step: step, shown: shown, editing: editing)
        }
        .disabled(store.running != nil)
    }

    private func sliderRow(binding: Binding<Double>, lo: Double, hi: Double, step: Double?, shown: Double,
                           editing: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 10) {
            Group {
                if let step, step > 0 {
                    Slider(value: binding, in: lo...hi, step: step, onEditingChanged: editing)
                } else {
                    Slider(value: binding, in: lo...hi, onEditingChanged: editing)
                }
            }
            .tint(JcTheme.accent)
            Text(JCJSON.numberString(shown))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(JcTheme.muted)
                .frame(minWidth: 36, alignment: .trailing)
        }
    }
}

private struct IntegrationUIStepper: View {
    let node: JCNode
    let ctx: JCBindingContext
    let store: IntegrationUIStore

    var body: some View {
        let id = node.string("id") ?? "stepper"
        let key = IntegrationUIStore.inputKey(id, row: ctx.row)
        let lo = node.double("min") ?? 0
        let hi = max(lo, node.double("max") ?? 1_000_000)
        let step = max(0.000_1, node.double("step") ?? 1)
        let value = store.value(of: key, bound: node.ref("value")?.resolve(ctx))?.asDouble ?? lo
        let binding = Binding<Double>(get: { value }, set: { new in
            store.setInput(key, .number(new))
            if let action = node.string("action") {
                store.request(IntegrationUIAction(name: action, control: id, value: .number(new), row: ctx.row,
                                                  revertsInput: true, clearsInputOnSuccess: bindsValue(node)))
            }
        })
        Stepper(value: binding, in: lo...hi, step: step) {
            HStack {
                Text(node.ref("label")?.string(ctx) ?? "")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                Spacer(minLength: 8)
                Text(JCJSON.numberString(value))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(JcTheme.text)
            }
        }
        .disabled(store.running != nil)
    }
}

private struct IntegrationUIDate: View {
    let node: JCNode
    let ctx: JCBindingContext
    let store: IntegrationUIStore

    var body: some View {
        let id = node.string("id") ?? "date"
        let key = IntegrationUIStore.inputKey(id, row: ctx.row)
        let mode = node.string("mode") ?? "date"
        let current = store.value(of: key, bound: node.ref("value")?.resolve(ctx))?.asString
            .flatMap(IntegrationUIDates.parse) ?? Date()
        let binding = Binding<Date>(get: { current }, set: { new in
            let text = IntegrationUIDates.format(new, mode: mode)
            store.setInput(key, .string(text))
            if let action = node.string("action") {
                store.request(IntegrationUIAction(name: action, control: id, value: .string(text), row: ctx.row,
                                                  revertsInput: true, clearsInputOnSuccess: bindsValue(node)))
            }
        })
        let components: DatePickerComponents = mode == "time" ? [.hourAndMinute]
            : mode == "dateTime" ? [.date, .hourAndMinute] : [.date]
        DatePicker(node.ref("label")?.string(ctx) ?? "", selection: binding, displayedComponents: components)
            .font(.system(size: 15, weight: .medium))
            .tint(JcTheme.accent)
            .disabled(store.running != nil)
    }
}

/// ISO 8601 both ways: full timestamps, dates (`2026-11-03`) and times (`07:45`).
enum IntegrationUIDates {
    static func parse(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let d = full.date(from: text) { return d }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: text) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "HH:mm"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: text) {
                guard format == "HH:mm" else { return d }
                // A bare time is today at that time.
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                return Calendar.current.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: Date())
            }
        }
        return nil
    }

    static func format(_ date: Date, mode: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        switch mode {
        case "time": f.dateFormat = "HH:mm"
        case "dateTime": f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        default: f.dateFormat = "yyyy-MM-dd"
        }
        return f.string(from: date)
    }
}
