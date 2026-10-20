import SwiftUI

/// His own states for a button: pick a live value to follow, then what the button shows and does
/// while it matches each state — "when bottle status is Sterilising: Stop sterilising".
struct ButtonStatesEditor: View {
    let onSave: (ButtonStates?) -> Void
    @State private var follows: String
    @State private var rules: [EditRule]
    @State private var countdownKey: String?
    @Environment(\.dismiss) private var dismiss

    /// A rule with an id of its own while it's edited, so removing one never shifts another's fields.
    private struct EditRule: Identifiable {
        let id = UUID()
        var rule: ButtonStates.Rule
    }

    init(states: ButtonStates?, onSave: @escaping (ButtonStates?) -> Void) {
        self.onSave = onSave
        _follows = State(initialValue: states?.follows ?? "")
        _rules = State(initialValue: (states?.rules ?? []).map { EditRule(rule: $0) })
        _countdownKey = State(initialValue: states?.countdownKey)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardGroup("Follows", footer: "Any live value a widget can show — the door alarm, the car, a "
                          + "wearable's status, your phone's battery…") {
                    valueRow(title: "Live value", key: follows.isEmpty ? nil : follows) { follows = $0 ?? "" }
                }
                ForEach(Array(rules.enumerated()), id: \.element.id) { offset, item in
                    ruleCard(item.id, number: offset + 1)
                }
                CardGroup {
                    Row {
                        Button {
                            rules.append(EditRule(rule: .init(when: rules.isEmpty ? .on : .otherwise, title: "",
                                                              symbol: "bolt.fill", action: .none)))
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
                    let kept = rules.map(\.rule)
                        .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && $0.action.isSet }
                    onSave(follows.isEmpty || kept.isEmpty
                           ? nil : ButtonStates(follows: follows, rules: kept, countdownKey: countdownKey))
                    dismiss()
                }
            }
        }
    }

    private func ruleCard(_ id: UUID, number: Int) -> some View {
        let rule = Binding<ButtonStates.Rule>(
            get: { rules.first { $0.id == id }?.rule ?? .init(when: .otherwise, title: "", symbol: "bolt.fill", action: .none) },
            set: { new in if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].rule = new } })
        let text: String = { if case .equals(let t) = rule.wrappedValue.when { return t } else { return "" } }()
        return CardGroup("State \(number)") {
            Row {
                Picker("When", selection: Binding(get: { MatchKind(rule.wrappedValue.when) },
                                                  set: { rule.wrappedValue.when = $0.match(text: text) })) {
                    ForEach(MatchKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            if case .equals = rule.wrappedValue.when {
                RowDivider()
                Row {
                    TextField("Value, e.g. Sterilising", text: Binding(
                        get: { text }, set: { rule.wrappedValue.when = .equals($0) }))
                        .autocorrectionDisabled()
                }
            }
            RowDivider()
            Row { TextField("Name it shows, e.g. Stop sterilising", text: rule.title) }
            RowDivider()
            NavigationLink {
                SymbolPicker(title: "Icon", selection: rule.wrappedValue.symbol) { rule.wrappedValue.symbol = $0 }
            } label: {
                Row {
                    HStack {
                        Text("Icon")
                        Spacer()
                        Image(systemName: rule.wrappedValue.symbol).foregroundStyle(JcAccent.color)
                        JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider()
            NavigationLink {
                RingActionPicker(title: "Action", current: rule.wrappedValue.action) { rule.wrappedValue.action = $0 }
            } label: {
                Row {
                    HStack {
                        Text("Does")
                        Spacer()
                        Text(rule.wrappedValue.action.isSet ? rule.wrappedValue.action.summary : "Choose")
                            .foregroundStyle(.secondary).lineLimit(1)
                        JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider()
            Row {
                Button("Remove this state", role: .destructive) { rules.removeAll { $0.id == id } }
            }
        }
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

/// His own icon for each state a button can show — Arm Away, Stop arming, Disarm, Silence; Lock and
/// Unlock; a wearable's on and off — used on the tile, widget buttons and the Lock Screen card.
struct StateIconsEditor: View {
    let button: ControlButton
    @Binding var symbols: [String: String]

    private var states: [ButtonLiveState] { ButtonStateResolver.possibleStates(button) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardGroup(footer: "Tap a state to choose its icon. States you leave keep the standard one.") {
                    ForEach(Array(states.enumerated()), id: \.element.id) { index, state in
                        if index > 0 { RowDivider() }
                        NavigationLink {
                            SymbolPicker(title: state.title, selection: symbols[state.id] ?? state.symbol) {
                                symbols[state.id] = $0 == state.symbol ? nil : $0
                            }
                        } label: {
                            Row {
                                HStack(spacing: 12) {
                                    Image(systemName: symbols[state.id] ?? state.symbol)
                                        .font(.system(size: 18))
                                        .foregroundStyle(state.alert ? JcTheme.danger : JcAccent.color)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(state.title).foregroundStyle(JcTheme.text)
                                        if let caption = state.caption {
                                            Text(caption).font(.caption).foregroundStyle(JcTheme.muted)
                                        }
                                    }
                                    Spacer()
                                    if symbols[state.id] != nil {
                                        Text("Changed").font(.caption).foregroundStyle(JcTheme.muted)
                                    }
                                    JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !symbols.isEmpty {
                    CardGroup {
                        Row {
                            Button("Use the standard icons", role: .destructive) { symbols = [:] }
                        }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle("State icons")
        .navigationBarTitleDisplayMode(.inline)
    }
}
