import SwiftUI

/// What the Integrations screens share: their type scale, their tap-target floor,
/// the one delete confirmation they all go through, and the card the setup
/// conversation draws for each thing it creates.
///
/// The rows, groups, separators and disclosure indicators these screens used to
/// hand-roll are `List` with `.insetGrouped` now — the system draws them, and it
/// draws them right at every text size.
///
/// Type here is Dynamic Type rather than `JcText`, whose fixed point sizes never
/// grow with the system text setting. The defaults land within a point of the rest
/// of the app; these screens just also scale.

/// The sizes these screens use, as text styles that scale.
enum IntegrationType {
    /// 20pt semibold — a screen or card title.
    static let title = Font.title3.weight(.semibold)
    /// 15pt — the default reading size, and a row's name.
    static let body = Font.subheadline
    /// 15pt semibold — a control's label.
    static let label = Font.subheadline.weight(.semibold)
    /// 13pt — a row's second line, a caption, metadata.
    static let small = Font.footnote
}

/// The smallest a control may be and still be reliably tappable (HIG: 44x44 pt).
let integrationTapTarget: CGFloat = 44

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
                    .font(IntegrationType.body)
                    .foregroundStyle(JcTheme.text)
                if !card.detail.isEmpty {
                    Text(card.detail)
                        .font(IntegrationType.small)
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
