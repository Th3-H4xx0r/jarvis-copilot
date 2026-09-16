import SwiftUI

/// The parts the Integrations screens are built from: a titled section, one
/// rounded card of hairline-separated rows, and the row itself.
///
/// The row is the whole pattern in one place — tap to open, ⋯ to act on it — so a
/// schedule, a collection, a document and a skill all behave the same way.
///
/// Type stays on the app's fixed scale (`JcText`) rather than Dynamic Type: these
/// screens sit next to ones that don't scale, and a section that grows on its own
/// reads as a different app rather than as a setting being honoured.

/// The smallest a control may be and still be reliably tappable (HIG: 44x44 pt).
let integrationTapTarget: CGFloat = 44

/// A titled section with a count chip and, optionally, one action on the right.
struct IntegrationSection<Content: View>: View {
    let title: String
    let count: Int
    /// A word about the section's state — "2 running", "all paused" — where the
    /// answer belongs: next to the name of the thing it is about.
    var status: String? = nil
    var statusColor: Color = JcTheme.success
    var action: Action? = nil
    @ViewBuilder var content: Content

    struct Action {
        let symbol: String
        let run: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title) {
                HStack(spacing: 8) {
                    if let status {
                        Text(status)
                            .font(JcText.small)
                            .foregroundStyle(statusColor)
                    }
                    CountChip(count)
                    if let action {
                        Button(action: action.run) {
                            JcIcon(action.symbol, size: 15)
                                .foregroundStyle(JcTheme.accent)
                                .fixedSize()
                                .frame(width: integrationTapTarget, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add to \(title)")
                    }
                }
            }
            content
        }
    }
}

/// How many of a thing a section holds.
struct CountChip: View {
    let count: Int

    init(_ count: Int) { self.count = count }

    var body: some View {
        Text("\(count)")
            .font(JcText.small)
            .foregroundStyle(JcTheme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(JcTheme.accent.opacity(0.14)))
    }
}

/// One rounded card holding a section's rows.
struct InsetGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard(padding: 0) { VStack(spacing: 0) { content } }
    }
}

/// An `InsetGroup` built from a list, with a separator between each pair.
struct InsetRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    var body: some View {
        InsetGroup {
            ForEach(items) { item in
                row(item)
                if item.id != items.last?.id { InsetDivider() }
            }
        }
    }
}

/// The hairline between two rows, inset past the text so it reads as a list.
struct InsetDivider: View {
    var body: some View {
        Rectangle()
            .fill(JcTheme.border)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

/// One thing inside a section: tap the body to open it, ⋯ to act on it.
struct IntegrationRow<Menu: View>: View {
    let name: String
    let note: String
    let trailing: String
    /// State as a shape, not only as a colour: a paused schedule reads as paused
    /// to someone who cannot tell grey from green.
    var leading: String? = nil
    var leadingColor: Color = JcTheme.accent
    var route: IntegrationDataRoute? = nil
    var onTap: (() -> Void)? = nil
    @ViewBuilder var menu: Menu

    init(name: String, note: String, trailing: String,
         leading: String? = nil, leadingColor: Color = JcTheme.accent,
         route: IntegrationDataRoute? = nil, onTap: (() -> Void)? = nil,
         @ViewBuilder menu: () -> Menu) {
        self.name = name
        self.note = note
        self.trailing = trailing
        self.leading = leading
        self.leadingColor = leadingColor
        self.route = route
        self.onTap = onTap
        self.menu = menu()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let route {
                NavigationLink(value: route) { label }.buttonStyle(.plain)
            } else if let onTap {
                Button(action: onTap) { label }.buttonStyle(.plain)
            } else {
                label
            }
            SwiftUI.Menu {
                menu
            } label: {
                JcIcon("ellipsis", size: 14)
                    .foregroundStyle(JcTheme.muted)
                    .frame(width: 40, height: integrationTapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(name)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
    }

    private var label: some View {
        HStack(spacing: 10) {
            if let leading {
                JcIcon(leading, size: 11)
                    .foregroundStyle(leadingColor)
                    .fixedSize()
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                if !note.isEmpty {
                    Text(note)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(JcText.small.monospacedDigit())
                    .foregroundStyle(JcTheme.muted)
            }
            // A row that goes somewhere says so, the way every other row in iOS does.
            if route != nil || onTap != nil {
                JcIcon("chevron.right", size: 10)
                    .foregroundStyle(JcTheme.muted.opacity(0.6))
                    .fixedSize()
            }
        }
        .padding(.vertical, 11)
        .frame(minHeight: integrationTapTarget)
        .contentShape(Rectangle())
    }
}

struct IntegrationEmptyRow: View {
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    init(text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        InsetGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                // An empty section that names what would fill it beats one that
                // only reports that it is empty.
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(JcText.label)
                        .foregroundStyle(JcTheme.accent)
                        .frame(minHeight: 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

struct IntegrationLoadingRow: View {
    var body: some View {
        InsetGroup {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
    }
}

// MARK: - Confirming a delete

/// Which row is asking to be deleted. One value drives every confirmation, so a
/// screen never has three half-open dialogs' worth of state.
enum IntegrationConfirm: Identifiable {
    case collection(IntegrationCollection)
    case document(IntegrationDocument)
    case skill(IntegrationSkill)

    var id: String {
        switch self {
        case .collection(let c): return "collection:\(c.name)"
        case .document(let d):   return "document:\(d.key)"
        case .skill(let s):      return "skill:\(s.name)"
        }
    }
}

extension View {
    /// The confirmation every per-row delete goes through.
    ///
    /// A skill gets a choice rather than a yes/no: unlinking it is cheap to undo,
    /// taking it out of service is not, and the two should never be one button.
    func integrationConfirm(_ pending: Binding<IntegrationConfirm?>,
                            store: IntegrationsStore) -> some View {
        modifier(IntegrationConfirmModifier(pending: pending, store: store))
    }
}

private struct IntegrationConfirmModifier: ViewModifier {
    @Binding var pending: IntegrationConfirm?
    let store: IntegrationsStore

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible,
                                   presenting: pending) { item in
            switch item {
            case .collection(let collection):
                Button("Delete \(collection.count.formatted()) records", role: .destructive) {
                    Task { await store.deleteCollection(collection.name) }
                }
            case .document(let document):
                Button("Delete", role: .destructive) {
                    Task { await store.deleteDocument(document.key) }
                }
            case .skill(let skill):
                Button("Remove from this integration") {
                    Task { await store.deleteSkill(skill.name, mode: .unlink) }
                }
                Button("Delete the skill entirely", role: .destructive) {
                    Task { await store.deleteSkill(skill.name, mode: .file) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(message(for: item))
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var title: String {
        switch pending {
        case .collection(let c): return "Delete \(c.name)?"
        case .document(let d):   return "Delete \(d.key)?"
        case .skill(let s):      return "Delete \(s.name)?"
        case nil:                return ""
        }
    }

    private func message(for item: IntegrationConfirm) -> String {
        switch item {
        case .collection(let c):
            return "Every record in it goes — \(c.count.formatted()) of them. This cannot be undone."
        case .document:
            return "What it holds goes with it. This cannot be undone."
        case .skill:
            return "Removing it from this integration leaves the skill alone. "
                 + "Deleting it takes it out of service everywhere."
        }
    }
}

/// A piece of an integration, the moment it exists.
///
/// Drawn wherever the conversation is shown — the setup sheet and the Chat tab
/// both get it, because both are the same view.
struct SetupCardView: View {
    let card: SetupCard

    private var symbol: String {
        switch card.kind {
        case .integration: return "folder"
        case .data:        return "doc.text"
        case .schedule:    return "clock"
        case .skill:       return "sparkles"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            JcIcon(symbol, size: 14).foregroundStyle(JcTheme.success).fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.text)
                if !card.detail.isEmpty {
                    Text(card.detail)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            StatusPill(card.kind.rawValue.uppercased(), color: JcTheme.success, dense: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(JcTheme.success.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous))
    }
}
