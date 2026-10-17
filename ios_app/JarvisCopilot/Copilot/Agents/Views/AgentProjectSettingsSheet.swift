import SwiftUI

/// A project's settings from a session's ••• menu: its name, whether its files
/// sync between the Mac and the server (what Continue on server needs), and
/// what stays out of the sync. Projects turn sync on by themselves when a
/// session runs in them; switching it off here is remembered, so it never
/// comes back on by itself (`POST /agents/project/sync`). Lifted from the old
/// Coding tab's project sheet.
struct AgentProjectSettingsSheet: View {
    let projectId: String
    let api: AgentsAPI

    @Environment(\.dismiss) private var dismiss
    @State private var project: CodingProject?
    @State private var loadError: String?
    @State private var name = ""
    @State private var syncOn = false
    @State private var ignore = ""
    @State private var error: String?

    var body: some View {
        Group {
            if let project {
                FormSheet(title: "Project settings", onSave: { await save(project) }) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let path = project.repoPath, !path.isEmpty {
                            Text(AgentsPresentation.shortPath(path))
                                .font(.system(size: 12))
                                .foregroundStyle(JcTheme.muted)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        FormTextField(label: "Name", text: $name, hint: "Project name")
                        Toggle(isOn: $syncOn) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sync with the server")
                                    .font(.system(size: 14)).foregroundStyle(JcTheme.text)
                                Text("Keeps the Mac’s folder and the server’s copy the same, so a session can continue on the server.")
                                    .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                            }
                        }
                        .tint(JcTheme.accent)
                        FormTextField(label: "Leave out of the sync (one per line)", text: $ignore,
                                      hint: "node_modules/\n.venv/\n*.log", lineLimit: 3)
                        if let error { CodingInlineError(message: error) }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    if let loadError {
                        CodingInlineError(message: loadError)
                        Button("Close") { dismiss() }
                            .buttonStyle(.jcGlass(tint: JcTheme.text))
                    } else {
                        ProgressView().tint(JcTheme.accent)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(JcTheme.surface)
                .presentationDetents([.medium])
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            guard let p = try await api.project(projectId) else {
                loadError = "This project isn’t on the server any more."
                return
            }
            name = p.name
            syncOn = p.syncEnabled
            ignore = p.ignoreRules ?? ""
            project = p
        } catch {
            if !wasCancelled(error) { loadError = apiErrorMessage(error) }
        }
    }

    private func save(_ p: CodingProject) async -> Bool {
        let n = jcTrim(name)
        guard !n.isEmpty else {
            error = "A project needs a name."
            return false
        }
        error = nil
        do {
            if n != p.name || ignore != (p.ignoreRules ?? "") {
                // Ignore rules are line-oriented — never trimmed.
                try await api.updateProject(p.id, name: n, ignoreRules: ignore)
            }
            if syncOn != p.syncEnabled {
                try await api.setProjectSync(p.id, on: syncOn)
            }
            return true
        } catch {
            self.error = apiErrorMessage(error)
            return false
        }
    }
}
