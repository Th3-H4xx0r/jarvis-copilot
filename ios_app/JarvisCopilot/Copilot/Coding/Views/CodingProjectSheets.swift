import SwiftUI

/// Create a project — name + repo path (+ optional default branch). Mirrors the
/// WebUI's "+ Project" flow (`POST /api/coding/projects`).
struct CodingNewProjectSheet: View {
    let store: CodingStore

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var repo = ""
    @State private var branch = ""
    @State private var validation: String?

    var body: some View {
        CodingSheetShell(
            title: "New project",
            actionLabel: store.busyProjects ? "Creating…" : "Create project",
            actionSymbol: "folder.badge.plus",
            busy: store.busyProjects,
            error: validation ?? store.error,
            action: { Task { await create() } }
        ) {
            CodingTextField(label: "Project name", text: $name, hint: "My project")
            CodingDirSuggestField(label: "Repo path on the server", path: $repo,
                                  hint: "~/code/my-project", scope: "server",
                                  fetch: { await store.api.dirSuggest(path: $0, host: "server") })
            CodingTextField(label: "Default branch (optional)", text: $branch, hint: "main")
        }
    }

    private func create() async {
        let n = CodingUI.trim(name)
        let r = CodingUI.trim(repo)
        if n.isEmpty { validation = "A project name is required"; return }
        if r.isEmpty { validation = "A repo path is required"; return }
        validation = nil
        if await store.createProject(name: n, repoPath: r,
                                     defaultBranch: CodingUI.trim(branch)) != nil {
            dismiss()
        }
    }
}

/// Rename a project, toggle its cross-device sync (device + folder), edit its
/// default branch + ignore rules, or delete it. Mirrors the WebUI's project
/// settings panel (`POST /project/<id>`, `DELETE /project/<id>`).
struct CodingProjectSettingsSheet: View {
    let store: CodingStore
    let project: CodingProject

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var branch: String
    @State private var syncOn: Bool
    @State private var syncDevice: String
    @State private var syncPath: String
    @State private var ignore: String
    @State private var validation: String?
    @State private var confirmingDelete = false

    init(store: CodingStore, project: CodingProject) {
        self.store = store
        self.project = project
        _name = State(initialValue: project.name)
        _branch = State(initialValue: project.defaultBranch ?? "")
        _syncOn = State(initialValue: project.syncEnabled)
        _syncDevice = State(initialValue: project.deviceId ?? "")
        _syncPath = State(initialValue: project.syncDesktopPath ?? "")
        _ignore = State(initialValue: project.ignoreRules ?? "")
    }

    var body: some View {
        CodingSheetShell(
            title: "Project settings",
            subtitle: project.repoPath,
            actionLabel: store.busyProjects ? "Saving…" : "Save",
            busy: store.busyProjects,
            error: validation ?? store.error,
            secondary: (label: "Delete", symbol: "trash", action: { confirmingDelete = true }),
            action: { Task { await save() } }
        ) {
            CodingTextField(label: "Name", text: $name, hint: "Project name")
            CodingTextField(label: "Default branch (optional)", text: $branch, hint: "main")
            CodingToggleRow(title: "Sync this project with a desktop device",
                            subtitle: "Two-way file sync with a paired device.",
                            isOn: $syncOn)
            if syncOn {
                VStack(alignment: .leading, spacing: 6) {
                    CodingFieldLabel("Device")
                    PickerField(selection: $syncDevice,
                                options: CodingUI.deviceOptions(store.devices, selected: syncDevice),
                                hint: "Choose a device", sheetTitle: "Sync device")
                }
                CodingDirSuggestField(label: "Folder path on that device", path: $syncPath,
                                      hint: "~/code/your-project", scope: syncDevice,
                                      fetch: { await store.api.dirSuggest(path: $0, host: "desktop",
                                                                          deviceId: syncDevice) })
            }
            CodingTextField(label: "Ignore rules (optional, one per line)", text: $ignore,
                            hint: "node_modules/\n.venv/\n*.log", lines: 3)
        }
        .confirmationDialog("Delete project", isPresented: $confirmingDelete, titleVisibility: .visible) {
            if project.sessions.isEmpty {
                Button("Delete", role: .destructive) { Task { await delete(cascade: false) } }
            } else {
                Button("Keep sessions") { Task { await delete(cascade: false) } }
                Button("Delete all", role: .destructive) { Task { await delete(cascade: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(project.sessions.isEmpty
                 ? "Delete this project?"
                 : "This project has \(project.sessions.count) session(s). Delete and also STOP + remove its sessions, or keep them (they move to Ungrouped)?")
        }
    }

    private func save() async {
        let n = CodingUI.trim(name)
        if n.isEmpty { validation = "A project name is required"; return }
        validation = nil
        let ok = await store.updateProject(project.id, name: n,
                                           defaultBranch: CodingUI.trim(branch),
                                           syncEnabled: syncOn,
                                           syncDesktopPath: CodingUI.trim(syncPath),
                                           // Ignore rules are line-oriented — never trimmed.
                                           ignoreRules: ignore,
                                           deviceId: CodingUI.trim(syncDevice))
        if ok { dismiss() }
    }

    private func delete(cascade: Bool) async {
        if await store.deleteProject(project.id, cascade: cascade) { dismiss() }
    }
}

/// Per-session settings — skip-permissions, working directory and cross-device
/// sync. Port of `_SettingsSheet`.
struct CodingSessionSettingsSheet: View {
    let store: CodingStore
    let session: CodingSession

    @Environment(\.dismiss) private var dismiss
    @State private var skipPerms: Bool
    @State private var syncOn: Bool
    @State private var syncDevice: String
    @State private var syncPath: String
    @State private var cwd: String
    @State private var saving = false

    init(store: CodingStore, session: CodingSession) {
        self.store = store
        self.session = session
        _skipPerms = State(initialValue: session.skipPermissions)
        _syncOn = State(initialValue: session.sync?.enabled ?? false)
        _syncDevice = State(initialValue: session.sync?.device ?? "")
        _syncPath = State(initialValue: session.sync?.remotePath ?? "")
        _cwd = State(initialValue: session.cwd ?? "")
    }

    var body: some View {
        CodingSheetShell(
            title: "Session settings",
            actionLabel: saving ? "Saving…" : "Save settings",
            busy: saving,
            error: store.error,
            action: { Task { await save() } }
        ) {
            CodingReadOnlyRow(label: "Run on", value: session.host ?? "server")
            CodingReadOnlyRow(label: "Model", value: session.model ?? "server default")
            CodingTextField(label: "Working directory", text: $cwd, hint: "~/code/project")
            CodingToggleRow(title: "Dangerously skip permissions",
                            subtitle: "Autonomous — no approval prompts.",
                            isOn: $skipPerms)
            CodingToggleRow(title: "Sync with another device",
                            subtitle: (session.sync?.device ?? "").isEmpty
                                ? "Two-way file sync."
                                : "Device: \(session.sync!.device!)",
                            isOn: $syncOn)
            if syncOn {
                VStack(alignment: .leading, spacing: 6) {
                    CodingFieldLabel("Device")
                    PickerField(selection: $syncDevice,
                                options: CodingUI.deviceOptions(store.devices, selected: syncDevice),
                                hint: "Choose a device", sheetTitle: "Sync device")
                }
                CodingTextField(label: "Folder path on that device", text: $syncPath,
                                hint: "~/code/your-project")
            }
        }
    }

    private func save() async {
        saving = true
        let ok = await store.saveSettings(
            skipPermissions: skipPerms,
            sync: CodingSync(enabled: syncOn, device: CodingUI.trim(syncDevice),
                             remotePath: CodingUI.trim(syncPath)),
            cwd: CodingUI.trim(cwd))
        saving = false
        if ok { dismiss() }
    }
}
