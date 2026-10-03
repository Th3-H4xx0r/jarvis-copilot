import SwiftUI

/// More → Harnesses: the built-ins and your own harnesses, the Voice and Chat
/// defaults, and the way into the canvas editor. Built-ins open read-only and
/// are duplicated to edit.
struct HarnessesPage: View {
    @State private var editing: AgentHarness?
    private var store: HarnessStore { HarnessStore.shared }

    var body: some View {
        List {
            Section {
                Picker("Voice", selection: defaultBinding(.voice)) {
                    ForEach(store.harnesses) { Text($0.title).tag($0.id) }
                }
                Picker("Chat", selection: defaultBinding(.chat)) {
                    ForEach(store.harnesses) { Text($0.title).tag($0.id) }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("A chat can still switch to another harness from its header.")
            }

            Section("Harnesses") {
                ForEach(store.harnesses) { harness in
                    Button { editing = harness } label: { row(harness) }
                        .swipeActions {
                            if !harness.isBuiltin {
                                Button("Delete", role: .destructive) {
                                    Task { await store.delete(harness.id) }
                                }
                            }
                            Button("Duplicate") { editing = copy(of: harness) }
                                .tint(JcTheme.accent)
                        }
                }
            }

            if let message = store.errorMessage {
                Section { Text(message).font(JcText.small).foregroundStyle(JcTheme.muted) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .jcScreen()
        .navigationTitle("Harnesses")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = HarnessGraph.newHarness(id: uniqueID("harness"), name: "New harness")
                } label: { JcIcon("plus").foregroundStyle(JcTheme.accent) }
                .accessibilityLabel("New harness")
            }
        }
        .navigationDestination(item: $editing) { HarnessEditorView(harness: $0) }
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }

    private func row(_ harness: AgentHarness) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(harness.title).foregroundStyle(JcTheme.text)
                let uses = [store.assignments["voice"] == harness.id ? "Voice" : nil,
                            store.assignments["chat"] == harness.id ? "Chat" : nil].compactMap { $0 }
                if harness.isBuiltin || !uses.isEmpty {
                    Text(((harness.isBuiltin ? ["Built-in"] : []) + uses.map { "\($0) default" })
                        .joined(separator: " · "))
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                }
            }
            if !(harness.problems ?? []).isEmpty {
                JcIcon("exclamationmark.triangle").foregroundStyle(JcTheme.amber)
            }
            Spacer()
            HarnessMiniDiagram(harness: harness)
        }
    }

    private func defaultBinding(_ surface: VoiceSurface) -> Binding<String> {
        Binding(
            get: { store.assignments[surface.rawValue] ?? HarnessStore.defaultAssignments[surface.rawValue] ?? "single" },
            set: { id in Task { await store.assign(id, to: surface) } })
    }

    private func copy(of harness: AgentHarness) -> AgentHarness {
        HarnessGraph.duplicate(harness, id: uniqueID("\(harness.id)-copy"), name: "\(harness.name) copy")
    }

    private func uniqueID(_ base: String) -> String {
        var id = base
        var n = 2
        while store.harness(id) != nil { id = "\(base)-\(n)"; n += 1 }
        return id
    }
}
