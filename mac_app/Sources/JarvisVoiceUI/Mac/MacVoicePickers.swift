import SwiftUI

/// The session and model pickers.
///
/// Same choices as the phone's, driven by the same two stores —
/// `VoiceSessionSelection` and `VoiceModelStore` — so a model picked here is the
/// model the next turn carries, and a chat picked here is the one voice writes
/// into, exactly as on the phone. What differs is the presentation: the phone
/// opens full-height sheets built from its design system, and a sheet inside a
/// 320-point popover would cover the thing it is a control for. A pull-down menu
/// is what a Mac offers for "pick one of these", and it can be as long as it
/// likes without touching the panel.
///
/// Both are `MacMenuChip`, which is an `NSButton` — see that file for why
/// SwiftUI's own `Menu` could not be made clickable here.

// MARK: - Session

struct MacSessionMenu: View {
    let enabled: Bool
    let onChange: () -> Void

    @State private var selection = VoiceSessionSelection.shared
    @State private var sessions: [ChatSessionSummary] = []
    @State private var loading = false

    var body: some View {
        MacMenuChip(symbol: "bubble.left",
                    text: selection.chipLabel,
                    enabled: enabled,
                    help: "Which chat voice talks into",
                    accessibilityLabel: "Voice session: \(selection.chipLabel)") {
            entries()
        }
        .task { await load() }
    }

    private func entries() -> [ChipMenuEntry] {
        var out: [ChipMenuEntry] = [
            ChipMenuEntry(title: "Voice", checked: selection.target.sessionID == nil,
                          action: { choose(.defaultVoice) })
        ]
        if !sessions.isEmpty {
            out.append(.separator())
            out.append(.header("Recent chats"))
            for session in sessions {
                out.append(ChipMenuEntry(
                    title: session.displayTitle,
                    checked: selection.target.sessionID == session.id,
                    action: { choose(.session(id: session.id, title: session.displayTitle)) }))
            }
        }
        out.append(.separator())
        out.append(ChipMenuEntry(title: "New session…",
                                 action: { Task { await newSession() } }))
        return out
    }

    private func choose(_ target: VoiceSessionSelection.Target) {
        selection.select(target)
        onChange()
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // A listing failure is not worth surfacing in a menu — the default
        // session always works, and the chip still says which one is current.
        if let list = try? await SessionsAPI().list() {
            sessions = list
            // Drops a target whose chat was deleted elsewhere, and keeps the
            // chip's title current once a new chat gets its name.
            selection.reconcile(with: list)
        }
    }

    private func newSession() async {
        guard (try? await selection.startNewSession()) != nil else { return }
        onChange()
        await load()
    }
}

// MARK: - Model

struct MacModelMenu: View {
    let enabled: Bool

    @State private var models = VoiceModelStore.shared

    var body: some View {
        MacMenuChip(symbol: "sparkles",
                    text: models.chipLabel,
                    enabled: enabled,
                    help: "Which model answers",
                    accessibilityLabel: "Voice model: \(models.chipLabel)") {
            entries()
        }
        .task { await models.load() }
    }

    private func entries() -> [ChipMenuEntry] {
        var out: [ChipMenuEntry] = [
            ChipMenuEntry(title: "Auto", checked: models.selectedModelID == nil,
                          action: { models.select(nil) })
        ]
        guard let catalog = models.catalog else {
            out.append(.separator())
            out.append(.header(models.loading ? "Loading…"
                               : (models.loadError ?? "No models")))
            return out
        }
        for provider in catalog.providers {
            out.append(.separator())
            out.append(.header(provider))
            for model in catalog.models(for: provider) {
                out.append(ChipMenuEntry(title: model.label,
                                         checked: models.selectedModelID == model.id,
                                         action: { models.select(model) }))
            }
        }
        return out
    }
}
