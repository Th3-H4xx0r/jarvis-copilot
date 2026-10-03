import SwiftUI

/// The header chip that names the agent harness a surface runs, and the sheet
/// to switch it. It replaced the model chip: a plain model is the "Single
/// model" harness, so the chip can never name a model that isn't answering.

/// A one-line sketch of a harness: one box per step after the start.
struct HarnessMiniDiagram: View {
    let harness: AgentHarness

    var body: some View {
        let steps = harness.nodes.filter { $0.type != .message }.count
        HStack(spacing: 2) {
            ForEach(0..<max(steps, 1), id: \.self) { i in
                if i > 0 { Rectangle().fill(JcTheme.accent.opacity(0.7)).frame(width: 7, height: 1) }
                RoundedRectangle(cornerRadius: 3)
                    .stroke(JcTheme.accent, lineWidth: 1)
                    .frame(width: 13, height: 9)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The list of harnesses for one surface, the current one ticked.
struct HarnessSheet: View {
    let surface: VoiceSurface
    let current: String
    let onSelect: (String) -> Void
    let onSingleModel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    private var store: HarnessStore { HarnessStore.shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.harnesses.filter { $0.id != "single" }) { harness in
                        Button {
                            onSelect(harness.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text(harness.title).foregroundStyle(JcTheme.text)
                                if !(harness.problems ?? []).isEmpty {
                                    JcIcon("exclamationmark.triangle").foregroundStyle(JcTheme.amber)
                                }
                                Spacer()
                                HarnessMiniDiagram(harness: harness)
                                if harness.id == current {
                                    JcIcon("checkmark").foregroundStyle(JcTheme.accent)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(surface == .chat ? "This chat runs the harness you pick."
                                          : "Voice runs the harness you pick.")
                }
                Section {
                    Button { editing = true } label: {
                        Text("Edit harnesses…").foregroundStyle(JcTheme.accent)
                    }
                }
                Section {
                    Button {
                        dismiss()
                        onSingleModel()
                    } label: {
                        HStack {
                            Text("Single model…").foregroundStyle(JcTheme.text)
                            Spacer()
                            if current == "single" { JcIcon("checkmark").foregroundStyle(JcTheme.accent) }
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
            .navigationTitle(surface == .chat ? "Chat harness" : "Voice harness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
            .navigationDestination(isPresented: $editing) { HarnessesPage() }
        }
        .presentationDetents([.medium, .large])
        .task { await store.refresh() }
    }
}

/// Chip label: the harness, or for Single the model it runs.
private struct HarnessChipLabel: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            JcIcon(symbol).foregroundStyle(JcTheme.accent)
            Text(text).lineLimit(1)
        }
        .font(JcText.body)
        .frame(maxWidth: 140)
    }
}

/// The Chat header chip: the open chat's own harness, else the Chat default.
struct ChatHarnessChip: View {
    let store: ChatStore
    @State private var picking = false
    @State private var pickingModel = false
    private var harnesses: HarnessStore { HarnessStore.shared }

    private var current: String { harnesses.current(for: .chat, sessionHarnessID: store.harnessID) }

    private var label: String {
        if current == "single" {
            return ChatUIFormat.shortModelName(store.selectedModel?.label ?? store.selectedModelID ?? "")
        }
        return harnesses.title(for: current)
    }

    var body: some View {
        Button { picking = true } label: {
            HarnessChipLabel(text: label, symbol: current == "single" ? "sparkles" : "flowchart")
        }
        .buttonStyle(.plain)
        .foregroundStyle(JcTheme.text)
        .accessibilityLabel("Chat harness: \(label)")
        .sheet(isPresented: $picking) {
            HarnessSheet(surface: .chat, current: current,
                         onSelect: { choose($0) },
                         onSingleModel: { choose("single"); pickingModel = true })
        }
        .sheet(isPresented: $pickingModel) { ChatModelPickerSheet(store: store) }
        .task {
            if harnesses.harnesses.isEmpty { await harnesses.refresh() }
            if store.models == nil { await store.loadModels() }
        }
    }

    /// A new chat has no session yet: the choice rides its first turn
    /// (chat/start's harness_id) and the server keeps it on the chat.
    private func choose(_ id: String) {
        store.harnessID = id
        guard let sessionID = store.sessionID else { return }
        Task { await harnesses.select(id, surface: .chat, sessionID: sessionID) }
    }
}

/// The Voice header chip: the Voice default harness.
struct VoiceHarnessChip: View {
    let modelLabel: String
    @Binding var showModelPicker: Bool
    @State private var picking = false
    private var harnesses: HarnessStore { HarnessStore.shared }

    private var current: String { harnesses.current(for: .voice, sessionHarnessID: nil) }
    private var label: String { current == "single" ? modelLabel : harnesses.title(for: current) }

    var body: some View {
        Button { picking = true } label: {
            HarnessChipLabel(text: label, symbol: current == "single" ? "sparkles" : "flowchart")
        }
        .accessibilityLabel("Voice harness: \(label)")
        .sheet(isPresented: $picking) {
            HarnessSheet(surface: .voice, current: current,
                         onSelect: { id in Task { await harnesses.assign(id, to: .voice) } },
                         onSingleModel: {
                             Task { await harnesses.assign("single", to: .voice) }
                             showModelPicker = true
                         })
        }
        .task { if harnesses.harnesses.isEmpty { await harnesses.refresh() } }
    }
}
