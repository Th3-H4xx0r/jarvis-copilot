import SwiftUI

/// Deleting an integration, one part at a time.
///
/// "Delete" on an integration can mean four different things and the difference
/// matters: dropping its data keeps the schedules running against nothing,
/// removing the schedules leaves the history readable, and taking a skill out of
/// service reaches beyond this integration entirely. So the sheet asks which,
/// spells out what that adds up to, and only then offers the red word.
///
/// Built as a navigation-bar sheet rather than a stack ending in a red slab:
/// Cancel is a peer of Delete, which is what a destructive, irreversible choice
/// is owed, and the toggles are plain grouped rows people already know.
struct IntegrationDeleteSheet: View {
    let integration: Integration
    let scheduleCount: Int
    let collectionCount: Int
    let documentCount: Int
    let skillCount: Int
    /// Returns whether it worked. A failed delete keeps the sheet open, with the
    /// choices intact — closing would lose them and hide the reason behind itself.
    let confirm: (IntegrationDeleteChoice) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var choice = IntegrationDeleteChoice()
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    toggle("Schedules", detail: count(scheduleCount, "schedule"),
                           isOn: $choice.schedules)
                    toggle("Data", detail: dataDetail, isOn: $choice.data)
                    toggle("Skills", detail: count(skillCount, "skill"), isOn: $choice.skills)
                    if choice.skills && skillCount > 0 {
                        toggle("Also delete their files",
                               detail: "Otherwise they just stop belonging here",
                               isOn: $choice.skillFiles)
                    }
                    toggle("The integration itself", detail: integration.id, isOn: $choice.space)
                } footer: {
                    // What the switches above add up to, in one sentence, before
                    // the word Delete is ever reachable.
                    Text(choice.summary(schedules: scheduleCount, collections: collectionCount,
                                        documents: documentCount, skills: skillCount))
                        .font(IntegrationType.small)
                        .foregroundStyle(choice.isEmpty ? JcTheme.muted : JcTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failure {
                    Section {
                        Text(failure)
                            .font(IntegrationType.small)
                            .foregroundStyle(JcTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowBackground(JcTheme.surface)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, integrationTapTarget)
            .navigationTitle("Delete \(integration.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Delete", role: .destructive, action: run)
                            .tint(JcTheme.danger)
                            .disabled(choice.isEmpty)
                    }
                }
            }
            .background(JcTheme.bg)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(JcTheme.bg)
    }

    private func run() {
        working = true
        failure = nil
        Task {
            let ok = await confirm(choice)
            working = false
            if ok { dismiss() } else { failure = "That did not go through. Try again." }
        }
    }

    private var dataDetail: String {
        var parts: [String] = []
        if collectionCount > 0 { parts.append(count(collectionCount, "collection")) }
        if documentCount > 0 { parts.append(count(documentCount, "document")) }
        return parts.isEmpty ? "Nothing stored" : parts.joined(separator: ", ")
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IntegrationType.body)
                    .foregroundStyle(JcTheme.text)
                Text(detail)
                    .font(IntegrationType.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(JcTheme.accent)
        .listRowBackground(JcTheme.surface)
        .padding(.vertical, 2)
    }
}
