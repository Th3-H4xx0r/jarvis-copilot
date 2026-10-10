import SwiftUI

/// One-time setup: link Tuya's cloud (only to fetch the hub's local key and its data points, and as
/// a backup), pick the hub, and choose the ESP32 at home that keeps a local line to it.
struct DoorAlarmSetupView: View {
    @ObservedObject private var store: DoorAlarmStore = .shared
    @State private var accessID = ""
    @State private var secret = ""
    @State private var region = "us"
    @State private var devices: [DoorAlarmAPI.CloudDevice] = []
    @State private var boards: [DoorAlarmAPI.Proxy] = []
    @State private var currentBoard: String?
    @State private var busy: String?
    @State private var message: String?

    private let api = DoorAlarmAPI()
    private static let regions = [("us", "Western America"), ("us-e", "Eastern America"), ("eu", "Central Europe"),
                                  ("eu-w", "Western Europe"), ("in", "India"), ("cn", "China"), ("sg", "Singapore")]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                steps
                credentials
                hubPicker
                proxyPicker
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 12)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Door alarm setup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.load()
            region = store.state?.setup.region ?? "us"
            if store.state?.setup.credentials == true { await loadDevices() }
            await loadBoards()
        }
    }

    private var steps: some View {
        CardGroup("Tuya cloud project (once)", footer: "Jarvis uses it to read the hub's settings and its local key, then talks to the hub through the ESP32 at home. It stays as a backup if the ESP32 is offline.") {
            Row {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Sign up at platform.tuya.com and create a Cloud project (Smart Home, data center: Western America).")
                    Text("2. Devices → Link App Account → scan the QR code with Smart Life (Me → ⊞ scan).")
                    Text("3. In the project, open the hub → set its control mode to “DP instruction”.")
                    Text("4. Message Service → enable it (the cloud backup feed).")
                    Text("5. Copy the Access ID and Access Secret from the project's Overview here.")
                }
                .font(.footnote)
            }
        }
    }

    private var credentials: some View {
        CardGroup("Credentials", footer: store.state?.setup.credentials == true
                  ? "Saved on your Jarvis server. Paste new ones to replace them." : "Stored on your Jarvis server, never on this phone.") {
            Row { TextField("Access ID", text: $accessID).textInputAutocapitalization(.never).autocorrectionDisabled() }
            RowDivider()
            Row { SecureField("Access Secret", text: $secret) }
            RowDivider()
            Row {
                Picker("Data center", selection: $region) {
                    ForEach(Self.regions, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            RowDivider()
            Button {
                Task { await saveCredentials() }
            } label: {
                Row { HStack { Text("Save and find my devices"); Spacer(); if busy == "creds" { ProgressView() } } }
            }
            .buttonStyle(.plain)
            .disabled(accessID.isEmpty || secret.isEmpty || busy != nil)
        }
    }

    @ViewBuilder private var hubPicker: some View {
        if !devices.isEmpty {
            CardGroup("Pick the hub", footer: "Smart Life calls it “Wireless Doorbell”.") {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { RowDivider() }
                    Button { Task { await pick(device) } } label: {
                        Row {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                    Text([device.product, device.category, device.online ? "online" : "offline"]
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if busy == device.id { ProgressView() }
                                else if store.state?.setup.hub == true, store.state?.hubName == device.name {
                                    Image(systemName: "checkmark").foregroundStyle(JcTheme.accent)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(busy != nil)
                }
            }
        }
    }

    private var proxyPicker: some View {
        CardGroup("ESP32 at home", footer: boards.isEmpty
                  ? "Flash a second ESP32 DevKit with the Jarvis firmware, pair it, and leave it plugged in on the hub's Wi-Fi. It shows here once connected."
                  : "The board keeps a local line to the hub and relays every door to Jarvis in a fraction of a second.") {
            ForEach(Array(boards.enumerated()), id: \.element.id) { index, board in
                if index > 0 { RowDivider() }
                Button { Task { await choose(board.id) } } label: {
                    Row {
                        HStack {
                            Text(board.name)
                            Spacer()
                            if busy == board.id { ProgressView() }
                            else if currentBoard == board.id { Image(systemName: "checkmark").foregroundStyle(JcTheme.accent) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy != nil || store.state?.setup.hub != true)
            }
            if boards.isEmpty {
                Row { Text("No ESP32 board connected").foregroundStyle(.secondary) }
            }
            if currentBoard != nil {
                RowDivider()
                Button(role: .destructive) { Task { await choose(nil) } } label: {
                    Row { Text("Stop using the ESP32").foregroundStyle(JcTheme.danger) }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Actions

    private func saveCredentials() async {
        busy = "creds"
        defer { busy = nil }
        do {
            try await api.saveCredentials(accessID: accessID.trimmingCharacters(in: .whitespaces),
                                          secret: secret.trimmingCharacters(in: .whitespaces), region: region)
            secret = ""
            message = "Linked. Pick the hub below."
            await loadDevices()
        } catch {
            message = apiErrorMessage(error)
        }
    }

    private func loadDevices() async {
        do {
            devices = try await api.cloudDevices()
        } catch {
            if !wasCancelled(error) { message = apiErrorMessage(error) }
        }
    }

    private func loadBoards() async {
        do {
            let found = try await api.proxies()
            boards = found.boards
            currentBoard = found.current
        } catch {
            if !wasCancelled(error) { message = apiErrorMessage(error) }
        }
    }

    private func pick(_ device: DoorAlarmAPI.CloudDevice) async {
        busy = device.id
        defer { busy = nil }
        do {
            _ = try await api.pick(device.id)
            message = "\(device.name) is the door alarm hub now."
            await store.load()
        } catch {
            message = apiErrorMessage(error)
        }
    }

    private func choose(_ boardID: String?) async {
        busy = boardID ?? "none"
        defer { busy = nil }
        do {
            try await api.setProxy(boardID)
            currentBoard = boardID
            message = boardID == nil ? "The ESP32 no longer talks to the hub." : "The ESP32 is connecting to the hub…"
            await store.load()
        } catch {
            message = apiErrorMessage(error)
        }
    }
}
