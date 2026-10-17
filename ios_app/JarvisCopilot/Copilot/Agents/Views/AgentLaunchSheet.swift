import SwiftUI

/// "+" in the Agents tab: start a Claude Code or Codex session in a folder, on
/// the server or on a connected Mac (`POST /agents/launch`). It shows up in
/// the list from its own hooks a moment later. Lifted from the old Coding
/// tab's launch sheet; there is no tmux any more, so no worktree or title.
struct AgentLaunchSheet: View {
    let store: AgentsStore

    @Environment(\.dismiss) private var dismiss
    @State private var cwd = ""
    /// "server" or a Mac's device id.
    @State private var place = "server"
    @State private var agent = "claude"
    @State private var model = ""
    @State private var permissionMode = ""
    @State private var prompt = ""
    @State private var macs: [CodingDevice] = []
    @State private var error: String?
    @State private var launching = false

    static let permissionModes: [PickerOption<String>] = [
        PickerOption("", "Ask before acting (default)", symbol: "hand.raised"),
        PickerOption("acceptEdits", "Accept file edits", symbol: "pencil"),
        PickerOption("plan", "Plan first", symbol: "list.bullet"),
        PickerOption("bypassPermissions", "Skip all permission prompts", symbol: "exclamationmark.shield"),
    ]

    private var places: [(id: String, label: String)] {
        [("server", "Server")] + macs.filter(\.online).map { ($0.id, $0.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("New session")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(JcTheme.text)
                VStack(alignment: .leading, spacing: 6) {
                    FormFieldLabel("Run on")
                    AgentChoiceChips(options: places, selection: $place)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FormFieldLabel("Agent")
                    AgentChoiceChips(options: [("claude", "Claude Code"), ("codex", "Codex")], selection: $agent)
                }
                AgentDirSuggestField(
                    label: "Folder",
                    path: $cwd,
                    hint: place == "server" ? "~/codingprojects/your-project" : "~/code/your-project",
                    scope: place,
                    fetch: { await store.api.dirSuggest(path: $0, deviceId: place == "server" ? nil : place) })
                if agent == "claude" {
                    FormTextField(label: "Model (optional)", text: $model,
                                  hint: "Blank uses the default")
                    FormDropdown(label: "Permissions", selection: $permissionMode,
                                 options: Self.permissionModes, sheetTitle: "Permissions")
                }
                FormTextField(label: "First message (optional)", text: $prompt,
                              hint: "What should it work on?", lineLimit: 4)
                if let error {
                    CodingInlineError(message: error)
                }
                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.jcGlass(tint: JcTheme.text, full: true))
                        .disabled(launching)
                    Button {
                        Task { await launch() }
                    } label: {
                        if launching {
                            ProgressView().controlSize(.small).tint(JcTheme.accent)
                        } else {
                            Text("Start")
                        }
                    }
                    .buttonStyle(.jcGlass(full: true))
                    .disabled(launching)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .background(JcTheme.surface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { macs = (try? await store.api.desktops()) ?? [] }
    }

    private func launch() async {
        let dir = jcTrim(cwd)
        guard !dir.isEmpty else {
            error = "Pick a folder."
            return
        }
        error = nil
        launching = true
        defer { launching = false }
        let failure = await store.launch(cwd: dir, where: place, agent: agent,
                                         model: agent == "claude" ? jcTrim(model) : nil,
                                         permissionMode: agent == "claude" ? permissionMode : nil,
                                         prompt: jcTrim(prompt))
        if let failure { error = failure } else { dismiss() }
    }
}

/// A row of equal choices (where to run, which agent): the chosen one in the accent.
struct AgentChoiceChips: View {
    let options: [(id: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.id) { option in
                let selected = selection == option.id
                Button { selection = option.id } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? JcTheme.accent : JcTheme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .jcLiquidGlass(in: Capsule(), tint: selected ? JcTheme.accent.opacity(0.18) : .clear)
                        .overlay(Capsule().strokeBorder(selected ? JcTheme.accent.opacity(0.6) : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A text field that offers folders on the chosen machine as you type, and
/// drills in when one is tapped. `scope` is where it looks (the server or a
/// Mac's device id): changing it drops the stale list and asks again.
struct AgentDirSuggestField: View {
    let label: String
    @Binding var path: String
    var hint: String = ""
    let scope: String
    let fetch: (String) async -> [String]

    @State private var suggestions: [String] = []
    @State private var queryToken = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormFieldLabel(label)
            TextField(hint, text: $path)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .jcFieldStyle()
            if focused && !suggestions.isEmpty {
                suggestionList
            }
        }
        .onChange(of: path) { _, _ in queryToken += 1 }
        .onChange(of: focused) { _, isFocused in
            if isFocused { queryToken += 1 } else { suggestions = [] }
        }
        .onChange(of: scope) { _, _ in
            suggestions = []
            queryToken += 1
        }
        // `.task(id:)` cancels the previous lookup: both the debounce and the
        // stale-response guard. Only a focused field asks.
        .task(id: queryToken) {
            guard focused else { return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            if Task.isCancelled { return }
            let dirs = await fetch(path)
            if !Task.isCancelled { suggestions = dirs }
        }
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.prefix(6), id: \.self) { dir in
                Button { pick(dir) } label: {
                    HStack(spacing: 8) {
                        JcIcon("folder", size: 13).foregroundStyle(JcTheme.muted)
                        Text(CodingJSON.basename(dir))
                            .font(.system(size: 13)).foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(JcTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(JcTheme.border, lineWidth: 1))
    }

    private func pick(_ dir: String) {
        // The trailing separator makes the next query list the folder's children.
        path = dir.hasSuffix("/") ? dir : dir + "/"
        // Tapping the row can resign the field; keep drilling in.
        focused = true
    }
}
