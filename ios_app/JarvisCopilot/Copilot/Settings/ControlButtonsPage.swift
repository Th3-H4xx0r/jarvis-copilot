import SwiftUI
import WidgetKit

/// A Control Center button as the app keeps it: what the widget sees, plus what it does.
struct ControlButton: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var symbol: String
    var action: RingAction

    static func new() -> ControlButton {
        ControlButton(id: UUID().uuidString, name: "", symbol: "bolt.fill", action: .none)
    }
}

/// The buttons, kept in the App Group so the Control Center control can list and draw them.
@MainActor
final class ControlButtonStore: ObservableObject {
    static let shared = ControlButtonStore()

    @Published private(set) var buttons: [ControlButton] = []

    private let defaults: UserDefaults
    private let reloadControls: () -> Void
    private let runAction: (RingAction) async -> String
    private let notify: (String, String) async -> Void

    init(defaults: UserDefaults = ControlButtonShelf.defaults,
         reloadControls: @escaping () -> Void = {
             if #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: ControlButtonShelf.controlKind) }
         },
         runAction: @escaping (RingAction) async -> String = { await RingActionRunner.run($0) },
         notify: @escaping (String, String) async -> Void = { title, body in
             try? await DefaultNotifier().post(LocalNotificationRequest(title: title, body: body))
         }) {
        self.defaults = defaults
        self.reloadControls = reloadControls
        self.runAction = runAction
        self.notify = notify
        if let data = defaults.data(forKey: ControlButtonShelf.key),
           let stored = try? JSONDecoder().decode([ControlButton].self, from: data) {
            buttons = stored
        }
    }

    func button(_ id: String) -> ControlButton? { buttons.first { $0.id == id } }

    /// Adds a new button or replaces the one with the same id.
    func save(_ button: ControlButton) {
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
    func press(_ id: String) async {
        guard let button = button(id) else { return }
        let line = await runAction(button.action)
        JcLog.services.notice("control button \(button.name, privacy: .public): \(line, privacy: .public)")
        if case .prompt = button.action {
            await notify(button.name, line)
        } else if line.contains(" failed") || line.hasPrefix("unknown action") || line.contains("unavailable") {
            await notify(button.name, line)
        }
    }

    /// Presses that landed in the widget extension while the app wasn't there to run them.
    func runPending() async {
        for id in ControlButtonShelf.takePending(defaults: defaults) { await press(id) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(buttons) { defaults.set(data, forKey: ControlButtonShelf.key) }
        reloadControls()
    }

    /// Icons offered for a button.
    static let symbols = [
        "bolt.fill", "sparkles", "atom", "play.fill", "playpause.fill", "forward.fill", "backward.fill",
        "speaker.wave.2.fill", "lightbulb.fill", "flashlight.on.fill", "house.fill", "moon.fill",
        "heart.fill", "waveform.path.ecg", "lungs.fill", "figure.walk", "camera.fill", "eyeglasses",
        "circle.circle", "antenna.radiowaves.left.and.right", "link", "bell.fill", "timer", "alarm.fill",
        "message.fill", "phone.fill", "car.fill", "music.note", "star.fill", "power",
    ]
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

/// One button: its name, its icon and what it does.
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
                CardGroup("Action", footer: "Anything a ring gesture can do: a phone or media action, a "
                    + "wearable's command, a Jarvis prompt, or switching a wearable's keep-alive.") {
                    NavigationLink {
                        RingActionPicker(title: draft.name.isEmpty ? "Action" : draft.name,
                                         current: draft.action) { draft.action = $0 }
                    } label: {
                        Row {
                            HStack {
                                Text(draft.action.isSet ? draft.action.summary : "Choose what it does")
                                    .foregroundStyle(draft.action.isSet ? .primary : .secondary)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                CardGroup("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(ControlButtonStore.symbols, id: \.self) { symbol in
                            Button { draft.symbol = symbol } label: {
                                Image(systemName: symbol)
                                    .font(.body)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .foregroundStyle(draft.symbol == symbol ? Color.black : Color.primary)
                                    .background(draft.symbol == symbol ? JcAccent.color : Color.white.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                        }
                    }
                    .padding(12)
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
}
