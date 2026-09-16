import SwiftUI

/// What one collection holds, newest first.
///
/// The registry imposes no shape on a record, so there is no fixed column set
/// to lay out: each record draws the fields it actually carries, under its time.
struct IntegrationRecordsView: View {
    /// From the route, not from the store: which integration was open can change
    /// during the push, and this screen is about the one that was tapped.
    let integrationID: String
    let collection: String
    @Bindable var store: IntegrationsStore

    @State private var records: [IntegrationRecord] = []
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        // One section per record, its time as the header. `LabeledContent` puts the
        // field name against its value and re-stacks them at accessibility sizes,
        // which a fixed-width label column cannot do.
        List {
            ForEach(records) { record in
                Section {
                    ForEach(record.fields, id: \.key) { field in
                        LabeledContent {
                            Text(field.value.isEmpty ? "\u{2014}" : field.value)
                                .font(IntegrationType.small)
                                .foregroundStyle(JcTheme.text)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Text(field.key)
                                .font(IntegrationType.small)
                                .foregroundStyle(JcTheme.muted)
                        }
                        .listRowBackground(JcTheme.surface)
                    }
                } header: {
                    if !record.timeLabel.isEmpty {
                        Text(record.timeLabel)
                            .font(IntegrationType.small)
                            .foregroundStyle(JcTheme.accent)
                            .textCase(nil)   // a timestamp is not a section name
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, integrationTapTarget)
        .overlay { state }
        .refreshable { await load() }
        .jcScreen(collection)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if loaded, !records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(records.count)")
                        .font(IntegrationType.small.monospacedDigit())
                        .foregroundStyle(JcTheme.muted)
                        .accessibilityLabel("\(records.count) records")
                }
            }
        }
        .task { if !loaded { await load() } }
    }

    @ViewBuilder
    private var state: some View {
        if let errorMessage {
            CenteredMessage(text: errorMessage, color: JcTheme.danger) { Task { await load() } }
        } else if !loaded {
            ProgressView()
        } else if records.isEmpty {
            ContentUnavailableView {
                Label("Nothing Recorded", jcIcon: "folder")
            } description: {
                Text("This collection is empty until a schedule appends to it.")
            }
        }
    }

    private func load() async {
        do {
            records = try await store.records(in: integrationID, collection: collection)
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        loaded = true
    }
}

/// One stored document, as it is: settings, a cursor, a state blob.
struct IntegrationDocumentView: View {
    let integrationID: String
    let key: String
    @Bindable var store: IntegrationsStore

    @State private var body_: String = ""
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage {
                    CenteredMessage(text: errorMessage, color: JcTheme.danger) { Task { await load() } }
                        .padding(.top, 80)
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 100)
                } else {
                    GlassCard(padding: 12) {
                        Text(body_.isEmpty ? "Empty." : body_)
                            .font(IntegrationType.small.monospaced())
                            .foregroundStyle(JcTheme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .refreshable { await load() }
        .jcScreen(key)
        .task { if !loaded { await load() } }
    }

    private func load() async {
        do {
            body_ = try await store.document(in: integrationID, key: key)
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        loaded = true
    }
}
