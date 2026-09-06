import SwiftUI

/// Launch a coding session — port of `_LaunchSheet`.
///
/// Launching INSIDE a project (`POST /project/<id>/session`) drops the worktree
/// toggle (project sessions inherit the project's repo) and treats a blank
/// working directory as "the project's repo_path". `project` fixes that choice
/// when the sheet was opened from a project header; opened from the fleet, the
/// picker offers it instead (the Flutter build could only reach an in-project
/// launch through the header "+").
struct CodingLaunchSheet: View {
    let store: CodingStore
    /// Non-nil pins the sheet to one project and hides the picker.
    var project: CodingProject?

    @Environment(\.dismiss) private var dismiss

    @State private var cwd: String
    @State private var title = ""
    @State private var model = ""
    @State private var prompt = ""
    @State private var host = "server"
    @State private var worktree = false
    @State private var skipPerms = false
    @State private var syncOn = false
    @State private var syncDevice = ""
    @State private var syncPath = ""
    @State private var pickedProject = ""
    @State private var validation: String?

    init(store: CodingStore, project: CodingProject? = nil) {
        self.store = store
        self.project = project
        _cwd = State(initialValue: project?.repoPath ?? "")
    }

    /// The project this launch targets: the pinned one, or whatever the picker
    /// selected.
    private var target: CodingProject? {
        project ?? store.projects.first { $0.id == pickedProject }
    }

    private var inProject: Bool { target != nil }

    private var projectOptions: [PickerOption<String>] {
        CodingUI.projectOptions(store.projects)
    }

    var body: some View {
        CodingSheetShell(
            title: target.map { "New session in “\($0.name)”" } ?? "Launch coding session",
            actionLabel: store.launching ? "Launching…" : "Launch",
            actionSymbol: "paperplane.fill",
            busy: store.launching,
            error: validation ?? store.error,
            action: { Task { await go() } }
        ) {
            if project == nil && !store.projects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    CodingFieldLabel("Project")
                    PickerField(selection: $pickedProject, options: projectOptions,
                                hint: "No project (ungrouped)", sheetTitle: "Project")
                }
                // Picking a project pre-fills its repo; clearing it takes the
                // suggestion back out so a hand-typed path is never clobbered.
                .onChange(of: pickedProject) { previous, next in
                    let was = store.projects.first { $0.id == previous }?.repoPath ?? ""
                    if CodingUI.trim(cwd).isEmpty || cwd == was {
                        cwd = store.projects.first { $0.id == next }?.repoPath ?? ""
                    }
                }
            }
            CodingDirSuggestField(
                label: inProject ? "Working directory (blank = project repo)" : "Working directory",
                path: $cwd,
                hint: "~/code/your-project  (~ expands, created if new)",
                scope: host,
                fetch: { await store.api.dirSuggest(path: $0, host: host) })

            CodingTextField(label: "Title (optional)", text: $title,
                            hint: "What are we building?")
            CodingTextField(label: "Model (optional)", text: $model,
                            hint: "e.g. claude-opus-4-8 (blank = server default)")

            VStack(alignment: .leading, spacing: 6) {
                CodingFieldLabel("Run on")
                CodingHostPicker(host: $host)
            }

            if !inProject {
                CodingToggleRow(title: "Run in an isolated git worktree",
                                subtitle: "Branches a fresh worktree from the directory above.",
                                isOn: $worktree)
            }
            CodingToggleRow(title: "Dangerously skip permissions",
                            subtitle: "Autonomous — no approval prompts.",
                            isOn: $skipPerms)
            CodingToggleRow(title: "Sync this project with another device",
                            subtitle: "Two-way file sync with a paired device.",
                            isOn: $syncOn)

            if syncOn { syncFields }

            CodingTextField(label: "Initial prompt", text: $prompt,
                            hint: "Describe the task for the coding agent…", lines: 3)
        }
    }

    private var syncFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                CodingFieldLabel("Device")
                PickerField(selection: $syncDevice,
                            options: CodingUI.deviceOptions(store.devices, selected: syncDevice),
                            hint: "Choose a device", sheetTitle: "Sync device")
            }
            CodingDirSuggestField(
                label: "Folder path on that device",
                path: $syncPath,
                hint: "~/code/your-project",
                scope: syncDevice,
                fetch: { await store.api.dirSuggest(path: $0, host: "desktop",
                                                    deviceId: syncDevice) })
            Text("On launch: a populated remote folder is pulled to the server; "
                 + "an empty one is pushed to. Two-way sync then keeps them in step.")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
        }
        .padding(.leading, 8)
    }

    private func go() async {
        let dir = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // In-project launches may leave cwd blank (the server defaults to repo_path).
        if !inProject && dir.isEmpty {
            validation = "A working directory is required"
            return
        }
        if task.isEmpty {
            validation = "An initial prompt is required"
            return
        }
        validation = nil
        let sync = syncOn ? CodingSync(enabled: true, device: syncDevice, remotePath: syncPath) : nil
        let session: CodingSession?
        if let target {
            session = await store.launchInProject(target.id,
                                                  cwd: dir.isEmpty ? nil : dir,
                                                  title: CodingUI.trim(title), prompt: task,
                                                  model: CodingUI.trim(model), host: host,
                                                  skipPermissions: skipPerms, sync: sync)
        } else {
            session = await store.launch(cwd: dir,
                                         // Send both keys so either server naming works.
                                         repoPath: dir, worktree: worktree,
                                         title: CodingUI.trim(title), prompt: task,
                                         model: CodingUI.trim(model), host: host,
                                         skipPermissions: skipPerms, sync: sync)
        }
        if session != nil { dismiss() }
    }
}
