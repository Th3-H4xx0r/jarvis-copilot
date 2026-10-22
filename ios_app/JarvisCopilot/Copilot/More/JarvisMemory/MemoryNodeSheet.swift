import SwiftUI

/// Tap a node: who/what it is, Pin, Expand, the fix tools (rename, aliases,
/// merge into…), and its memories — swipe one to remove a wrong link.
struct MemoryNodeSheet: View {
    let graph: MemoryGraphStore
    let id: String

    @State private var model: MemoryEntitySheetModel
    @State private var renaming = false
    @State private var renameText = ""
    @Environment(\.dismiss) private var dismiss

    init(graph: MemoryGraphStore, id: String, api: JarvisMemoryAPI = JarvisMemoryAPI()) {
        self.graph = graph
        self.id = id
        _model = State(initialValue: MainActor.assumeIsolated { MemoryEntitySheetModel(id: id, api: api) })
    }

    /// What the canvas knows, until the detail loads.
    private var node: MemoryGraphNode? { graph.graph.node(id) }
    private var name: String { model.detail?.entity.label.nonEmptyOr(node?.label ?? "") ?? node?.label ?? "" }
    private var kind: MemoryEntityKind {
        if let type = model.detail?.entity.type, !type.isEmpty { return MemoryEntityKind(wire: type) }
        return node?.kind ?? .topic
    }
    private var pinned: Bool { model.detail?.entity.pinned ?? node?.pinned ?? false }
    private var aliases: [String] { model.detail?.entity.aliases ?? [] }

    var body: some View {
        NavigationStack {
            List {
                header
                fixSection
                memoriesSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(JcTheme.surface)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await rename() } }
            } message: {
                Text("A name another \(kind.label.lowercased()) already has merges the two.")
            }
            .moreToast($model.toast)
            // Pin / rename / aliases / merge errors, shown here rather than in
            // the map's toast hidden under the sheet.
            .moreToast(Binding(get: { graph.sheetToast }, set: { graph.sheetToast = $0 }))
        }
        .tint(JcTheme.accent)
        .task { await model.load() }
    }

    // MARK: Header

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    JcIcon(kind.symbol, size: 18)
                        .foregroundStyle(MemoryGraphPalette.color(kind))
                        .frame(width: 40, height: 40)
                        .background(MemoryGraphPalette.color(kind).opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(JcTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                if !aliases.isEmpty {
                    Text("Also: " + aliases.joined(separator: ", "))
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = model.detail?.entity.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(JcTheme.text.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    let expanded = graph.graph.expanded.contains(id)
                    Button {
                        Task {
                            await graph.expand(id)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if graph.expanding == id { ProgressView().controlSize(.mini) }
                            else { JcIcon("arrow.up.left.and.arrow.down.right", size: 13) }
                            Text(expanded ? "Expanded" : "Expand")
                        }
                    }
                    .buttonStyle(.jcGlass(compact: true))
                    .disabled(expanded || graph.expanding != nil)

                    Toggle(isOn: Binding(get: { pinned }, set: { value in
                        Task {
                            if let saved = await graph.setPinned(id, value) { model.apply(saved) }
                        }
                    })) {
                        Label("Pin", jcIcon: "pin")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(JcTheme.text)
                    }
                    .toggleStyle(.switch)
                    .tint(JcTheme.accent)
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(JcTheme.surfaceAlt)
        }
    }

    /// The node's own weight: every memory it links, not just the ones listed.
    private var subtitle: String {
        var parts = [kind.label]
        if let weight = node?.weight, weight > 0 {
            parts.append(weight == 1 ? "1 memory" : "\(weight) memories")
        } else if let count = model.detail?.memories.count, count > 0 {
            parts.append(count == 1 ? "1 memory" : "\(count) memories")
        }
        if let start = model.detail?.entity.eventStart ?? node?.eventStart {
            parts.append(RelativeTime.absolute(start))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Fix

    private var fixSection: some View {
        Section {
            Button {
                renameText = name
                renaming = true
            } label: {
                Label("Rename", jcIcon: "pencil")
            }
            // Only once the saved aliases are known: editing from an empty list
            // would save over them.
            NavigationLink {
                MemoryAliasesEditor(aliases: aliases) { list in
                    guard let saved = await graph.setAliases(id, list) else { return false }
                    model.apply(saved)
                    return true
                }
            } label: {
                Label(aliases.isEmpty ? "Add aliases" : "Aliases (\(aliases.count))", jcIcon: "text.badge.plus")
            }
            .disabled(model.detail == nil)
            NavigationLink {
                MemoryMergePicker(graph: graph, id: id, name: name, kind: kind,
                                  neighbors: model.detail?.neighbors ?? []) {
                    dismiss()
                }
            } label: {
                Label("Merge into…", jcIcon: "arrow.triangle.merge")
            }
        } header: {
            Text("Fix")
        }
        .foregroundStyle(JcTheme.text)
        .listRowBackground(JcTheme.surfaceAlt)
    }

    // MARK: Memories

    @ViewBuilder private var memoriesSection: some View {
        Section {
            if let detail = model.detail {
                if detail.memories.isEmpty {
                    Text("No memories link here now.")
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                }
                ForEach(detail.memories) { memory in
                    MemoryLinkRow(memory: memory)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task {
                                    if await model.unlink(memory.id) { graph.memoryUnlinked(from: id) }
                                }
                            } label: {
                                Label("Remove link", jcIcon: "scissors")
                            }
                        }
                }
            } else if let error = model.error {
                Text(error).font(.system(size: 13)).foregroundStyle(JcTheme.danger)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            HStack {
                Text("Memories")
                Spacer()
                // The sheet lists the newest; the node may link many more.
                if let shown = model.detail?.memories.count, let weight = node?.weight, shown < weight {
                    Text("showing \(shown)").textCase(nil)
                }
            }
        } footer: {
            if model.detail?.memories.isEmpty == false {
                Text("Swipe a memory to remove a wrong link. The memory itself stays.")
            }
        }
        .listRowBackground(JcTheme.surfaceAlt)
    }

    private func rename() async {
        let before = id
        guard let saved = await graph.rename(before, to: renameText) else { return }
        if saved.id != before {
            // Merged into an entity that already had the name: this node is gone.
            graph.toast = "Merged into \(saved.label)"
            dismiss()
        } else {
            model.apply(saved)
        }
    }
}

/// One memory linked to the node: its text, when, where it came from, and a
/// "past" tag when something newer replaced it.
struct MemoryLinkRow: View {
    let memory: MemoryEntityMemory

    private var when: String {
        if let event = memory.eventStart { return RelativeTime.isoDate(event) }
        return memory.createdAt.map { RelativeTime.format($0) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(memory.body)
                .font(.system(size: 14))
                .foregroundStyle(memory.past ? JcTheme.muted : JcTheme.text)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                let meta = [when, memory.sourceLabel].filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.system(size: 11.5)).foregroundStyle(JcTheme.muted)
                }
                if memory.past { StatusPill("past", color: JcTheme.amber, dense: true) }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Edit a node's other names.
struct MemoryAliasesEditor: View {
    /// True when saved; on false the editor stays open (the error shows in the sheet).
    let onSave: ([String]) async -> Bool
    @State private var aliases: [String]
    @State private var draft = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(aliases: [String], onSave: @escaping ([String]) async -> Bool) {
        self.onSave = onSave
        _aliases = State(initialValue: aliases)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add an alias", text: $draft)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Other names Jarvis should read as this one.")
            }
            .listRowBackground(JcTheme.surfaceAlt)
            if !aliases.isEmpty {
                Section {
                    ForEach(aliases, id: \.self) { Text($0).foregroundStyle(JcTheme.text) }
                        .onDelete { aliases.remove(atOffsets: $0) }
                }
                .listRowBackground(JcTheme.surfaceAlt)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(JcTheme.surface)
        .navigationTitle("Aliases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        saving = true
                        add()
                        let saved = await onSave(aliases)
                        saving = false
                        if saved { dismiss() }
                    }
                } label: {
                    if saving { ProgressView() } else { Text("Save").bold() }
                }
                .disabled(saving)
            }
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !aliases.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { aliases.append(value) }
        draft = ""
    }
}

/// "Merge into…": a searchable list of same-type nodes (on the map, plus this
/// one's neighbours). Confirmed, because the merged node is deleted.
struct MemoryMergePicker: View {
    let graph: MemoryGraphStore
    let id: String
    let name: String
    let kind: MemoryEntityKind
    let neighbors: [MemoryEntityNeighbor]
    let onMerged: () -> Void

    @State private var search = ""
    @State private var pending: MemoryMergeTargets.Target?
    @State private var merging = false

    private var targets: [MemoryMergeTargets.Target] {
        MemoryMergeTargets.list(for: id, kind: kind, graph: graph.graph, neighbors: neighbors, search: search)
    }

    var body: some View {
        List {
            if targets.isEmpty {
                Text(search.isEmpty
                     ? "No other \(kind.chipLabel.lowercased()) on the map. Expand nearby nodes to find more."
                     : "No match.")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .listRowBackground(JcTheme.surfaceAlt)
            }
            ForEach(targets) { target in
                Button { pending = target } label: {
                    HStack {
                        Circle().fill(MemoryGraphPalette.color(kind)).frame(width: 8, height: 8)
                        Text(target.label).foregroundStyle(JcTheme.text)
                        Spacer()
                        if target.weight > 0 {
                            Text("\(target.weight)").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                        }
                    }
                }
                .listRowBackground(JcTheme.surfaceAlt)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(JcTheme.surface)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search \(kind.chipLabel.lowercased())")
        .navigationTitle("Merge \(name) into…")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(merging)
        .overlay { if merging { ProgressView() } }
        .confirmationDialog("Merge into \(pending?.label ?? "")?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { target in
            Button("Merge") {
                Task {
                    merging = true
                    let ok = await graph.merge(id, into: target.id)
                    merging = false
                    if ok {
                        graph.toast = "Merged into \(target.label)"
                        onMerged()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Its memories move to \(target.label) and “\(name)” becomes an alias.")
        }
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}
