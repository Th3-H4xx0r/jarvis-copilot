import SwiftUI

/// The "Dynamic Island" settings screen, ported from `pages/island_designs_page.dart`.
///
/// One radio group picks what shows: **Auto** (rules decide) or a specific entry
/// pinned, including the built-in Voice and Coding islands. Below it a management
/// list toggles each entry's place in the Auto rotation, nudges its priority and
/// deletes custom designs. Designs are authored by Jarvis via the dynamic-island
/// skill, never here.
struct IslandDesignsPage: View {
    @State private var store: IslandDesignsStore
    @State private var deleting: IslandCatalogEntry?

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: IslandDesignsStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated {
            IslandDesignsStore.production()
        })
    }

    var body: some View {
        content
            .jcScreen("Dynamic Island")
            .task { if store.entries.isEmpty { store.load() } }
            .moreToast($store.toast)
            .alert("Delete this design?", isPresented: deletingBinding, presenting: deleting) { entry in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await store.delete(entry) } }
            } message: { entry in
                Text("This removes “\(entry.name)”. Jarvis can recreate it later via "
                   + "the dynamic-island skill.")
            }
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pick which Dynamic Island shows — or let Auto choose by time "
                       + "and context. Jarvis creates custom designs for you; they "
                       + "appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 22)

                    if let message = store.errorMessage {
                        IslandErrorCard(message: message).padding(.bottom, 18)
                    }

                    GlassSectionLabel("Show on Dynamic Island")
                    GlassGroup {
                        IslandRadioRow(symbol: "wand.and.stars",
                                       title: "Auto",
                                       subtitle: "Let rules pick the right island at the right time.",
                                       selected: store.selectedKey == IslandDesignsStore.autoKey,
                                       last: store.entries.isEmpty,
                                       enabled: !store.isBusy) {
                            Task { await store.select(IslandDesignsStore.autoKey) }
                        }
                        ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                            IslandRadioRow(symbol: entry.iconName,
                                           title: entry.name,
                                           subtitle: entry.subtitle,
                                           selected: store.selectedKey == entry.id,
                                           last: index == store.entries.count - 1,
                                           enabled: !store.isBusy) {
                                Task { await store.select(entry.id) }
                            }
                        }
                    }
                    .padding(.bottom, 26)

                    GlassSectionLabel("In the Auto rotation")
                    GlassGroup {
                        ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                            IslandManageRow(entry: entry,
                                            busy: store.isBusy,
                                            last: index == store.entries.count - 1,
                                            onEnabled: { on in
                                                Task { await store.setEnabled(entry.id, on) }
                                            },
                                            onPriority: { value in
                                                Task { await store.setPriority(entry.id, value) }
                                            },
                                            onDelete: store.canDelete(entry)
                                                ? { deleting = entry } : nil)
                        }
                    }

                    if store.customEntries.isEmpty {
                        IslandEmptyHint().padding(.top, 18)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await store.refresh() }
        }
    }
}

/// One radio row: frosted glyph, title + subtitle, and the selection mark.
struct IslandRadioRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let selected: Bool
    let last: Bool
    let enabled: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 14) {
                    GlassCircleIcon(symbol: symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected ? JcTheme.primaryBlue : JcTheme.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            if !last {
                Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 68)
            }
        }
    }
}

/// One management row: name, a priority nudger, delete (custom designs only) and
/// the Auto-rotation switch.
struct IslandManageRow: View {
    let entry: IslandCatalogEntry
    let busy: Bool
    let last: Bool
    let onEnabled: (Bool) -> Void
    let onPriority: (Int) -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(entry.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                priority
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 15))
                            .foregroundStyle(JcTheme.muted)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityLabel("Delete \(entry.name)")
                }
                Toggle("", isOn: Binding(get: { entry.enabled }, set: onEnabled))
                    .labelsHidden()
                    .tint(JcTheme.primaryBlue)
                    .disabled(busy)
                    .accessibilityLabel("\(entry.name) in Auto rotation")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if !last {
                Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 14)
            }
        }
    }

    /// Priority decides which enabled entry Auto picks when several match, so it
    /// needs to be adjustable — the Flutter screen only showed it in the subtitle.
    private var priority: some View {
        HStack(spacing: 2) {
            Button { onPriority(max(0, entry.priority - 1)) } label: {
                Image(systemName: "minus").font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy || entry.priority <= 0)
            Text("\(entry.priority)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(JcTheme.text)
                .frame(minWidth: 18)
            Button { onPriority(min(99, entry.priority + 1)) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy || entry.priority >= 99)
        }
        .foregroundStyle(JcTheme.muted)
        .background(JcTheme.glassFill, in: Capsule())
        .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .accessibilityLabel("\(entry.name) priority \(entry.priority)")
    }
}

/// The "ask Jarvis for one" nudge, shown when nothing custom exists yet.
struct IslandEmptyHint: View {
    var body: some View {
        Text("No custom designs yet. Ask Jarvis to make one — e.g. “make a Dynamic "
           + "Island that shows my next meeting”.")
            .font(.system(size: 13))
            .foregroundStyle(JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

/// A soft red banner for a catalog that wouldn't load.
struct IslandErrorCard: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(JcTheme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(JcTheme.danger.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(JcTheme.danger.opacity(0.3), lineWidth: 1))
    }
}
