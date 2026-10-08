import SwiftUI

/// A host's Linked devices: each linked wearable's own card (long-press to unlink) and a way to
/// link another.
struct LinkedWearablesSection: View {
    let hostKind: String
    let hostName: String
    var namespace: Namespace.ID

    @ObservedObject private var links: WearableLinks = .shared
    @State private var choosing = false

    var body: some View {
        let children = links.children(of: hostKind)
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Linked devices")
                .padding(.horizontal, 4)
            if children.isEmpty {
                CardEmptyBlock(symbol: "link", text: "Nothing linked to \(hostName) yet.")
                    .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
            }
            ForEach(children, id: \.kind) { child in
                child.card(namespace: namespace)
                    .contextMenu {
                        Button("Unlink from \(hostName)", jcIcon: "link") { links.unlink(child.kind) }
                    }
            }
            Button {
                choosing = true
            } label: {
                Label("Link a device", jcIcon: "plus")
            }
            .buttonStyle(.jcGlass(compact: true))
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .sheet(isPresented: $choosing) {
            LinkWearableSheet(hostKind: hostKind, hostName: hostName)
                .presentationDetents([.medium])
        }
    }
}

/// The wearables that could be linked to a host, one tap each.
private struct LinkWearableSheet: View {
    let hostKind: String
    let hostName: String

    @ObservedObject private var links: WearableLinks = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let candidates = links.candidates(for: hostKind)
        NavigationStack {
            ScrollView {
                CardGroup {
                    if candidates.isEmpty {
                        CardEmptyBlock(symbol: "link", text: "Nothing else to link yet.")
                    }
                    ForEach(Array(candidates.enumerated()), id: \.element.kind) { index, candidate in
                        if index > 0 { RowDivider() }
                        Button {
                            try? links.link(candidate.kind, to: hostKind)
                            dismiss()
                        } label: {
                            Row {
                                HStack(spacing: 12) {
                                    JcIcon(candidate.symbol, size: 20).foregroundStyle(JcTheme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.title).font(.body.weight(.semibold))
                                        Text(candidate.linkStatus.text).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    JcIcon("plus", size: 15).foregroundStyle(JcTheme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 12)
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Link to \(hostName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
