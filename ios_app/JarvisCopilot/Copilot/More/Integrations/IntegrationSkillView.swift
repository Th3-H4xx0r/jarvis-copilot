import SwiftUI

/// A skill, in full.
///
/// The row on an integration's page shows a name and a truncated description;
/// this is the whole thing — where it lives, what it is for, what it tells the
/// agent to do, and any files that came with it.
struct IntegrationSkillView: View {
    let name: String
    var api: JarvisAPI = .shared

    @State private var skill: SkillDetail?
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let skill {
                Section {
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(IntegrationType.body)
                            .foregroundStyle(JcTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowBackground(JcTheme.surface)
                    }
                    if !skill.tags.isEmpty {
                        JcWrap(spacing: 6, runSpacing: 6) {
                            ForEach(skill.tags, id: \.self) { tag in
                                StatusPill(tag, color: JcTheme.accent, dense: true)
                            }
                        }
                        .listRowBackground(JcTheme.surface)
                    }
                } footer: {
                    if !skill.path.isEmpty {
                        Text(skill.path)
                            .font(IntegrationType.small.monospaced())
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textCase(nil)
                    }
                }

                if !skill.linkedFiles.isEmpty {
                    Section {
                        ForEach(skill.linkedFiles) { file in
                            Text(file.name)
                                .font(IntegrationType.body)
                                .foregroundStyle(JcTheme.text)
                                .listRowBackground(JcTheme.surface)
                        }
                    } header: { header("Files") } footer: {
                        footer("Shipped alongside the skill and readable by it.")
                    }
                }

                Section {
                    // The skill's own text — what it actually tells the agent —
                    // through the same markdown renderer a reply uses.
                    ChatMarkdownText(text: skill.markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(JcTheme.surface)
                } header: { header("What it says") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, integrationTapTarget)
        .overlay { state }
        .refreshable { await load() }
        .jcScreen(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load() } }
    }

    @ViewBuilder
    private var state: some View {
        if let errorMessage {
            CenteredMessage(text: errorMessage, color: JcTheme.danger) { Task { await load() } }
        } else if !loaded {
            ProgressView()
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(IntegrationType.small)
            .textCase(.uppercase)
            .foregroundStyle(JcTheme.muted)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(IntegrationType.small)
            .foregroundStyle(JcTheme.muted)
    }

    private func load() async {
        do {
            let body = try await api.get("/api/skills/content",
                                         query: ["name": name]).object()
            skill = SkillDetail(json: body)
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        loaded = true
    }
}

/// One skill as `/api/skills/content` returns it.
struct SkillDetail: Equatable, Sendable {
    struct LinkedFile: Identifiable, Equatable, Sendable {
        var name: String
        var id: String { name }
    }

    var name: String
    var description: String
    var path: String
    var tags: [String]
    var linkedFiles: [LinkedFile]
    /// The body, with the front matter taken off — it is metadata, and the header
    /// above already shows the parts of it worth reading.
    var markdown: String

    init(json: JSONObject) {
        name = MoreJSON.text(json["name"])
        description = MoreJSON.text(json["description"])
        path = MoreJSON.text(json["skill_dir"])
        tags = MoreJSON.stringList(json["tags"])
        linkedFiles = MoreJSON.map(json["linked_files"]).keys.sorted().map { LinkedFile(name: $0) }
        markdown = Self.withoutFrontMatter(MoreJSON.text(json["content"]))
    }

    static func withoutFrontMatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return text }
        return lines[(close + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
