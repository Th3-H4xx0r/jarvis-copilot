import SwiftUI

/// Everything the create/edit form collects, so `TasksPage` hands one value to
/// `CronsStore.save(...)` instead of eight positional arguments.
struct CronFormValues {
    var prompt = ""
    var schedule = ""
    var name = ""
    var deliver = "local"
    var skills: Set<String> = []
    var model = ""
    var profile = ""
    var toastNotifications = true
}

/// Create or edit a scheduled task. `existing == nil` creates.
///
/// The deliver list is the known set plus whatever the job already had, so an
/// unrecognised channel from the server survives a round-trip through the form.
struct CronFormSheet: View {
    let existing: CronJob?
    /// Skills offered by the chip picker — the store's union of everything seen.
    let allSkills: [String]
    let onSave: (CronFormValues) async -> Bool

    @State private var form: CronFormValues

    init(existing: CronJob?, allSkills: [String],
         onSave: @escaping (CronFormValues) async -> Bool) {
        self.existing = existing
        self.allSkills = allSkills
        self.onSave = onSave
        var values = CronFormValues()
        if let existing {
            values.prompt = existing.prompt
            values.schedule = existing.schedule
            values.name = existing.name
            values.deliver = existing.deliver.isEmpty ? "local" : existing.deliver
            values.skills = Set(existing.skills)
            values.model = existing.model
            values.profile = existing.profile
            values.toastNotifications = existing.toastNotifications
        }
        _form = State(initialValue: values)
    }

    private var deliverOptions: [String] {
        var out = CronDeliver.options
        if !form.deliver.isEmpty && !out.contains(form.deliver) { out.append(form.deliver) }
        return out
    }

    /// The job's own skills stay selectable even when no other job uses them.
    private var skillChoices: [String] {
        Array(Set(allSkills).union(form.skills)).sorted()
    }

    var body: some View {
        FormSheet(title: existing == nil ? "New task" : "Edit task",
                  saveLabel: existing == nil ? "Create" : "Save",
                  onSave: { await onSave(form) }) {
            FormTextField(label: "Prompt", text: $form.prompt,
                          hint: "What should the agent do?", lineLimit: 4)
            FormTextField(label: "Schedule", text: $form.schedule,
                          hint: "e.g. every day at 9am, or */15 * * * *")
            FormTextField(label: "Name (optional)", text: $form.name)
            FormDropdown(label: "Deliver", selection: $form.deliver,
                         options: deliverOptions.map {
                             PickerOption($0, CronDeliver.label($0),
                                          symbol: CronDeliver.iconName($0))
                         },
                         sheetTitle: "Deliver results to")
            if !skillChoices.isEmpty {
                FormChipMulti(label: "Skills", all: skillChoices, selected: $form.skills)
            }
            FormTextField(label: "Model (optional)", text: $form.model)
            FormTextField(label: "Profile (optional)", text: $form.profile)
            FormToggle(label: "Completion toasts", isOn: $form.toastNotifications)
        }
    }
}
