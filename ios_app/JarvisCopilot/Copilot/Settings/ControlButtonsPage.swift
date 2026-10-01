import SwiftUI
import WidgetKit

/// A Control Center button as the app keeps it: what the widget sees, plus what it does.
struct ControlButton: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var symbol: String
    var action: RingAction
    /// A switch's action when turned off; `.none` runs `action` both ways.
    var offAction: RingAction = .none
    /// Goes in Control Center as a "Jarvis switch" that stays lit while on.
    var keepsState = false
    var isOn = false
    /// A switch's symbol while off; nil keeps `symbol`.
    var offSymbol: String?
    /// "#RRGGBB"; nil is the system's colour.
    var tint: String?
    var captionKind: Caption = .state
    var captionText = ""
    var lastResult: String?

    /// The line under a switch's name.
    enum Caption: String, Codable, CaseIterable {
        case none, state, lastResult, text

        var label: String {
            switch self {
            case .none: return "Nothing"
            case .state: return "On / Off"
            case .lastResult: return "What it last did"
            case .text: return "My own text"
            }
        }
    }

    init(id: String, name: String, symbol: String, action: RingAction) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.action = action
    }

    static func new() -> ControlButton {
        ControlButton(id: UUID().uuidString, name: "", symbol: "bolt.fill", action: .none)
    }

    /// The line the widget shows, worked out here so the widget never needs the action.
    var caption: String? {
        guard keepsState else { return nil }
        switch captionKind {
        case .none: return nil
        case .state: return isOn ? "On" : "Off"
        case .lastResult: return lastResult
        case .text: return captionText.isEmpty ? nil : captionText
        }
    }

    /// The wearable whose Keep Alive this button switches, if that is what it does.
    var keepAliveDevice: String? {
        guard case .skill(let id, _) = action, id.hasPrefix("keep_alive_") else { return nil }
        return String(id.dropFirst("keep_alive_".count))
    }

    // Older buttons have none of the state fields; the widget reads `caption`, which is
    // written but never read back.
    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, action, offAction, keepsState, isOn, offSymbol, tint, captionKind, captionText, lastResult
        case caption
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        action = try c.decodeIfPresent(RingAction.self, forKey: .action) ?? .none
        offAction = try c.decodeIfPresent(RingAction.self, forKey: .offAction) ?? .none
        keepsState = try c.decodeIfPresent(Bool.self, forKey: .keepsState) ?? false
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        offSymbol = try c.decodeIfPresent(String.self, forKey: .offSymbol)
        tint = try c.decodeIfPresent(String.self, forKey: .tint)
        captionKind = try c.decodeIfPresent(Caption.self, forKey: .captionKind) ?? .state
        captionText = try c.decodeIfPresent(String.self, forKey: .captionText) ?? ""
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(action, forKey: .action)
        try c.encode(offAction, forKey: .offAction)
        try c.encode(keepsState, forKey: .keepsState)
        try c.encode(isOn, forKey: .isOn)
        try c.encodeIfPresent(offSymbol, forKey: .offSymbol)
        try c.encodeIfPresent(tint, forKey: .tint)
        try c.encode(captionKind, forKey: .captionKind)
        try c.encode(captionText, forKey: .captionText)
        try c.encodeIfPresent(lastResult, forKey: .lastResult)
        try c.encodeIfPresent(caption, forKey: .caption)
    }
}

/// The buttons, kept in the App Group so the Control Center controls can list and draw them.
@MainActor
final class ControlButtonStore: ObservableObject {
    static let shared = ControlButtonStore()

    @Published private(set) var buttons: [ControlButton] = []

    private let defaults: UserDefaults
    private let reloadControls: () -> Void
    private let runAction: (RingAction) async -> String
    private let notify: (String, String) async -> Void
    private let keepAliveIsOn: (String) -> Bool
    private var keepAliveWatch: NSObjectProtocol?

    init(defaults: UserDefaults = ControlButtonShelf.defaults,
         reloadControls: @escaping () -> Void = {
             if #available(iOS 18.0, *) {
                 ControlCenter.shared.reloadControls(ofKind: ControlButtonShelf.controlKind)
                 ControlCenter.shared.reloadControls(ofKind: ControlButtonShelf.switchKind)
             }
         },
         runAction: @escaping (RingAction) async -> String = { await RingActionRunner.run($0) },
         notify: @escaping (String, String) async -> Void = { title, body in
             try? await DefaultNotifier().post(LocalNotificationRequest(title: title, body: body))
         },
         keepAliveIsOn: @escaping (String) -> Bool = { WearableKeepAlive.isOn($0) }) {
        self.defaults = defaults
        self.reloadControls = reloadControls
        self.runAction = runAction
        self.notify = notify
        self.keepAliveIsOn = keepAliveIsOn
        if let data = defaults.data(forKey: ControlButtonShelf.key),
           let stored = try? JSONDecoder().decode([ControlButton].self, from: data) {
            buttons = stored
        }
        // A Keep Alive switched anywhere — its own screen, Jarvis, a ring gesture — relights
        // the switches that show it.
        keepAliveWatch = NotificationCenter.default.addObserver(
            forName: .jcKeepAliveChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncKeepAlive() }
        }
    }

    func button(_ id: String) -> ControlButton? { buttons.first { $0.id == id } }

    /// Adds a new button or replaces the one with the same id.
    func save(_ button: ControlButton) {
        var button = button
        if let device = button.keepAliveDevice, button.keepsState { button.isOn = keepAliveIsOn(device) }
        if let index = buttons.firstIndex(where: { $0.id == button.id }) {
            buttons[index] = button
        } else {
            buttons.append(button)
        }
        persist()
    }

    func delete(_ id: String) {
        buttons.removeAll { $0.id == id }
        persist()
    }

    /// One press from Control Center. A Jarvis prompt's reply comes back as a notification —
    /// Control Center has nowhere to show it — and so does a failure; anything else is silent.
    /// A button that keeps its state flips it.
    func press(_ id: String) async {
        guard let button = button(id) else { return }
        if button.keepsState { return await set(id, !button.isOn) }
        let line = await runAction(button.action)
        record(id, line)
        await report(button, line)
    }

    /// A switch turned on or off. A Keep Alive switch sets exactly that state and shows what it
    /// really is; any other action runs and the switch keeps the state it was flipped to.
    func set(_ id: String, _ on: Bool) async {
        guard var button = button(id) else { return }
        var action = !on && button.offAction.isSet ? button.offAction : button.action
        if button.keepAliveDevice != nil, case .skill(let option, var arguments) = action {
            arguments["state"] = on ? "on" : "off"
            action = .skill(id: option, arguments: arguments)
        }
        let line = await runAction(action)
        button.isOn = button.keepAliveDevice.map(keepAliveIsOn) ?? on
        button.lastResult = line
        replace(button)
        await report(button, line)
    }

    /// Presses that landed in the widget extension while the app wasn't there to run them.
    func runPending() async {
        for entry in ControlButtonShelf.takePending(defaults: defaults) {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { await set(parts[0], parts[1] == "on") } else { await press(entry) }
        }
    }

    /// Relights the Keep Alive switches from the real setting.
    func syncKeepAlive() {
        var changed = false
        for index in buttons.indices {
            guard buttons[index].keepsState, let device = buttons[index].keepAliveDevice else { continue }
            let on = keepAliveIsOn(device)
            if buttons[index].isOn != on {
                buttons[index].isOn = on
                changed = true
            }
        }
        if changed { persist() }
    }

    private func record(_ id: String, _ line: String) {
        guard var button = button(id) else { return }
        button.lastResult = line
        replace(button)
    }

    private func replace(_ button: ControlButton) {
        guard let index = buttons.firstIndex(where: { $0.id == button.id }) else { return }
        buttons[index] = button
        persist()
    }

    private func report(_ button: ControlButton, _ line: String) async {
        JcLog.services.notice("control button \(button.name, privacy: .public): \(line, privacy: .public)")
        if case .prompt = button.action {
            await notify(button.name, line)
        } else if line.contains(" failed") || line.hasPrefix("unknown action") || line.contains("unavailable") {
            await notify(button.name, line)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(buttons) { defaults.set(data, forKey: ControlButtonShelf.key) }
        reloadControls()
    }

    /// Colours offered for a button's lit symbol; nil is the system's.
    static let tints: [String?] = [nil, String(format: "#%06X", JcAccent.hex), "#FF453A", "#FF9F0A", "#FFD60A",
                                   "#30D158", "#63E6E2", "#40C8E0", "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F"]
}

/// Settings → Control Center buttons: the buttons, and how to put them in Control Center.
struct ControlButtonsPage: View {
    @ObservedObject private var store = ControlButtonStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardGroup(footer: "In Control Center, tap +, add the \"Jarvis button\" control and pick which "
                    + "button it runs. Add it once for each button you want there.") {
                    if store.buttons.isEmpty {
                        Row { Text("No buttons yet").foregroundStyle(.secondary) }
                    }
                    ForEach(Array(store.buttons.enumerated()), id: \.element.id) { index, button in
                        if index > 0 { RowDivider() }
                        NavigationLink {
                            ControlButtonEditor(button: button)
                        } label: {
                            HStack(spacing: 12) {
                                JcIcon(button.symbol)
                                    .font(.body)
                                    .foregroundStyle(JcAccent.color)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(button.name).font(.subheadline)
                                    Text(button.action.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                }
                CardGroup {
                    NavigationLink {
                        ControlButtonEditor(button: .new())
                    } label: {
                        Row {
                            Label("Add a button", systemImage: "plus")
                                .foregroundStyle(JcAccent.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle("Control Center buttons")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One button: its name, its icon, what it does and whether it keeps a state.
struct ControlButtonEditor: View {
    @ObservedObject private var store = ControlButtonStore.shared
    @State private var draft: ControlButton
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(button: ControlButton) {
        _draft = State(initialValue: button)
    }

    private var isNew: Bool { store.button(draft.id) == nil }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.action.isSet
            && draft != store.button(draft.id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardGroup("Name") {
                    Row { TextField("e.g. Play / pause", text: $draft.name) }
                }
                CardGroup(draft.keepsState ? "When turned on" : "Action",
                          footer: "Anything a ring gesture can do: a phone or media action, a wearable's "
                            + "command, a Jarvis prompt, or switching a wearable's keep-alive.") {
                    actionRow(draft.action, empty: "Choose what it does") { draft.action = $0 }
                }
                if draft.keepsState && draft.keepAliveDevice == nil {
                    CardGroup("When turned off", footer: "Leave it empty to run the same action both ways.") {
                        actionRow(draft.offAction, empty: "Same as when turned on") { draft.offAction = $0 }
                        if draft.offAction.isSet {
                            RowDivider()
                            Row {
                                Button("Clear", role: .destructive) { draft.offAction = .none }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                CardGroup("State", footer: draft.keepsState
                          ? "Add it in Control Center as a \"Jarvis switch\": it stays lit while on, even after "
                            + "you close Control Center. A keep-alive switch always shows the real setting."
                          : "Add it in Control Center as a \"Jarvis button\".") {
                    Row { Toggle("Keep its state (lights up while on)", isOn: $draft.keepsState) }
                    if draft.keepsState {
                        RowDivider()
                        Row {
                            Picker("Line under the name", selection: $draft.captionKind) {
                                ForEach(ControlButton.Caption.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                        }
                        if draft.captionKind == .text {
                            RowDivider()
                            Row { TextField("e.g. Saving battery", text: $draft.captionText) }
                        }
                    }
                }
                CardGroup("Look") {
                    symbolRow(draft.keepsState ? "Icon when on" : "Icon", symbol: draft.symbol) { draft.symbol = $0 }
                    if draft.keepsState {
                        RowDivider()
                        symbolRow("Icon when off", symbol: draft.offSymbol ?? draft.symbol) { draft.offSymbol = $0 }
                    }
                    RowDivider()
                    Row { tints }
                }
                if !isNew {
                    CardGroup {
                        Row {
                            Button("Delete button", role: .destructive) { confirmDelete = true }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle(isNew ? "New button" : "Button")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.save(draft)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .confirmationDialog("Delete this button?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(draft.id)
                dismiss()
            }
        } message: {
            Text("A Control Center control pointed at it stops doing anything.")
        }
    }

    private func actionRow(_ action: RingAction, empty: String,
                           set: @escaping (RingAction) -> Void) -> some View {
        NavigationLink {
            RingActionPicker(title: draft.name.isEmpty ? "Action" : draft.name, current: action, onSave: set)
        } label: {
            Row {
                HStack {
                    Text(action.isSet ? action.summary : empty)
                        .foregroundStyle(action.isSet ? .primary : .secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func symbolRow(_ title: String, symbol: String, set: @escaping (String) -> Void) -> some View {
        NavigationLink {
            SymbolPicker(title: title, selection: symbol, onPick: set)
        } label: {
            Row {
                HStack {
                    Text(title)
                    Spacer(minLength: 8)
                    Image(systemName: symbol)
                        .foregroundStyle(ControlButtonInfo(id: "", name: "", symbol: "", tint: draft.tint).tintColor
                                         ?? JcAccent.color)
                    JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Colour")
            HStack(spacing: 8) {
                ForEach(ControlButtonStore.tints, id: \.self) { hex in
                    let color = ControlButtonInfo(id: "", name: "", symbol: "", tint: hex).tintColor
                    Button { draft.tint = hex } label: {
                        Circle()
                            .fill(color ?? Color.white.opacity(0.15))
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: draft.tint == hex ? 2 : 0))
                            .overlay { if hex == nil { Image(systemName: "circle.slash").font(.caption2) } }
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex ?? "System colour")
                }
            }
        }
    }
}

/// Every SF Symbol the phone has, searchable and by Apple's categories.
struct SymbolPicker: View {
    let title: String
    let selection: String
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var category: String?
    @Environment(\.dismiss) private var dismiss

    private var results: [SFSymbolCatalog.Symbol] { SFSymbolCatalog.search(query, category: category) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", icon: "square.grid.2x2", key: nil)
                        ForEach(SFSymbolCatalog.categories, id: \.key) { chip(Self.label($0.key), icon: $0.icon, key: $0.key) }
                    }
                    .padding(.horizontal, 16)
                }
                Text("\(results.count) symbols")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                    ForEach(results, id: \.name) { symbol in
                        Button {
                            onPick(symbol.name)
                            dismiss()
                        } label: {
                            Image(systemName: symbol.name)
                                .font(.title3)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(symbol.name == selection ? Color.black : Color.primary)
                                .background(symbol.name == selection ? JcAccent.color : Color.white.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol.name)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
        }
        .searchable(text: $query, prompt: "Search 7,000+ symbols")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chip(_ text: String, icon: String, key: String?) -> some View {
        Button { category = key } label: {
            Label(text, systemImage: icon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(category == key ? Color.black : Color.primary)
                .background(category == key ? JcAccent.color : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    static func label(_ key: String) -> String {
        let names = ["objectsandtools": "Objects & tools", "cameraandphotos": "Camera & photos",
                     "privacyandsecurity": "Privacy & security", "textformatting": "Text formatting"]
        return names[key] ?? key.prefix(1).uppercased() + key.dropFirst()
    }
}
