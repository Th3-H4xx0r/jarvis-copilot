import SwiftUI

/// What each tap, swipe and press on the ring runs. Replaces the ring's own
/// music/video/camera modes: Jarvis takes the input and runs your action instead.
struct RingInputsSection: View {
    @ObservedObject var store: RingInputStore
    let ready: Bool
    let sensitivity: Int?
    let onSensitivity: (Int) -> Void

    var body: some View {
        CardGroup("Ring inputs",
                  footer: "Every tap or swipe the ring sends runs what you set here. Watch the log below to "
                      + "see which one your ring sends for a given gesture.") {
            ForEach(Array(RingInput.allCases.enumerated()), id: \.element.id) { index, input in
                if index > 0 { RowDivider() }
                NavigationLink {
                    RingActionPicker(store: store, input: input)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(input.label).font(.subheadline)
                            Text(store.action(for: input).summary)
                                .font(.caption)
                                .foregroundStyle(store.action(for: input).isSet ? AnyShapeStyle(.secondary)
                                                                                : AnyShapeStyle(.tertiary))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
            if let sensitivity {
                RowDivider()
                Row {
                    Stepper("Gesture sensitivity \(sensitivity)",
                            value: Binding(get: { sensitivity }, set: onSensitivity), in: 0...10)
                }
                .disabled(!ready)
            }
        }
    }
}

/// Picks what one input does: a prompt Jarvis runs, or one of the phone's own actions.
struct RingActionPicker: View {
    @ObservedObject var store: RingInputStore
    let input: RingInput

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var selected: String?
    @State private var value = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                CardGroup("Ask Jarvis", footer: "Runs as a Jarvis turn with every tool it has — \"turn off the "
                    + "lights\", \"text Mum I'm on my way\", \"what's my next meeting\".") {
                    Row {
                        TextField("What should Jarvis do?", text: $prompt, axis: .vertical)
                            .lineLimit(1...3)
                    }
                    RowDivider()
                    Row {
                        Button("Use this prompt") { save(.prompt(prompt)) }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                ForEach(RingActionCatalogue.groups, id: \.self) { group in
                    CardGroup(group) {
                        let options = RingActionCatalogue.options.filter { $0.group == group }
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            if index > 0 { RowDivider() }
                            optionRow(option)
                        }
                    }
                }

                CardGroup("Off") {
                    Row {
                        Button("Do nothing", role: .destructive) { save(.none) }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle(input.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func optionRow(_ option: RingActionOption) -> some View {
        Row {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    selected = option.id
                    value = option.arguments[option.parameter?.key ?? ""] ?? ""
                    if option.parameter == nil { save(.skill(id: option.id, arguments: [:])) }
                } label: {
                    HStack {
                        Text(option.label).font(.subheadline)
                        Spacer(minLength: 0)
                        if isCurrent(option) {
                            Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let note = option.note, selected == option.id {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                if let parameter = option.parameter, selected == option.id {
                    HStack {
                        TextField(parameter.placeholder, text: $value)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button("Save") { save(.skill(id: option.id, arguments: [parameter.key: value])) }
                            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func isCurrent(_ option: RingActionOption) -> Bool {
        if case .skill(let id, _) = store.action(for: input) { return id == option.id }
        return false
    }

    private func load() {
        switch store.action(for: input) {
        case .prompt(let text):
            prompt = text
        case .skill(let id, let arguments):
            selected = id
            value = RingActionCatalogue.option(id)?.parameter.flatMap { arguments[$0.key] } ?? ""
        case .none:
            break
        }
    }

    private func save(_ action: RingAction) {
        store.set(action, for: input)
        dismiss()
    }
}
