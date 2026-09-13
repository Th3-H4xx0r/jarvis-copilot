import SwiftUI

/// The session and model pickers, as menus.
///
/// Same choices as the phone's, driven by the same two stores — `VoiceSessionSelection`
/// and `VoiceModelStore` — so a model picked here is the model the next turn
/// carries, and a chat picked here is the one voice writes into, exactly as on
/// the phone. What differs is the presentation: the phone opens full-height
/// sheets built from its design system, and a sheet inside a 320-point popover
/// would cover the thing it is a control for. A pull-down menu is what a Mac
/// offers for "pick one of these", and it can be as long as it likes without
/// touching the panel.

// MARK: - Session

struct MacSessionMenu: View {
    let onChange: () -> Void

    @State private var selection = VoiceSessionSelection.shared
    @State private var sessions: [ChatSessionSummary] = []
    @State private var loading = false
    @State private var creating = false

    var body: some View {
        Menu {
            Button { choose(.defaultVoice) } label: {
                Label("Voice", systemImage: isDefault ? "checkmark" : "waveform")
            }
            if !sessions.isEmpty {
                Section("Recent chats") {
                    ForEach(sessions) { session in
                        Button {
                            choose(.session(id: session.id, title: session.displayTitle))
                        } label: {
                            Label(session.displayTitle,
                                  systemImage: selection.target.sessionID == session.id
                                      ? "checkmark" : "bubble.left")
                        }
                    }
                }
            }
            Divider()
            Button { Task { await newSession() } } label: {
                Label(creating ? "Starting…" : "New session", systemImage: "plus.bubble")
            }
            .disabled(creating)
            if loading {
                Text("Loading…")
            }
        } label: {
            MacPickerLabel(symbol: "bubble.left", text: selection.chipLabel)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which chat voice talks into")
        .accessibilityLabel("Voice session: \(selection.chipLabel)")
        .task { await load() }
    }

    private var isDefault: Bool { selection.target.sessionID == nil }

    private func choose(_ target: VoiceSessionSelection.Target) {
        selection.select(target)
        onChange()
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // A listing failure is not worth a banner in a menu — the default
        // session always works, and the chip still says which one is current.
        if let list = try? await SessionsAPI().list() {
            sessions = list
            // Drops a target whose chat was deleted elsewhere, and keeps the
            // chip's title current after a new chat gets its name.
            selection.reconcile(with: list)
        }
    }

    private func newSession() async {
        creating = true
        defer { creating = false }
        guard (try? await selection.startNewSession()) != nil else { return }
        onChange()
        await load()
    }
}

// MARK: - Model

struct MacModelMenu: View {
    @State private var models = VoiceModelStore.shared

    var body: some View {
        Menu {
            Button { models.select(nil) } label: {
                Label("Auto", systemImage: models.selectedModelID == nil
                      ? "checkmark" : "sparkles")
            }
            if let catalog = models.catalog {
                ForEach(catalog.providers, id: \.self) { provider in
                    Section(provider) {
                        ForEach(catalog.models(for: provider)) { model in
                            Button { models.select(model) } label: {
                                Label(model.label, systemImage: models.selectedModelID == model.id
                                      ? "checkmark" : "cpu")
                            }
                        }
                    }
                }
            } else if models.loading {
                Text("Loading…")
            } else if let failure = models.loadError {
                Text(failure)
            }
        } label: {
            MacPickerLabel(symbol: "sparkles", text: models.chipLabel)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which model answers")
        .accessibilityLabel("Voice model: \(models.chipLabel)")
        .task { await models.load() }
    }
}

// MARK: - Shared label

/// Both chips: a symbol, the current choice, and nothing else. Truncated hard —
/// a model id or a chat title can be long, and the panel is 320 points wide with
/// two of these and the pop-out button to fit on one row.
private struct MacPickerLabel: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(JcTheme.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: 110, alignment: .leading)
        .background(.white.opacity(0.045), in: Capsule())
        .contentShape(Capsule())
    }
}
