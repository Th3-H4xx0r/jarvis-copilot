import SwiftUI

/// One widget design: a live preview at each size, the size's rows of blocks, and its name,
/// icon and colour.
struct WidgetEditor: View {
    struct BlockRef: Identifiable, Hashable {
        let row: Int
        let block: Int
        var id: String { "\(row)-\(block)" }
    }

    @ObservedObject private var store = WidgetDesignStore.shared
    @State private var draft: WidgetDesignDraft
    @State private var size: WidgetSize = .small
    @State private var editing: BlockRef?
    @State private var data: [String: JCJSON] = [:]
    @State private var message: String?
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var saved: WidgetDesignDraft?
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    init(draft: WidgetDesignDraft, isNew: Bool) {
        _draft = State(initialValue: draft)
        _saved = State(initialValue: isNew ? nil : draft)
        self.isNew = isNew
    }

    private var design: JCDesign? { try? JSONDecoder().decode(JCDesign.self, from: draft.compile()) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                WidgetPreview(design: design, size: size, data: data)
                    .frame(maxWidth: .infinity)
                sizes
                if draft.layout(size) == nil {
                    CardGroup(footer: borrowed.map { "Uses the \($0.label.lowercased()) layout until you design this size." }
                              ?? "Nothing shows at this size until you design it.") {
                        Row {
                            Button("Design this size") {
                                draft.layouts[size.rawValue] = borrowed.flatMap(draft.layout) ?? WidgetLayout()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    rows
                }
                details
                if !isNew {
                    CardGroup {
                        Row {
                            Button("Delete widget", role: .destructive) { confirmDelete = true }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle(draft.name.isEmpty ? "Widget" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { data = WidgetDataFile.read() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save", action: save)
                    .disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft == saved)
            }
        }
        .sheet(item: $editing) { ref in
            NavigationStack {
                WidgetBlockInspector(block: blockBinding(ref), onDelete: { removeBlock(ref) })
            }
        }
        .confirmationDialog("Delete this widget?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.delete(draft.id)
                    dismiss()
                }
            }
        } message: {
            Text("Widgets showing it go back to asking for a design.")
        }
    }

    /// The nearest smaller size with a layout, which this one borrows.
    private var borrowed: WidgetSize? {
        var current = size.fallback
        while let s = current {
            if draft.layout(s) != nil { return s }
            current = s.fallback
        }
        return nil
    }

    // MARK: Sections

    private var sizes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WidgetSize.allCases) { s in
                    Button { size = s } label: {
                        HStack(spacing: 5) {
                            if draft.layout(s) != nil { Circle().fill(JcAccent.color).frame(width: 6, height: 6) }
                            Text(s.label)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .foregroundStyle(size == s ? Color.black : Color.primary)
                        .background(size == s ? JcAccent.color : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var rows: some View {
        let layout = draft.layout(size) ?? WidgetLayout()
        ForEach(Array(layout.rows.enumerated()), id: \.element.id) { rowIndex, row in
            CardGroup("Row \(rowIndex + 1)") {
                ForEach(Array(row.blocks.enumerated()), id: \.element.id) { blockIndex, block in
                    if blockIndex > 0 { RowDivider() }
                    Button { editing = BlockRef(row: rowIndex, block: blockIndex) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: block.kind == .symbol ? (block.symbol ?? block.kind.symbol) : block.kind.symbol)
                                .foregroundStyle(JcAccent.color)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(block.kind.label).font(.subheadline)
                                Text(summary(block)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !row.blocks.isEmpty { RowDivider() }
                Row {
                    HStack {
                        Menu {
                            ForEach(WidgetBlock.Kind.allCases) { kind in
                                Button { addBlock(kind, row: rowIndex) } label: { Label(kind.label, systemImage: kind.symbol) }
                            }
                        } label: {
                            Label("Add a block", systemImage: "plus").font(.subheadline)
                        }
                        Spacer()
                        Menu {
                            Button { moveRow(rowIndex, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                                .disabled(rowIndex == 0)
                            Button { moveRow(rowIndex, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                                .disabled(rowIndex == layout.rows.count - 1)
                            Button(role: .destructive) { removeRow(rowIndex) } label: { Label("Delete row", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        CardGroup {
            Row {
                Button { updateLayout { $0.rows.append(WidgetRow(blocks: [])) } } label: {
                    Label("Add a row", systemImage: "plus.rectangle.on.rectangle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if size != .small {
                RowDivider()
                Row {
                    Button("Use the smaller size's layout", role: .destructive) { draft.layouts[size.rawValue] = nil }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var details: some View {
        CardGroup("Widget") {
            Row { TextField("Name", text: $draft.name) }
            RowDivider()
            NavigationLink {
                SymbolPicker(title: "Icon", selection: draft.icon) { draft.icon = $0 }
            } label: {
                Row {
                    HStack {
                        Text("Icon")
                        Spacer()
                        Image(systemName: draft.icon).foregroundStyle(JcAccent.color)
                        JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider()
            Row {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Colour")
                    WidgetColorSwatches(selection: $draft.tint)
                }
            }
        }
    }

    // MARK: Editing

    private func summary(_ block: WidgetBlock) -> String {
        if let source = block.source {
            return WidgetDataCatalog.entry(source)?.label ?? source
        }
        if let id = block.button {
            return ControlButtonShelf.infos().first { $0.id == id }?.name ?? "Choose a button"
        }
        if let device = block.device { return WidgetDataCatalog.wearables.first { $0.key == device }?.name ?? device }
        return block.label ?? block.symbol ?? ""
    }

    private func updateLayout(_ change: (inout WidgetLayout) -> Void) {
        var layout = draft.layout(size) ?? WidgetLayout()
        change(&layout)
        draft.layouts[size.rawValue] = layout
    }

    private func addBlock(_ kind: WidgetBlock.Kind, row: Int) {
        var block = WidgetBlock(kind: kind)
        switch kind {
        case .stat, .gauge, .progress: block.source = "health.steps"
        case .text: block.label = "Text"
        case .chart, .sparkline: block.source = "health.steps_week"; block.chartStyle = "bar"
        case .symbol: block.symbol = "star.fill"
        case .model: block.device = "x5ring"
        case .button, .toggle: block.button = ControlButtonShelf.infos().first { ($0.keepsState == true) == (kind == .toggle) }?.id
        default: break
        }
        updateLayout { $0.rows[row].blocks.append(block) }
        editing = BlockRef(row: row, block: (draft.layout(size)?.rows[row].blocks.count ?? 1) - 1)
    }

    private func moveRow(_ index: Int, by offset: Int) {
        updateLayout { layout in
            let target = index + offset
            guard layout.rows.indices.contains(target) else { return }
            layout.rows.swapAt(index, target)
        }
    }

    private func removeRow(_ index: Int) {
        updateLayout { $0.rows.remove(at: index) }
    }

    private func removeBlock(_ ref: BlockRef) {
        editing = nil
        updateLayout { layout in
            guard layout.rows.indices.contains(ref.row), layout.rows[ref.row].blocks.indices.contains(ref.block) else { return }
            layout.rows[ref.row].blocks.remove(at: ref.block)
        }
    }

    private func blockBinding(_ ref: BlockRef) -> Binding<WidgetBlock> {
        Binding(
            get: {
                guard let layout = draft.layout(size), layout.rows.indices.contains(ref.row),
                      layout.rows[ref.row].blocks.indices.contains(ref.block) else { return WidgetBlock(kind: .spacer) }
                return layout.rows[ref.row].blocks[ref.block]
            },
            set: { block in
                updateLayout { layout in
                    guard layout.rows.indices.contains(ref.row), layout.rows[ref.row].blocks.indices.contains(ref.block)
                    else { return }
                    layout.rows[ref.row].blocks[ref.block] = block
                }
            })
    }

    private func save() {
        saving = true
        message = nil
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let toSave = draft
        Task {
            switch await store.save(toSave) {
            case .saved(let warnings):
                saved = toSave
                message = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
                if warnings.isEmpty { dismiss() }
            case .local(let why):
                saved = toSave
                message = "Saved on this phone; it reaches Jarvis when the server is back (\(why))."
            case .rejected(let why):
                message = why
            }
            saving = false
        }
    }
}

/// The colour choices, shared by the editor and the inspector.
struct WidgetColorSwatches: View {
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ControlButtonStore.tints, id: \.self) { hex in
                    let color = hex.flatMap(jcParseColor)
                    Button { selection = hex } label: {
                        Circle()
                            .fill(color ?? Color.white.opacity(0.15))
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: selection == hex ? 2 : 0))
                            .overlay { if hex == nil { Image(systemName: "circle.slash").font(.caption2) } }
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex ?? "Default colour")
                }
            }
        }
    }
}
