import SwiftUI

/// Picks what a ring gesture, a Control Center button or switch (and so a widget button) does:
/// an Ask Jarvis prompt on a chosen model or harness, or any action any device offers — found
/// with the search bar or in that device's section.
struct RingActionPicker: View {
    @ObservedObject private var devices = DeviceRegistry.shared
    let title: String
    let current: RingAction
    let onSave: (RingAction) -> Void
    /// Only Control Center buttons can skip Face ID; a ring gesture's picker doesn't offer it.
    var allowsSkipFaceID = true

    /// Any action Jarvis can run — a ring gesture's, a Control Center button's.
    init(title: String, current: RingAction, onSave: @escaping (RingAction) -> Void) {
        self.title = title
        self.current = current
        self.onSave = onSave
    }

    init(store: RingInputStore, input: RingInput) {
        self.init(title: input.label, current: store.action(for: input)) { store.set($0, for: input) }
        allowsSkipFaceID = false
    }

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var agent: AgentChoice?
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var boards: [ServerDevice] = []
    /// `onAppear` runs again on the way back from "Runs on": load the saved action only once.
    @State private var loaded = false

    private var sections: [ActionPickerSection] {
        ActionPickerIndex.sections(
            devices: devices.devices.map {
                ActionPickerDevice(id: $0.deviceID, model: type(of: $0).model, capabilities: $0.capabilities,
                             unavailable: $0.unavailableCapabilities)
            },
            serverDevices: boards)
    }

    var body: some View {
        let shown = ActionPickerIndex.filter(sections, query: query)
        ScrollView {
            VStack(spacing: 18) {
                if query.isEmpty { askJarvis }
                ForEach(shown) { section in sectionCard(section) }
                if shown.isEmpty && !query.isEmpty {
                    CardGroup { CardEmptyBlock("Nothing matches “\(query)”", symbol: "magnifyingglass") }
                }
                if query.isEmpty {
                    CardGroup("Off") {
                        Row { Button("Do nothing", role: .destructive) { save(.none) } }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search actions")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .task { boards = await ServerDevices.load() }
    }

    // MARK: Ask Jarvis

    private var askJarvis: some View {
        CardGroup("Ask Jarvis", footer: "Runs as a Jarvis turn with every tool it has — \"turn off the lights\", "
            + "\"text Mum I'm on my way\", \"what's my next meeting\". A button's replies go to its own chat.") {
            Row {
                TextField("What should Jarvis do?", text: $prompt, axis: .vertical)
                    .lineLimit(1...3)
            }
            RowDivider()
            NavigationLink {
                AgentChoicePage(title: "Runs on", pick: AgentPick(agent)) { agent = $0.choice }
            } label: {
                Row {
                    HStack {
                        Text("Runs on").foregroundStyle(JcTheme.text)
                        Spacer()
                        Text(AgentPick(agent).label).foregroundStyle(JcTheme.muted).lineLimit(1)
                        JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider()
            Row {
                Button("Use this prompt") { save(.prompt(prompt, agent: agent)) }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: Sections

    private func sectionCard(_ section: ActionPickerSection) -> some View {
        let open = !query.isEmpty || expanded.contains(section.id)
        return CardGroup {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    if expanded.contains(section.id) { expanded.remove(section.id) } else { expanded.insert(section.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    JcIcon(section.symbol).font(.system(size: 16)).foregroundStyle(JcAccent.color).frame(width: 24)
                    Text(section.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(JcTheme.text)
                    Spacer(minLength: 8)
                    if section.rows.contains(where: { $0.matches(current) }) {
                        JcIcon("checkmark.circle.fill").font(.caption).foregroundStyle(JcAccent.color)
                    }
                    Text("\(section.rows.count)").font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                    JcIcon("chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(JcTheme.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!query.isEmpty)
            if open {
                ForEach(section.rows) { row in
                    RowDivider()
                    rowView(row)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ActionPickerRow) -> some View {
        switch row.kind {
        case .pick(let action):
            Button { save(action) } label: { rowLabel(row, chevron: false) }
                .buttonStyle(.plain)
                .disabled(row.unavailable != nil)
        case .form(let form):
            NavigationLink { formView(form) } label: { rowLabel(row, chevron: true) }
                .buttonStyle(.plain)
                .disabled(row.unavailable != nil)
        }
    }

    private func rowLabel(_ row: ActionPickerRow, chevron: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(row.unavailable == nil ? JcTheme.text : JcTheme.muted)
                if !row.detail.isEmpty {
                    Text(row.detail).font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(2)
                }
                if let reason = row.unavailable {
                    Text(reason).font(.system(size: 11.5, weight: .medium)).foregroundStyle(JcTheme.amber)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.matches(current) {
                JcIcon("checkmark").font(.caption).foregroundStyle(JcAccent.color)
            } else if chevron {
                JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .opacity(row.unavailable == nil ? 1 : 0.6)
    }

    @ViewBuilder
    private func formView(_ form: ActionPickerForm) -> some View {
        switch form {
        case .catalogue(let option):
            CatalogueValueEditor(option: option, current: current, onSave: onSave)
        case .wearable(let deviceID, let model, let capability):
            RingWearableActionEditor(current: current, onSave: onSave, deviceID: deviceID, model: model,
                                     capability: capability)
        case .serverDevice(let deviceID, let name, let capability):
            RingWearableActionEditor(current: current, onSave: onSave, deviceID: deviceID, model: name,
                                     capability: capability, onServer: true)
        case .secure(let action):
            SecureActionEditor(action: action, current: current, onSave: onSave, allowsSkip: allowsSkipFaceID)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if case .prompt(let text, let choice) = current {
            prompt = text
            agent = choice
        }
        if let holding = sections.first(where: { $0.rows.contains { $0.matches(current) } }) {
            expanded.insert(holding.id)
        }
    }

    private func save(_ action: RingAction) {
        onSave(action)
        dismiss()
    }
}

/// A catalogue action's one value — a timer's minutes, a link, a Shortcut's name.
struct CatalogueValueEditor: View {
    let option: RingActionOption
    let current: RingAction
    let onSave: (RingAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        Form {
            if let note = option.note { Section { Text(note).font(.footnote) } }
            if let parameter = option.parameter {
                Section(parameter.title) {
                    TextField(parameter.placeholder, text: $value).autocorrectionDisabled()
                }
                Section {
                    Button("Save") {
                        onSave(.skill(id: option.id, arguments: [parameter.key: value]))
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationTitle(option.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if case .skill(let id, let arguments) = current, id == option.id, let key = option.parameter?.key {
                value = arguments[key] ?? ""
            } else {
                value = option.arguments[option.parameter?.key ?? ""] ?? ""
            }
        }
    }
}

/// Disarm, silence or a car command, with its Skip Face ID choice. Turning it on the first time
/// asks Face ID once, to register this iPhone's button key with the server.
struct SecureActionEditor: View {
    let action: RingAction
    let current: RingAction
    let onSave: (RingAction) -> Void
    var allowsSkip = true
    @Environment(\.dismiss) private var dismiss
    @State private var skip = false
    @State private var working = false
    @State private var error: String?

    private var title: String {
        switch action {
        case .door(let command, _): return "Door alarm: \(command.title)"
        case .car(let command, _): return CarButtonCommand.title(command)
        default: return "Action"
        }
    }

    var body: some View {
        Form {
            if allowsSkip {
                skipSection
            } else {
                Section { Text("Asks for Face ID each time: a notification asks — tap it.").font(.footnote) }
            }
            if let error { Section { Text(error).foregroundStyle(JcTheme.danger) } }
            Section {
                Button("Save") {
                    onSave(saved(skip: allowsSkip && skip))
                    dismiss()
                }
                .disabled(working)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            switch (action, current) {
            case (.door(let command, _), .door(let other, let was)) where command == other: skip = was
            case (.car(let command, _), .car(let other, let was)) where command == other: skip = was
            default: skip = false
            }
        }
    }

    private var skipSection: some View {
        Section {
            Toggle(skipLabel, isOn: Binding(get: { skip }, set: { turn($0) }))
                .disabled(working)
        } footer: {
            Text(skip
                 ? "Pressing this button in Control Center runs it straight away — anyone holding your "
                   + "iPhone could. On a widget, the ring, a Shortcut, Siri or Jarvis it still asks for Face ID."
                 : "Asks for Face ID each time. From Control Center or a widget, a notification asks — tap it.")
        }
    }

    /// An Arm button shows Disarm once armed: its switch is about that.
    private var skipLabel: String {
        switch action {
        case .door(.armHome, _), .door(.armAway, _), .door(.armNow, _), .door(.cancelArming, _):
            return "Disarm without Face ID"
        case .car(let command, _) where !CarButtonCommand.needsFaceID(command):
            return "Start without Face ID"
        default:
            return "Skip Face ID"
        }
    }

    private func saved(skip: Bool) -> RingAction {
        switch action {
        case .door(let command, _): return .door(command, skipFaceID: skip)
        case .car(let command, _): return .car(command: command, skipFaceID: skip)
        default: return action
        }
    }

    private func turn(_ on: Bool) {
        error = nil
        guard on, !ButtonKeyRegistration.isRegistered else { skip = on; return }
        working = true
        Task {
            do {
                try await ToyotaApprover.shared.registerButtonKey()
                skip = true
            } catch CarSignError.cancelled {
                skip = false
            } catch {
                skip = false
                self.error = apiErrorMessage(error)
            }
            working = false
        }
    }
}

/// A model-or-harness choice as the "Runs on" pages show it.
enum AgentPick: Equatable {
    /// A widget's buttons keep their own choice (widgets only).
    case buttonsOwn
    case sameAsDefault
    case harness(String)
    case model(id: String, provider: String?)

    init(_ choice: AgentChoice?) {
        switch choice {
        case nil: self = .sameAsDefault
        case .harness(let id)?: self = .harness(id)
        case .model(let id, let provider)?: self = .model(id: id, provider: provider)
        }
    }

    init(widget: WidgetAgent?) {
        switch widget {
        case nil: self = .buttonsOwn
        case .default?: self = .sameAsDefault
        case .harness(let id)?: self = .harness(id)
        case .model(let id, let provider)?: self = .model(id: id, provider: provider)
        }
    }

    var choice: AgentChoice? {
        switch self {
        case .buttonsOwn, .sameAsDefault: return nil
        case .harness(let id): return .harness(id)
        case .model(let id, let provider): return .model(id: id, provider: provider)
        }
    }

    var widgetAgent: WidgetAgent? {
        switch self {
        case .buttonsOwn: return nil
        case .sameAsDefault: return .default
        case .harness(let id): return .harness(id)
        case .model(let id, let provider): return .model(id: id, provider: provider)
        }
    }

    @MainActor
    var label: String {
        switch self {
        case .buttonsOwn: return "Each button's own"
        case .sameAsDefault: return HarnessStore.shared.sameAsDefaultTitle
        case .harness(let id): return HarnessStore.shared.harness(id)?.title ?? "A harness"
        case .model(let id, _): return id
        }
    }
}

/// "Same as default (Name)", the harnesses, then Single model — like the chat's harness sheet.
/// `forWidget` adds "Each button's own" first.
struct AgentChoicePage: View {
    let title: String
    let pick: AgentPick
    var forWidget = false
    let onPick: (AgentPick) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pickingModel = false
    @State private var pickedModel = false
    @State private var catalog: ModelCatalog?
    private var store: HarnessStore { HarnessStore.shared }

    var body: some View {
        List {
            Section {
                if forWidget { option(.buttonsOwn, "Each button's own", "Every button runs what it was set to") }
                option(.sameAsDefault, store.sameAsDefaultTitle, "Settings → Default sets it")
            }
            Section("Harnesses") {
                ForEach(store.harnesses.filter { $0.id != "single" }) { harness in
                    option(.harness(harness.id), harness.title, nil)
                }
            }
            Section {
                Button {
                    pickingModel = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Single model…").foregroundStyle(JcTheme.text)
                            if case .model(let id, _) = pick {
                                Text(id).font(.caption).foregroundStyle(JcTheme.muted)
                            }
                        }
                        Spacer()
                        if case .model = pick { JcIcon("checkmark").foregroundStyle(JcAccent.color) }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
        .sheet(isPresented: $pickingModel, onDismiss: { if pickedModel { dismiss() } }) {
            CatalogModelPickerSheet(title: "Model", catalog: catalog,
                                    selectedID: { if case .model(let id, _) = pick { return id } else { return nil } }(),
                                    showsAuto: false,
                                    load: { catalog = try? await BoardChat().models() },
                                    select: { model in
                                        guard let model else { return }
                                        onPick(.model(id: model.id, provider: model.providerID))
                                        // Back to the picker once the sheet has gone, not under it.
                                        pickedModel = true
                                        pickingModel = false
                                    })
        }
    }

    private func option(_ value: AgentPick, _ name: String, _ note: String?) -> some View {
        Button {
            onPick(value)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(JcTheme.text)
                    if let note { Text(note).font(.caption).foregroundStyle(JcTheme.muted) }
                }
                Spacer()
                if pick == value { JcIcon("checkmark").foregroundStyle(JcAccent.color) }
            }
        }
    }
}
