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
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage {
                    CenteredMessage(text: errorMessage, color: JcTheme.danger) { Task { await load() } }
                        .padding(.top, 80)
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 100)
                } else if records.isEmpty {
                    CenteredMessage(text: "Nothing recorded yet.").padding(.top, 80)
                } else {
                    Text("\(records.count) record\(records.count == 1 ? "" : "s"), newest first.")
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .padding(.bottom, 2)
                    ForEach(records) { record in
                        IntegrationRecordCard(record: record)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .refreshable { await load() }
        .jcScreen(collection)
        .task { if !loaded { await load() } }
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

struct IntegrationRecordCard: View {
    let record: IntegrationRecord

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 7) {
                if !record.timeLabel.isEmpty {
                    Text(record.timeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(JcTheme.accent)
                }
                ForEach(record.fields, id: \.key) { field in
                    HStack(alignment: .top, spacing: 10) {
                        Text(field.key)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .frame(width: 92, alignment: .leading)
                        Text(field.value.isEmpty ? "—" : field.value)
                            .font(.system(size: 12.5))
                            .foregroundStyle(JcTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                            .font(.system(size: 11.5, design: .monospaced))
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
