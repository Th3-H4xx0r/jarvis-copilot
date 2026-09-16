import SwiftUI

/// Deleting an integration, one part at a time.
///
/// "Delete" on an integration can mean four different things and the difference
/// matters: dropping its data keeps the schedules running against nothing,
/// removing the schedules leaves the history readable, and taking a skill out of
/// service reaches beyond this integration entirely. So the sheet asks which,
/// spells out what that adds up to, and only then offers a red button.
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
        DetailSheet(title: "Delete \(integration.name)") {
            VStack(alignment: .leading, spacing: 14) {
                InsetGroup {
                    toggle("Schedules", detail: count(scheduleCount, "schedule"),
                           isOn: $choice.schedules)
                    InsetDivider()
                    toggle("Data", detail: dataDetail, isOn: $choice.data)
                    InsetDivider()
                    toggle("Skills", detail: count(skillCount, "skill"), isOn: $choice.skills)
                    if choice.skills && skillCount > 0 {
                        InsetDivider()
                        toggle("Also delete their files",
                               detail: "Otherwise they just stop belonging here",
                               isOn: $choice.skillFiles, indented: true)
                    }
                    InsetDivider()
                    toggle("The integration itself", detail: integration.id,
                           isOn: $choice.space)
                }

                Text(choice.summary(schedules: scheduleCount, collections: collectionCount,
                                    documents: documentCount, skills: skillCount))
                    .font(.system(size: 12.5))
                    .foregroundStyle(choice.isEmpty ? JcTheme.muted : JcTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)

                if let failure {
                    Text(failure)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    working = true
                    failure = nil
                    Task {
                        let ok = await confirm(choice)
                        working = false
                        if ok { dismiss() } else { failure = "That did not go through. Try again." }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if working { ProgressView().controlSize(.small) }
                        Text(working ? "Deleting\u{2026}" : "Delete")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(JcTheme.danger.opacity(choice.isEmpty ? 0.12 : 0.9),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(choice.isEmpty ? JcTheme.muted : Color.white)
                }
                .buttonStyle(.plain)
                .disabled(choice.isEmpty || working)
            }
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

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>,
                        indented: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: indented ? .regular : .medium))
                    .foregroundStyle(JcTheme.text)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
            }
        }
        .tint(JcTheme.danger)
        .padding(.leading, indented ? 28 : 14)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }
}
