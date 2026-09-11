import SwiftUI

/// App-level Jarvis Copilot settings: which server, pairing, and whether the bridge runs
/// at all. Individual wearables opt in from their own settings screen.
struct BridgeSettingsView: View {
    @StateObject private var bridge = BridgeClient.shared
    /// Without observing this, the list never refreshes when a device is shared.
    @StateObject private var registry = DeviceRegistry.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                connection
                behaviour
                sharedDevices
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        // The port's screen chrome: the aurora behind a clear container and a
        // transparent inline bar, so this pushed screen matches the Settings page
        // it is reached from instead of sitting on flat system black. The scroll
        // container has to give up its own background for the aurora to show.
        .scrollContentBackground(.hidden)
        .jcScreen("Bridge")
    }

    // MARK: Connection

    @ViewBuilder private var connection: some View {
        CardGroup("Connection",
                  footer: nil) {
            Row {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bridge.status == .online ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(bridge.status.text).foregroundStyle(.secondary)
                    }
                }
            }

            RowDivider()
            Row { LabeledContent("Server", value: bridge.serverURL) }
            RowDivider()
            Row {
                LabeledContent("Commands shared", value: "\(bridge.registeredSkills)")
            }
            RowDivider()
            Row {
                Button("Unpair", role: .destructive) { bridge.unpair() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Behaviour

    @ViewBuilder private var behaviour: some View {
        CardGroup("Bridge",
                  footer: "Keeps the app, Bluetooth and the Jarvis link alive in the "
                        + "background so commands arrive instantly. Uses a silent audio "
                        + "session to stay awake, which costs some battery. Nothing is "
                        + "audible and your music is not interrupted.") {
            if let at = bridge.lastPushAt {
                Row {
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent("Last wake",
                                       value: at.formatted(date: .omitted, time: .standard))
                        Text(bridge.lastPushOutcome)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                RowDivider()
            }
            Row {
                Toggle("Bridge mode", isOn: Binding(
                    get: { bridge.enabled },
                    set: { on in
                        bridge.enabled = on
                        if on { bridge.connect() } else { bridge.disconnect() }
                    }))
            }
        }
    }

    // MARK: Shared devices

    /// Read-only mirror of what Jarvis can currently see. The opt-in itself lives in
    /// each wearable's own settings.
    @ViewBuilder private var sharedDevices: some View {
        let online = Dictionary(uniqueKeysWithValues:
            registry.devices.map { ($0.deviceID, $0) })
        let records = BridgeClient.sharedRecords.sorted { $0.key < $1.key }

        CardGroup("Shared with Jarvis",
                  footer: records.isEmpty
                      ? "Turn on \"Share with Jarvis\" in a wearable's settings to expose it."
                      : "Offline wearables stay listed — Jarvis sees them again as soon as "
                        + "the app reconnects.") {
            if records.isEmpty {
                Row { Text("Nothing shared").foregroundStyle(.secondary) }
            } else {
                ForEach(Array(records.enumerated()), id: \.element.key) { i, record in
                    if i > 0 { RowDivider() }
                    let device = online[record.key]
                    Row {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.value)
                                Text(device.map { "\($0.capabilities.count) commands" }
                                     ?? record.key)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(device != nil ? Color.green : Color.secondary)
                                    .frame(width: 6, height: 6)
                                Text(device != nil ? "Online" : "Offline")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
