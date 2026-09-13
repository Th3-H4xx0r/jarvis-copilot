import SwiftUI

/// The session and model pickers.
///
/// Same choices as the phone's, driven by the same two stores —
/// `VoiceSessionSelection` and `VoiceModelStore` — so a model picked here is the
/// model the next turn carries, and a chat picked here is the one voice writes
/// into, exactly as on the phone.
///
/// Drawn INSIDE the panel, not as a menu. This panel's usual home is a transient
/// `NSPopover`, and a menu is its own window: opening one is a click outside the
/// popover, so the popover closes and takes the menu with it. Nothing appears,
/// and the chip reads as dead. Three menu constructions were tried against that
/// — SwiftUI's `Menu`, an `NSButton` popping one from its action, and an
/// `NSPopUpButton` — and the popover defeats all three, because the problem was
/// never the control.
///
/// A list drawn in the panel's own hierarchy has no window to lose. It also
/// behaves the same in the pop-out window, where a menu would have worked.

/// One row of a picker.
struct PickerRow: Identifiable {
    enum Kind { case item, header }

    let id = UUID()
    var kind: Kind = .item
    var title: String = ""
    var checked: Bool = false
    var action: () -> Void = {}

    static func header(_ title: String) -> PickerRow {
        PickerRow(kind: .header, title: title)
    }
}

/// Which picker is open, if any.
enum MacPickerKind: Identifiable {
    case session, model
    var id: Self { self }

    var title: String {
        switch self {
        case .session: return "Voice session"
        case .model: return "Model"
        }
    }
}

// MARK: - Session

@MainActor
@Observable
final class MacSessionPicker {
    private let selection = VoiceSessionSelection.shared
    /// How many chats the picker offers. The server returns every session
    /// there has ever been — the first version of this listed all of them and
    /// drew a menu taller than the screen. "Recent chats" is what the phone's
    /// picker calls this list, and recent is what it should mean.
    static let recentLimit = 10

    private(set) var sessions: [ChatSessionSummary] = []
    private var loading = false

    var chipLabel: String { selection.chipLabel }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // A listing failure is not worth a banner — the default session always
        // works, and the chip still says which one is current.
        if let list = try? await SessionsAPI().list() {
            sessions = Array(list.prefix(Self.recentLimit))
            // Drops a target whose chat was deleted elsewhere, and keeps the
            // chip's title current once a new chat gets its name.
            // Reconciled against the FULL list: a chat further down it is still
            // a live target, and pruning the selection to the visible ten would
            // throw away a perfectly good one.
            selection.reconcile(with: list)
        }
    }

    func rows(onChange: @escaping () -> Void) -> [PickerRow] {
        var out = [PickerRow(title: "Voice",
                             checked: selection.target.sessionID == nil,
                             action: { self.choose(.defaultVoice, onChange) })]
        if !sessions.isEmpty {
            out.append(.header("Recent chats"))
            for session in sessions {
                out.append(PickerRow(
                    title: session.displayTitle,
                    checked: selection.target.sessionID == session.id,
                    action: {
                        self.choose(.session(id: session.id, title: session.displayTitle),
                                    onChange)
                    }))
            }
        }
        out.append(.header(""))
        out.append(PickerRow(title: "New session…", action: {
            Task {
                guard (try? await self.selection.startNewSession()) != nil else { return }
                onChange()
                await self.load()
            }
        }))
        return out
    }

    private func choose(_ target: VoiceSessionSelection.Target, _ onChange: () -> Void) {
        selection.select(target)
        onChange()
    }
}

// MARK: - Model

@MainActor
@Observable
final class MacModelPicker {
    private let models = VoiceModelStore.shared

    var chipLabel: String { models.chipLabel }

    func load() async { await models.load() }

    func rows() -> [PickerRow] {
        var out = [PickerRow(title: "Auto",
                             checked: models.selectedModelID == nil,
                             action: { self.models.select(nil) })]
        guard let catalog = models.catalog else {
            out.append(.header(models.loading ? "Loading…" : (models.loadError ?? "No models")))
            return out
        }
        for provider in catalog.providers {
            out.append(.header(provider))
            for model in catalog.models(for: provider) {
                out.append(PickerRow(title: model.label,
                                     checked: models.selectedModelID == model.id,
                                     action: { self.models.select(model) }))
            }
        }
        return out
    }
}

// MARK: - Views

/// The chip: a symbol, the current choice, a chevron. An ordinary SwiftUI
/// `Button`, which — unlike `Menu` — hit-tests the whole shape it is given.
struct MacPickerChip: View {
    /// Longest chat title or model name the chip shows.
    ///
    /// Clipped as a STRING, not with `frame(maxWidth:)`. A capped frame makes
    /// the chip claim that width whether its text needs it or not, so two chips
    /// push each other across the row and the chevron ends up an inch from the
    /// word it belongs to. Cutting the string keeps the chip exactly as wide as
    /// what it says.
    static let titleLimit = 16

    static func clipped(_ text: String) -> String {
        text.count <= titleLimit ? text
            : String(text.prefix(titleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    let symbol: String
    let text: String
    var enabled: Bool = true
    var accessibilityLabel: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(Self.clipped(text))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(JcTheme.text.opacity(enabled ? 0.75 : 0.35))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // `frame(maxWidth:)` would make the chip CLAIM that width whether it
            // needs it or not, and two of them then push each other across the
            // row. The text is what is capped.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel.isEmpty ? text : accessibilityLabel)
    }
}

/// The open picker: a scrim over the panel and a card of rows.
struct MacPickerSheet: View {
    let title: String
    let rows: [PickerRow]
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // Tapping anywhere outside the card closes it, the way dismissing a
            // menu does — and it must swallow the tap, or the control underneath
            // takes it too.
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(JcTheme.muted)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            switch row.kind {
                            case .header:
                                if !row.title.isEmpty {
                                    Text(row.title.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                        .tracking(0.8)
                                        .foregroundStyle(JcTheme.muted.opacity(0.8))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 10)
                                        .padding(.bottom, 3)
                                } else {
                                    Divider().opacity(0.25).padding(.vertical, 5)
                                }
                            case .item:
                                Button {
                                    row.action()
                                    onDismiss()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .opacity(row.checked ? 1 : 0)
                                            .frame(width: 11)
                                        Text(row.title)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(JcTheme.text)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(MacPickerRowStyle())
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            .frame(maxHeight: 210)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape.fill(Color(jcHex: 0x15151C))
                shape.strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
            .padding(.horizontal, 10)
            .padding(.top, 32)
        }
    }
}

/// Rows highlight under the pointer, as menu rows do.
private struct MacPickerRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed
                        ? Color.white.opacity(0.10) : Color.clear)
            .onHover { hovering = $0 }
    }
}
