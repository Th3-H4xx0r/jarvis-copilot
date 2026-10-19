import SwiftUI

/// His own states for a button: pick a live value to follow, then what the button shows and does
/// while it matches each state — "when bottle status is Sterilising: Stop sterilising".
struct ButtonStatesEditor: View {
    let onSave: (ButtonStates?) -> Void
    @State private var follows: String
    @State private var rules: [ButtonStates.Rule]
    @State private var countdownKey: String?
    @Environment(\.dismiss) private var dismiss

    init(states: ButtonStates?, onSave: @escaping (ButtonStates?) -> Void) {
        self.onSave = onSave
        _follows = State(initialValue: states?.follows ?? "")
        _rules = State(initialValue: states?.rules ?? [])
        _countdownKey = State(initialValue: states?.countdownKey)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardGroup("Follows", footer: "Any live value a widget can show — the door alarm, the car, a "
                          + "wearable's status, your phone's battery…") {
                    valueRow(title: "Live value", key: follows.isEmpty ? nil : follows) { follows = $0 ?? "" }
                }
                ForEach(rules.indices, id: \.self) { index in
                    ruleCard(index)
                }
                CardGroup {
                    Row {
                        Button {
                            rules.append(.init(when: rules.isEmpty ? .on : .otherwise, title: "",
                                               symbol: "bolt.fill", action: .none))
                        } label: {
                            Label("Add a state", systemImage: "plus.circle.fill")
                        }
                        .disabled(follows.isEmpty)
                    }
                }
                CardGroup("Countdown", footer: "A live value holding an end time: the tile, the Lock Screen and the "
                          + "Dynamic Island count down to it.") {
                    valueRow(title: "Count down to", key: countdownKey) { countdownKey = $0 }
                }
                if !follows.isEmpty || !rules.isEmpty {
                    CardGroup {
                        Row {
                            Button("Remove my own states", role: .destructive) {
                                onSave(nil)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle("My own states")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    let kept = rules.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && $0.action.isSet }
                    onSave(follows.isEmpty || kept.isEmpty
                           ? nil : ButtonStates(follows: follows, rules: kept, countdownKey: countdownKey))
                    dismiss()
                }
            }
        }
    }

    private func ruleCard(_ index: Int) -> some View {
        CardGroup("State \(index + 1)") {
            Row {
                Picker("When", selection: Binding(get: { MatchKind(rules[index].when) },
                                                  set: { rules[index].when = $0.match(text: matchText(index)) })) {
                    ForEach(MatchKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            if case .equals = rules[index].when {
                RowDivider()
                Row {
                    TextField("Value, e.g. Sterilising", text: Binding(
                        get: { matchText(index) }, set: { rules[index].when = .equals($0) }))
                        .autocorrectionDisabled()
                }
            }
            RowDivider()
            Row { TextField("Name it shows, e.g. Stop sterilising", text: $rules[index].title) }
            RowDivider()
            NavigationLink {
                SymbolPicker(title: "Icon", selection: rules[index].symbol) { rules[index].symbol = $0 }
            } label: {
                Row {
                    HStack {
                        Text("Icon")
                        Spacer()
                        Image(systemName: rules[index].symbol).foregroundStyle(JcAccent.color)
                        JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider()
            NavigationLink {
                RingActionPicker(title: "Action", current: rules[index].action) { rules[index].action = $0 }
            } label: {
                Row {
                    HStack {
                        Text("Does")
                        Spacer()
                        Text(rules[index].action.isSet ? rules[index].action.summary : "Choose")
                            .foregroundStyle(.secondary).lineLimit(1)
                        JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider()
            Row {
                Button("Remove this state", role: .destructive) { rules.remove(at: index) }
            }
        }
    }

    private func matchText(_ index: Int) -> String {
        if case .equals(let text) = rules[index].when { return text }
        return ""
    }

    private func valueRow(title: String, key: String?, set: @escaping (String?) -> Void) -> some View {
        NavigationLink {
            LiveValuePicker(selected: key, onPick: set)
        } label: {
            Row {
                HStack {
                    Text(title)
                    Spacer()
                    Text(key.map { WidgetDataCatalog.entry($0)?.label ?? $0 } ?? "None")
                        .foregroundStyle(.secondary).lineLimit(1)
                    JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The match kinds as the picker lists them.
    enum MatchKind: CaseIterable {
        case on, off, equals, otherwise

        init(_ match: ButtonStates.Match) {
            switch match {
            case .on: self = .on
            case .off: self = .off
            case .equals: self = .equals
            case .otherwise: self = .otherwise
            }
        }

        var label: String {
            switch self {
            case .on: return "It's on"
            case .off: return "It's off"
            case .equals: return "It is…"
            case .otherwise: return "Anything else"
            }
        }

        func match(text: String) -> ButtonStates.Match {
            switch self {
            case .on: return .on
            case .off: return .off
            case .equals: return .equals(text)
            case .otherwise: return .otherwise
            }
        }
    }
}

/// Every live value a widget can show, grouped by area and searchable.
struct LiveValuePicker: View {
    let selected: String?
    let onPick: (String?) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var entries: [WidgetDataCatalog.Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return WidgetDataCatalog.entries.filter { entry in
            words.allSatisfy { "\(entry.label) \(entry.key)".lowercased().contains($0) }
        }
    }

    var body: some View {
        List {
            Section {
                Button("None") {
                    onPick(nil)
                    dismiss()
                }
            }
            ForEach(Array(Set(entries.map(\.area))).sorted(), id: \.self) { area in
                Section(area.capitalized) {
                    ForEach(entries.filter { $0.area == area }) { entry in
                        Button {
                            onPick(entry.key)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label).foregroundStyle(JcTheme.text)
                                    Text(entry.key).font(.caption).foregroundStyle(JcTheme.muted)
                                }
                                Spacer()
                                if entry.key == selected { JcIcon("checkmark").foregroundStyle(JcAccent.color) }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search live values")
        .navigationTitle("Live value")
        .navigationBarTitleDisplayMode(.inline)
    }
}
