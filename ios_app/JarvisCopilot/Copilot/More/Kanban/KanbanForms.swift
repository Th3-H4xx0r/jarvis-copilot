import SwiftUI

/// Create / edit a task. `showsColumn` is the only difference between the two
/// forms — the edit path moves a task through the Move picker instead, because
/// the bridge rejects a direct write to `running`.
struct KanbanTaskFormSheet: View {
    let title: String
    let showsColumn: Bool
    /// `(title, body, column, assignee, priority) -> saved`.
    let onSave: (String, String, String, String, Int) async -> Bool

    @State private var taskTitle: String
    @State private var details: String
    @State private var column: String
    @State private var assignee: String
    @State private var priority: String

    init(title: String,
         showsColumn: Bool,
         task: KanbanTask? = nil,
         onSave: @escaping (String, String, String, String, Int) async -> Bool) {
        self.title = title
        self.showsColumn = showsColumn
        self.onSave = onSave
        _taskTitle = State(initialValue: task?.title ?? "")
        _details = State(initialValue: task?.body ?? "")
        // `running` is not a valid create target, so a task sitting in it opens
        // the form on the first manual column instead.
        let seed = task.map { Kanban.manualColumns.contains($0.status) ? $0.status : "todo" }
        _column = State(initialValue: seed ?? "todo")
        _assignee = State(initialValue: task?.assignee ?? "")
        let seedPriority = task?.priority ?? ""
        _priority = State(initialValue: seedPriority.isEmpty ? "0" : seedPriority)
    }

    var body: some View {
        FormSheet(title: title, onSave: {
            let parsed = Int(priority.trimmingCharacters(in: .whitespaces)) ?? 0
            return await onSave(taskTitle, details, column, assignee, parsed)
        }) {
            FormTextField(label: "Title", text: $taskTitle, hint: "What needs doing")
            FormTextField(label: "Description", text: $details, hint: "Optional", lineLimit: 4)
            if showsColumn {
                FormDropdown(label: "Column", selection: $column,
                             options: Kanban.manualColumns.map {
                                 PickerOption($0, Kanban.columnLabel($0),
                                              symbol: Kanban.columnIcon($0))
                             })
            }
            KanbanAssigneeField(assignee: $assignee)
            FormTextField(label: "Priority", text: $priority, hint: "0")
        }
    }
}

/// Create / rename a board.
struct KanbanBoardFormSheet: View {
    let title: String
    var nameHint: String = ""
    let onSave: (String, String) async -> Bool

    @State private var name: String
    @State private var note: String

    init(title: String, name: String = "", note: String = "", nameHint: String = "",
         onSave: @escaping (String, String) async -> Bool) {
        self.title = title
        self.nameHint = nameHint
        self.onSave = onSave
        _name = State(initialValue: name)
        _note = State(initialValue: note)
    }

    var body: some View {
        FormSheet(title: title, onSave: { await onSave(name, note) }) {
            FormTextField(label: title == "New board" ? "Title" : "Name",
                          text: $name, hint: nameHint)
            FormTextField(label: "Description", text: $note, hint: "Optional", lineLimit: 3)
        }
    }
}

/// A one-field prompt — the block reason and the quick comment. Ported from
/// `kanban_page.dart`'s `_promptText` dialog; a sheet here so it shares the
/// single-presentation routing the board uses everywhere else.
struct KanbanTextPromptSheet: View {
    let title: String
    let label: String
    var hint: String = ""
    let onSave: (String) async -> Bool

    @State private var text = ""

    var body: some View {
        FormSheet(title: title, saveLabel: "OK", onSave: { await onSave(text) }) {
            FormTextField(label: label, text: $text, hint: hint, lineLimit: 3)
        }
    }
}

/// Assignee picker sourced from the real JarvisCopilot profiles — the
/// dispatcher claims a task by activating its assignee profile, so a free-text
/// name that matches no profile will never auto-run.
///
/// Options are the profile names plus Unassigned and Custom…; a typed or legacy
/// value (a removed profile, say) survives through the Custom path. If the
/// profiles endpoint fails we degrade to a plain text field rather than
/// blocking the form.
struct KanbanAssigneeField: View {
    @Binding var assignee: String

    /// Sentinels, not names — a real profile can't contain these.
    private static let none = "__none__"
    private static let custom = "__custom__"

    @State private var names: [String] = []
    @State private var selection = KanbanAssigneeField.none
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                FormTextField(label: "Assignee", text: $assignee, hint: "Optional")
            } else if loading {
                VStack(alignment: .leading, spacing: 7) {
                    FormFieldLabel("Assignee")
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading profiles…")
                            .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                    }
                }
                .padding(.bottom, 16)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    FormDropdown(label: "Assignee", selection: $selection,
                                 options: options, sheetTitle: "Assign to profile")
                    if selection == Self.custom {
                        FormTextField(label: "Custom assignee", text: $assignee,
                                      hint: "Type a name")
                    }
                }
                .onChange(of: selection) { _, new in apply(new) }
            }
        }
        .task { await load() }
    }

    private var options: [PickerOption<String>] {
        var out = [PickerOption(Self.none, "Unassigned",
                                subtitle: "Sits in Ready — won't auto-run",
                                symbol: "person.slash")]
        out += names.map { PickerOption($0, $0, subtitle: "JarvisCopilot profile",
                                        symbol: "person.crop.circle") }
        out.append(PickerOption(Self.custom, "Custom…", subtitle: "Type a name",
                                symbol: "square.and.pencil"))
        return out
    }

    private func apply(_ new: String) {
        if new == Self.none {
            assignee = ""
        } else if new != Self.custom {
            assignee = new
        } else if names.contains(assignee.trimmingCharacters(in: .whitespaces)) {
            // Switching from a real profile to Custom starts from a blank name.
            assignee = ""
        }
    }

    private func load() async {
        guard loading else { return }
        do {
            let result = try await ProfilesAPI().list()
            var seen: [String] = []
            for profile in result.profiles {
                let name = profile.name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !seen.contains(name) { seen.append(name) }
            }
            names = seen
            let initial = assignee.trimmingCharacters(in: .whitespaces)
            if initial.isEmpty {
                selection = Self.none
            } else if seen.contains(initial) {
                selection = initial
            } else {
                selection = Self.custom
            }
            loading = false
        } catch {
            failed = true
            loading = false
        }
    }
}
