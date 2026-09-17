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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let errorMessage {
                    CenteredMessage(text: errorMessage, color: JcTheme.danger) {
                        Task { await load() }
                    }
                    .padding(.top, 80)
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 100)
                } else if let skill {
                    summary(skill)
                    if !skill.linkedFiles.isEmpty { files(skill) }
                    body(skill)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .refreshable { await load() }
        .jcScreen(name)
        .task { if !loaded { await load() } }
    }

    private func summary(_ skill: SkillDetail) -> some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    JcIcon("sparkles", size: 16).foregroundStyle(JcTheme.accent).fixedSize()
                    Text(skill.name).font(JcText.label).foregroundStyle(JcTheme.text)
                    Spacer(minLength: 0)
                }
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !skill.tags.isEmpty {
                    JcWrap(spacing: 6, runSpacing: 6) {
                        ForEach(skill.tags, id: \.self) { tag in
                            StatusPill(tag, color: JcTheme.accent, dense: true)
                        }
                    }
                }
                if !skill.path.isEmpty {
                    Text(skill.path)
                        .font(JcText.small.monospaced())
                        .foregroundStyle(JcTheme.muted.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func files(_ skill: SkillDetail) -> some View {
        IntegrationSection(title: "Files", count: skill.linkedFiles.count) {
            InsetRows(skill.linkedFiles) { file in
                IntegrationRow(name: file.name, note: "", trailing: "") { EmptyView() }
            }
        }
    }

    /// The skill's own text — what it actually tells the agent — as markdown,
    /// through the same renderer a reply uses.
    private func body(_ skill: SkillDetail) -> some View {
        IntegrationSection(title: "What it says", count: 0) {
            GlassCard(padding: 14) {
                ChatMarkdownText(text: skill.markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
