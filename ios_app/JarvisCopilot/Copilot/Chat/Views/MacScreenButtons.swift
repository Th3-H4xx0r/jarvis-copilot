import Observation
import SwiftUI

// His own Control Center buttons on the Mac live view: "I want the live view page to be
// customizable so that I can add whatever buttons I want from the control center to show up
// on that page as I please." No second button system: the buttons are the ones in
// Settings → Control Center buttons (`ControlButtonStore`), and a tap goes through the same
// dispatch as a Control Center press. Only which ones show, and their order, is kept here.

// MARK: - Selection

/// Which Control Center buttons the live view shows, in his order. `order` is every button as
/// he last arranged them in the editor (so a row he dragged keeps its place while off);
/// `chosen` are the ones switched on. Ids of buttons deleted from Control Center drop out.
struct MacScreenButtonSelection: Codable, Equatable {
    var order: [String] = []
    var chosen: [String] = []

    static let key = "jc.macScreen.buttons"

    static func load(defaults: UserDefaults = ControlButtonShelf.defaults) -> MacScreenButtonSelection {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(MacScreenButtonSelection.self, from: data) else { return .init() }
        return stored
    }

    func save(defaults: UserDefaults = ControlButtonShelf.defaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    func isChosen(_ id: String) -> Bool { chosen.contains(id) }

    /// The editor's rows: every Control Center button, in his order; ones he never placed
    /// (made since) follow in Control Center's order.
    func rows(_ buttons: [ControlButton]) -> [ControlButton] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return buttons.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// What the live view shows: the chosen buttons that still exist, in his order.
    func visible(_ buttons: [ControlButton]) -> [ControlButton] {
        rows(buttons).filter { chosen.contains($0.id) }
    }

    mutating func set(_ id: String, on: Bool) {
        chosen.removeAll { $0 == id }
        if on { chosen.append(id) }
    }

    /// A drag in the editor: `rows` are the ids as the editor listed them.
    mutating func move(in rows: [String], from source: IndexSet, to destination: Int) {
        var ids = rows
        ids.move(fromOffsets: source, toOffset: destination)
        order = ids
    }

    /// Forgets buttons no longer in Control Center. True when anything was dropped.
    mutating func pruned(to buttons: [ControlButton]) -> Bool {
        let ids = Set(buttons.map(\.id))
        let before = self
        order.removeAll { !ids.contains($0) }
        chosen.removeAll { !ids.contains($0) }
        return self != before
    }
}

/// The live view's selection, shared by the row and the editor and saved on every change.
@MainActor
@Observable
final class MacScreenButtonsModel {
    static let shared = MacScreenButtonsModel()

    private(set) var selection: MacScreenButtonSelection
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = ControlButtonShelf.defaults) {
        self.defaults = defaults
        selection = .load(defaults: defaults)
    }

    func update(_ change: (inout MacScreenButtonSelection) -> Void) {
        var next = selection
        change(&next)
        guard next != selection else { return }
        selection = next
        next.save(defaults: defaults)
    }

    /// Quietly drops buttons deleted from Control Center.
    func prune(_ buttons: [ControlButton]) {
        var next = selection
        if next.pruned(to: buttons) { update { $0 = next } }
    }
}

// MARK: - The row

/// The chosen buttons as grey capsules (name + symbol), and Edit. Portrait: one scrolling row
/// under the Mac's picture. Landscape: a column in the rail's popover.
struct MacScreenButtonRow: View {
    enum Layout { case row, column }

    var layout: Layout = .row
    @ObservedObject private var store: ControlButtonStore
    private let model: MacScreenButtonsModel
    @State private var editing = false
    @State private var running: String?
    @State private var result: String?
    @State private var resultTask: Task<Void, Never>?

    init(layout: Layout = .row, store: ControlButtonStore = .shared, model: MacScreenButtonsModel = .shared) {
        self.layout = layout
        _store = ObservedObject(wrappedValue: store)
        self.model = model
    }

    var body: some View {
        let buttons = model.selection.visible(store.buttons)
        VStack(alignment: .leading, spacing: 6) {
            if let result {
                Text(result)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(2)
                    .padding(.horizontal, layout == .row ? 16 : 0)
                    .transition(.opacity)
            }
            if layout == .row {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) { capsules(buttons) }
                        .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) { capsules(buttons) }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.vertical, layout == .row ? 8 : 0)
        .animation(.easeOut(duration: 0.2), value: result)
        .onAppear { model.prune(store.buttons) }
        .onChange(of: store.buttons.map(\.id)) { _, _ in model.prune(store.buttons) }
        .sheet(isPresented: $editing) { MacScreenButtonsEditor(store: store, model: model) }
    }

    @ViewBuilder
    private func capsules(_ buttons: [ControlButton]) -> some View {
        ForEach(buttons) { button in
            let face = Self.face(for: button, at: .now)
            Button { run(button) } label: {
                HStack(spacing: 7) {
                    if running == button.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: face.symbol)
                    }
                    Text(face.title).lineLimit(1)
                }
            }
            .buttonStyle(MacCapsuleButtonStyle(alert: face.alert))
            .disabled(running == button.id)
            .accessibilityLabel(face.title)
        }
        Button { editing = true } label: {
            HStack(spacing: 7) {
                Image(systemName: buttons.isEmpty ? "plus" : "slider.horizontal.3")
                Text(buttons.isEmpty ? "Add buttons" : "Edit").lineLimit(1)
            }
        }
        .buttonStyle(MacCapsuleButtonStyle(alert: false, quiet: !buttons.isEmpty))
        .accessibilityLabel(buttons.isEmpty ? "Add Control Center buttons" : "Edit buttons")
    }

    /// What the tile shows: the live state's title and icon (as the Control Center tile does),
    /// or the button's own name and icon.
    static func face(for button: ControlButton, at date: Date) -> (title: String, symbol: String, alert: Bool) {
        if let live = button.timeline?.state(at: date) { return (live.title, live.symbol, live.alert) }
        let name = button.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Jarvis button" : name, button.symbol, false)
    }

    /// The press a tap sends: what Control Center would run, with the state this tile showed so
    /// a stale tile never runs a different action. Never `physical`: the skip-Face-ID button key
    /// belongs to his own Control Center press only, so the door and car ask for Face ID here.
    static func press(for button: ControlButton, at date: Date) -> ButtonPress {
        ButtonPress(buttonID: button.id, physical: false, shownState: button.timeline?.state(at: date)?.id)
    }

    private func run(_ button: ControlButton) {
        running = button.id
        let press = Self.press(for: button, at: .now)
        Task {
            await ControlButtonShelf.dispatch(press)
            running = nil
            if let line = store.button(button.id)?.lastResult, !line.isEmpty { show("\(button.name): \(line)") }
        }
    }

    private func show(_ line: String) {
        result = line
        resultTask?.cancel()
        resultTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { result = nil }
        }
    }
}

/// A grey capsule with a white label (the app's ordinary button, `JcButton`), dimmer pressed.
struct MacCapsuleButtonStyle: ButtonStyle {
    var alert = false
    /// Edit: a step quieter than his buttons.
    var quiet = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(alert ? JcTheme.danger : (quiet ? JcTheme.muted : JcButton.label))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .jcButtonSurface(in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? JcButton.pressedOpacity : (enabled ? 1 : JcButton.disabledOpacity))
    }
}

// MARK: - Editor

/// Edit: every Control Center button with a switch, dragged into the order they show.
struct MacScreenButtonsEditor: View {
    @ObservedObject private var store: ControlButtonStore
    private let model: MacScreenButtonsModel
    @Environment(\.dismiss) private var dismiss

    init(store: ControlButtonStore = .shared, model: MacScreenButtonsModel = .shared) {
        _store = ObservedObject(wrappedValue: store)
        self.model = model
    }

    var body: some View {
        let rows = model.selection.rows(store.buttons)
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text("No Control Center buttons yet. Make them in Settings → Control Center buttons.")
                        .font(.footnote)
                        .foregroundStyle(JcTheme.muted)
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(rows) { button in
                            row(button)
                        }
                        .onMove { source, destination in
                            model.update { $0.move(in: rows.map(\.id), from: source, to: destination) }
                        }
                    } header: {
                        JcSectionLabel("Control Center buttons", first: true)
                    } footer: {
                        Text("Switch on the ones to show under your Mac's screen. Drag to change their order.")
                            .font(.footnote)
                            .foregroundStyle(JcTheme.muted)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .environment(\.editMode, .constant(.active))
            .jcScreen("Live view buttons", header: .inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(.black)
        .onAppear { model.prune(store.buttons) }
    }

    private func row(_ button: ControlButton) -> some View {
        let face = MacScreenButtonRow.face(for: button, at: .now)
        return HStack(spacing: 12) {
            JcIconSquare(symbol: face.symbol)
            Text(button.name.isEmpty ? face.title : button.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle(button.name, isOn: Binding(get: { model.selection.isChosen(button.id) },
                                              set: { on in model.update { $0.set(button.id, on: on) } }))
                .labelsHidden()
                .toggleStyle(.jcSwitch)
        }
        .listRowBackground(JcTheme.surface)
    }
}
