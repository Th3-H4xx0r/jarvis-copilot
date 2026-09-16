import SwiftUI

/// The parts the Integrations screens are built from: a titled section, one
/// rounded card of hairline-separated rows, and the row itself.
///
/// The row is the whole pattern in one place — tap to open, ⋯ to act on it — so a
/// schedule, a collection, a document and a skill all behave the same way.

/// A titled section with a count chip and, optionally, one action on the right.
struct IntegrationSection<Content: View>: View {
    let title: String
    let count: Int
    var action: Action? = nil
    @ViewBuilder var content: Content

    struct Action {
        let symbol: String
        let run: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(JcTheme.muted)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(JcTheme.accent.opacity(0.12)))
                Spacer(minLength: 0)
                if let action {
                    Button(action: action.run) {
                        JcIcon(action.symbol, size: 13)
                            .foregroundStyle(JcTheme.accent)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            content
        }
    }
}

/// One rounded card holding a section's rows.
struct InsetGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(JcTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(JcTheme.border, lineWidth: 0.5))
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
            .padding(.leading, 14)
    }
}

/// One thing inside a section: tap the body to open it, ⋯ to act on it.
struct IntegrationRow<Menu: View>: View {
    let name: String
    let note: String
    let trailing: String
    var route: IntegrationDataRoute? = nil
    var onTap: (() -> Void)? = nil
    @ViewBuilder var menu: Menu

    init(name: String, note: String, trailing: String,
         route: IntegrationDataRoute? = nil, onTap: (() -> Void)? = nil,
         @ViewBuilder menu: () -> Menu) {
        self.name = name
        self.note = note
        self.trailing = trailing
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
                    .frame(width: 34, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
    }

    private var label: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(JcTheme.muted)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

struct IntegrationEmptyRow: View {
    let text: String

    var body: some View {
        InsetGroup {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
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
