import SwiftUI

/// The chat model picker, ported from `widgets/model_picker_sheet.dart`: the
/// catalogue grouped by provider, searchable, with the current choice ticked.
///
/// "Auto" is the top row and clears the explicit pick, so the server's active /
/// default model decides. Selection is persisted through
/// ``ChatStore/selectModel(_:)`` → ``ModelSelection`` (key `sel_chat_model`), the
/// same key the Flutter app used, so a migrated install keeps its model.
struct ChatModelPickerSheet: View {
    let store: ChatStore

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var loading = false

    private var catalog: ModelCatalog? { store.models }

    private func models(for provider: String) -> [ChatModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = catalog?.models(for: provider) ?? []
        guard !needle.isEmpty else { return all }
        return all.filter { $0.label.lowercased().contains(needle) || $0.id.lowercased().contains(needle) }
    }

    private var providers: [String] {
        (catalog?.providers ?? []).filter { !models(for: $0).isEmpty }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Chat model")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search models")
        }
        .presentationDetents([.large])
        .task {
            guard store.models == nil else { return }
            loading = true
            await store.loadModels()
            loading = false
        }
    }

    @ViewBuilder private var content: some View {
        if loading && catalog == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).jcScreen()
        } else if catalog == nil {
            VStack(spacing: 12) {
                CenteredMessage(text: "Couldn’t load models.")
                Button("Retry") {
                    Task { loading = true; await store.loadModels(); loading = false }
                }
                .font(JcText.label)
                .foregroundStyle(JcTheme.accent)
            }
            .frame(maxHeight: .infinity)
            .jcScreen()
        } else {
            List {
                Section {
                    row(title: "Auto",
                        subtitle: defaultSubtitle,
                        selected: store.selectedModelID == nil) { store.selectModel(nil) }
                }
                ForEach(providers, id: \.self) { provider in
                    Section(provider.isEmpty ? "Models" : provider) {
                        ForEach(models(for: provider)) { model in
                            row(title: model.label,
                                subtitle: model.label == model.id ? nil : model.id,
                                selected: model.id == store.selectedModelID) {
                                store.selectModel(model)
                            }
                        }
                    }
                }
                if providers.isEmpty {
                    Section { Text("No models match.").foregroundStyle(JcTheme.muted) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .jcScreen()
        }
    }

    private var defaultSubtitle: String {
        let fallback = catalog?.activeModel ?? catalog?.defaultModel ?? ""
        return fallback.isEmpty ? "Server default model." : "Server default — \(fallback)."
    }

    private func row(title: String, subtitle: String?, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: selected ? .bold : .medium))
                        .foregroundStyle(JcTheme.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(JcTheme.primaryBlueHi)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(JcTheme.glassFill)
    }
}
