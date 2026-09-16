import SwiftUI

/// What an integration keeps (collections and documents) and what it knows (skills),
/// one screen each, pushed from the Holdings rows on the detail screen.
///
/// Both are real inset-grouped `List`s: swipe a row to delete it, tap it to open it.
/// Deleting still goes through `integrationConfirm`, so a swipe is a shortcut to the
/// same question, never a shortcut past it.

// MARK: - Data

struct IntegrationDataListView: View {
    let integrationID: String
    @Bindable var store: IntegrationsStore
    @State private var confirming: IntegrationConfirm?

    private var detail: IntegrationDetail? {
        store.detailID == integrationID ? store.detail : nil
    }

    var body: some View {
        List {
            if let detail {
                if !detail.collections.isEmpty {
                    Section {
                        ForEach(detail.collections) { collection in
                            NavigationLink(value: IntegrationDataRoute.records(integrationID, collection.name)) {
                                holdingRow(collection.name,
                                           note: collection.summary,
                                           trailing: collection.count.formatted())
                            }
                            .listRowBackground(JcTheme.surface)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { confirming = .collection(collection) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: { sectionHeader("Collections") } footer: {
                        sectionFooter("Rows appended over time. Opening one shows its records.")
                    }
                }
                if !detail.documents.isEmpty {
                    Section {
                        ForEach(detail.documents) { document in
                            NavigationLink(value: IntegrationDataRoute.document(integrationID, document.key)) {
                                holdingRow(document.key,
                                           note: document.summary,
                                           trailing: document.sizeLabel)
                            }
                            .listRowBackground(JcTheme.surface)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { confirming = .document(document) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: { sectionHeader("Documents") } footer: {
                        sectionFooter("A single value, overwritten each time it changes.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, integrationTapTarget)
        .overlay {
            if detail == nil {
                ProgressView()
            } else if detail?.hasNothingStored == true {
                ContentUnavailableView {
                    Label("Nothing Stored", jcIcon: "folder")
                } description: {
                    Text("What this integration's schedules record will show up here.")
                }
            }
        }
        .refreshable { await store.open(integrationID) }
        .jcScreen("Data")
        .task { if detail == nil { await store.open(integrationID) } }
        .integrationConfirm($confirming, store: store)
    }
}

// MARK: - Skills

struct IntegrationSkillsListView: View {
    let integrationID: String
    @Bindable var store: IntegrationsStore
    @State private var confirming: IntegrationConfirm?

    private var detail: IntegrationDetail? {
        store.detailID == integrationID ? store.detail : nil
    }

    var body: some View {
        List {
            if let detail, !detail.skills.isEmpty {
                Section {
                    ForEach(detail.skills) { skill in
                        NavigationLink(value: IntegrationDataRoute.skill(integrationID, skill.name)) {
                            holdingRow(skill.name, note: skill.summary, trailing: nil)
                        }
                        .listRowBackground(JcTheme.surface)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { confirming = .skill(skill) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    sectionFooter("A skill is instructions Jarvis follows when it works on this integration.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, integrationTapTarget)
        .overlay {
            if detail == nil {
                ProgressView()
            } else if detail?.skills.isEmpty == true {
                ContentUnavailableView {
                    Label("No Skills", jcIcon: "scroll")
                } description: {
                    Text("Ask Jarvis to write one, and it will claim this integration.")
                }
            }
        }
        .refreshable { await store.open(integrationID) }
        .jcScreen("Skills")
        .task { if detail == nil { await store.open(integrationID) } }
        .integrationConfirm($confirming, store: store)
    }
}

// MARK: - Shared row

/// Name over description, with a count or size trailing. The chevron comes from
/// `NavigationLink` itself, which is the point of using one.
@ViewBuilder
private func holdingRow(_ title: String, note: String, trailing: String?) -> some View {
    HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(IntegrationType.body)
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            if !note.isEmpty {
                Text(note)
                    .font(IntegrationType.small)
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(2)
            }
        }
        Spacer(minLength: 8)
        if let trailing {
            Text(trailing)
                .font(IntegrationType.small.monospacedDigit())
                .foregroundStyle(JcTheme.muted)
        }
    }
    .padding(.vertical, 4)
}

@ViewBuilder
private func sectionHeader(_ text: String) -> some View {
    Text(text)
        .font(IntegrationType.small)
        .textCase(.uppercase)
        .foregroundStyle(JcTheme.muted)
}

@ViewBuilder
private func sectionFooter(_ text: String) -> some View {
    Text(text)
        .font(IntegrationType.small)
        .foregroundStyle(JcTheme.muted)
}
