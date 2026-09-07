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
    }
}

// MARK: - Screens

/// The top-right menu. watchOS has no `Menu`, so it is a small pushed list —
/// which is also easier to hit on a wrist than a popover.
struct WatchMenuScreen: View {
    @ObservedObject var store: WatchMenuStore
    var onVoice: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                dismiss()
                onVoice()
            } label: {
                Label("Voice", systemImage: "waveform")
            }
            NavigationLink {
                WatchWearablesList(store: store)
            } label: {
                Label("Jarvis wearables", systemImage: "sensor")
            }
            NavigationLink {
                WatchChatPicker(store: store)
            } label: {
                Label("Chats", systemImage: "bubble.left")
            }
        }
        .navigationTitle("Menu")
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

struct WatchWearablesList: View {
    @ObservedObject var store: WatchMenuStore

    var body: some View {
        List {
            if store.wearables.isEmpty && !store.loading {
                Text(store.error ?? "No wearables paired.")
                    .font(.inter(12)).foregroundStyle(JcWatch.muted)
            }
            ForEach(store.wearables) { device in
                NavigationLink {
                    WatchWearableDetail(device: device, store: store)
                } label: {
                    WatchWearableRow(device: device)
                }
            }
        }
        .navigationTitle("Wearables")
        .task { store.loadWearables() }
    }
}

/// The identical row for every device — that uniformity IS the design.
private struct WatchWearableRow: View {
    let device: WatchWearable

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(device.connected ? JcWatch.accent : JcWatch.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.inter(14, .semibold)).lineLimit(1)
                Text(device.state).font(.inter(11)).foregroundStyle(JcWatch.muted)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One detail layout for all three: the same header, the same reading grid.
struct WatchWearableDetail: View {
    let device: WatchWearable
    @ObservedObject var store: WatchMenuStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: device.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(device.connected ? JcWatch.accent : JcWatch.muted)
                Text(device.state)
                    .font(.inter(12)).foregroundStyle(JcWatch.muted)

                let live = store.wearables.first { $0.id == device.id } ?? device
                if live.readings.isEmpty {
                    Text(live.connected ? "No readings yet." : "Not connected.")
                        .font(.inter(12)).foregroundStyle(JcWatch.muted)
                } else {
                    ForEach(live.readings) { reading in
                        HStack {
                            Text(reading.label).font(.inter(12)).foregroundStyle(JcWatch.muted)
                            Spacer()
                            Text(reading.value).font(.inter(14, .semibold))
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle(device.name)
        .task { store.loadWearables() }
    }
}
