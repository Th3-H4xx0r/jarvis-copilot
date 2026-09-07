import SwiftUI
import WatchConnectivity

/// Everything on the watch beyond the orb: the chat picker and the wearables.
///
/// The watch owns no data. It asks the phone, which answers from the very same
/// `WearablesHub` managers and `SessionsAPI` its own screens use, so a chat
/// picked here is the chat voice uses on the phone, and a bottle shown here is
/// the bottle the phone is connected to.
@MainActor
final class WatchMenuStore: ObservableObject {
    @Published var sessions: [WatchSession] = []
    @Published var selectedSessionID = ""
    @Published var wearables: [WatchWearable] = []
    @Published var loading = false
    @Published var error: String?
    /// The outcome of the last command, shown under the buttons.
    @Published var lastResult: String?

    func loadSessions() { request(["type": "sessions"]) { reply in
        self.sessions = (reply["sessions"] as? [[String: Any]] ?? []).map(WatchSession.init)
        self.selectedSessionID = reply["selected"] as? String ?? ""
    } }

    func loadWearables() { request(["type": "wearables"]) { reply in
        self.wearables = (reply["wearables"] as? [[String: Any]] ?? []).map(WatchWearable.init)
    } }

    func select(_ id: String) {
        selectedSessionID = id
        request(["type": "session_select", "id": id]) { _ in }
    }

    func startNewChat(_ done: @escaping () -> Void) {
        request(["type": "session_new"]) { reply in
            if let id = reply["id"] as? String { self.selectedSessionID = id }
            self.loadSessions()
            done()
        }
    }

    /// Ask the PHONE to bring the device up — the same thing saying "connect to
    /// my bottle" in chat does. A wearable that is merely out of the app's
    /// foreground should connect, not report failure.
    func connect(_ id: String) {
        request(["type": "wearable_connect", "id": id]) { _ in self.loadWearables() }
    }

    func run(_ action: WatchWearable.Action) {
        lastResult = nil
        request(["type": "wearable_invoke", "device": action.device, "action": action.name]) { reply in
            self.lastResult = (reply["ok"] as? Bool) == true ? "Done." : "Didn't work."
            self.loadWearables()
        }
    }

    private func request(_ message: [String: Any], _ handle: @escaping ([String: Any]) -> Void) {
        guard WCSession.isSupported() else { error = "Not paired."; return }
        // `sendMessage` before activation raises an exception and takes the app
        // down — this is what crashed the watch as soon as the menu opened.
        let session = WCSession.default
        guard session.activationState == .activated else {
            session.activate()
            error = "Connecting to your iPhone…"
            return
        }
        loading = true
        error = nil
        session.sendMessage(message) { reply in
            Task { @MainActor in
                self.loading = false
                if (reply["ok"] as? Bool) == false {
                    // Say what went wrong rather than showing an empty list.
                    self.error = reply["error"] as? String ?? "Couldn't load."
                    return
                }
                handle(reply)
            }
        } errorHandler: { _ in
            Task { @MainActor in
                self.loading = false
                self.error = "Open JarvisCopilot on your iPhone."
            }
        }
    }
}

struct WatchSession: Identifiable, Equatable {
    let id: String
    let title: String
    let messages: Int

    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""
        title = d["title"] as? String ?? "Untitled"
        messages = d["messages"] as? Int ?? 0
    }
}

/// Every wearable arrives in the same shape, so one row and one detail view
/// serve the bottle, the scale and the board alike.
struct WatchWearable: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let state: String
    let connected: Bool
    let readings: [Reading]
    let actions: [Action]

    /// One of the device's own commands, exactly as JARVIS sees it.
    struct Action: Identifiable, Equatable {
        let name: String
        let title: String
        let device: String
        var id: String { name }
    }

    struct Reading: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""
        name = d["name"] as? String ?? "Device"
        symbol = d["symbol"] as? String ?? "sensor"
        state = d["state"] as? String ?? ""
        connected = d["connected"] as? Bool ?? false
        readings = (d["readings"] as? [[String: Any]] ?? []).map {
            Reading(label: $0["label"] as? String ?? "",
                    value: $0["value"] as? String ?? "")
        }
        actions = (d["actions"] as? [[String: Any]] ?? []).map {
            Action(name: $0["name"] as? String ?? "",
                   title: $0["title"] as? String ?? "",
                   device: $0["device"] as? String ?? "")
        }
    }
}

// MARK: - Screens

/// The top-right menu: Voice, then the wearables themselves.
///
/// Everything is INLINE — no NavigationLink pushes. A watchOS scene provides a
/// navigation bar but not always a stack to push onto, and a row that silently
/// does nothing when tapped is worse than one more scroll. Tapping a device
/// expands its readings in place.
struct WatchMenuScreen: View {
    @ObservedObject var store: WatchMenuStore
    var onVoice: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                // Close this sheet first; presenting another from inside a
                // dismissing one is dropped.
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onVoice() }
            } label: {
                Label("Voice", systemImage: "waveform")
            }

            Section("Jarvis wearables") {
                if store.wearables.isEmpty {
                    Text(store.error ?? (store.loading ? "Loading…" : "No wearables paired."))
                        .font(.inter(12)).foregroundStyle(JcWatch.muted)
                }
                ForEach(store.wearables) { device in
                    NavigationLink {
                        WatchWearableScreen(device: device, store: store)
                    } label: {
                        WatchWearableRow(device: device)
                    }
                }
            }
        }
        .navigationTitle("Menu")
        .task { store.loadWearables() }
    }
}

/// The identical row for every device — that uniformity IS the design. Tapping
/// it reveals the same three-line reading list for each.
struct WatchWearableRow: View {
    let device: WatchWearable

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(device.connected ? JcWatch.accent : JcWatch.muted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.inter(14, .semibold)).lineLimit(1)
                Text(device.state).font(.inter(11)).foregroundStyle(JcWatch.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// One screen for every wearable: its readings, its own commands, and — when it
/// is not connected — a button that asks the phone to bring it up rather than
/// simply reporting "not connected".
struct WatchWearableScreen: View {
    let device: WatchWearable
    @ObservedObject var store: WatchMenuStore

    private var live: WatchWearable {
        store.wearables.first { $0.id == device.id } ?? device
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: live.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(live.connected ? JcWatch.accent : JcWatch.muted)
                    Text(live.state).font(.inter(12)).foregroundStyle(JcWatch.muted)
                }
                if !live.connected {
                    Button {
                        store.connect(live.id)
                    } label: {
                        Label(store.loading ? "Connecting…" : "Connect",
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(store.loading)
                }
            }

            if !live.readings.isEmpty {
                Section("Readings") {
                    ForEach(live.readings) { reading in
                        HStack {
                            Text(reading.label).font(.inter(12)).foregroundStyle(JcWatch.muted)
                            Spacer()
                            Text(reading.value).font(.inter(13, .semibold))
                        }
                    }
                }
            }

            if !live.actions.isEmpty {
                Section("Controls") {
                    ForEach(live.actions) { action in
                        Button(action.title) { store.run(action) }
                            .disabled(!live.connected || store.loading)
                    }
                }
            }

            if let result = store.lastResult {
                Text(result).font(.inter(11)).foregroundStyle(JcWatch.muted)
            }
            if let error = store.error {
                Text(error).font(.inter(11)).foregroundStyle(JcWatch.muted)
            }
        }
        .navigationTitle(live.name)
        .task { store.loadWearables() }
    }
}

struct WatchChatPicker: View {
    @ObservedObject var store: WatchMenuStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                store.startNewChat { dismiss() }
            } label: {
                Label("New chat", systemImage: "plus.bubble")
            }

            Section("Recent") {
                if store.sessions.isEmpty && !store.loading {
                    Text(store.error ?? "No chats yet.")
                        .font(.inter(12)).foregroundStyle(JcWatch.muted)
                }
                ForEach(store.sessions) { session in
                    Button {
                        store.select(session.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.inter(14, .semibold)).lineLimit(1)
                                Text("\(session.messages) messages")
                                    .font(.inter(11)).foregroundStyle(JcWatch.muted)
                            }
                            Spacer()
                            if session.id == store.selectedSessionID {
                                Image(systemName: "checkmark").foregroundStyle(JcWatch.accent)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Chat")
        .task { store.loadSessions() }
    }
}
