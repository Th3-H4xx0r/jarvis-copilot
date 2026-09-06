import SwiftUI

/// Everything that isn't part of using the bottle day to day: preferences, maintenance
/// commands, firmware identity and the raw BLE tooling. Kept off the main screen so it
/// stays a bottle and three buttons.
struct DeviceDetailsView: View {
    @ObservedObject var manager: BottleManager
    @AppStorage("temperatureUnit") private var tempUnit: TemperatureUnit = .celsius

    @StateObject private var bridge = BridgeClient.shared
    @State private var rawHex = ""
    @State private var screenSeconds = 5.0

    private var ready: Bool { manager.state == .ready }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                sharing
                preferences
                maintenance
                identity
                diagnostics
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Per-device opt-in. Server, pairing and bridge mode are app-level and live in
    /// Jarvis Copilot settings, reachable from the device list.
    @ViewBuilder private var sharing: some View {
        if let deviceID = manager.exposedDeviceID {
            CardGroup("Jarvis Copilot",
                      footer: bridge.isPaired
                          ? "Lets Jarvis read this bottle's state and run its commands."
                          : "Pair with a Jarvis Copilot server first — Settings on the "
                            + "device list.") {
                Row {
                    Toggle("Share with Jarvis", isOn: Binding(
                        get: { BridgeClient.isExposed(deviceID) },
                        set: { on in
                            BridgeClient.setExposed(on, for: deviceID)
                            manager.refreshRegistryMembership()
                        }))
                }
                .disabled(!bridge.isPaired)
            }
        }
    }

    @ViewBuilder private var preferences: some View {
        CardGroup("Preferences") {
            Row {
                HStack {
                    Text("Temperature")
                    Spacer(minLength: 12)
                    Picker("Temperature", selection: $tempUnit) {
                        ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            RowDivider()
            Row(minHeight: 66) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Screen timeout", value: "\(Int(screenSeconds))s")
                    Slider(value: $screenSeconds, in: 3...15, step: 1) { editing in
                        if !editing { manager.send(.setScreenSeconds(UInt8(screenSeconds))) }
                    }
                }
            }
            RowDivider()
            Row {
                Toggle("Clear stats daily at 24:00", isOn: Binding(
                    get: { manager.status?.dailyAutoReset ?? false },
                    set: { manager.send(.dailyAutoReset($0)) }))
            }
        }
        .disabled(!ready)
    }

    @ViewBuilder private var maintenance: some View {
        CardGroup("Maintenance") {
            Row {
                Button("Sync clock") { manager.send(.setClock(Date())) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            RowDivider()
            Row {
                Button(role: .destructive) {
                    // Puts every flag this app can set back to the bottle's defaults.
                    manager.send([.sterilise(false), .touchLock(false),
                                  .dailyAutoReset(false), .uvIntensity(.normal),
                                  .setScreenSeconds(5), .setClock(Date())])
                } label: {
                    Label("Restore safe defaults", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .disabled(!ready)
    }

    @ViewBuilder private var identity: some View {
        CardGroup("Device") {
            Row { LabeledContent("Connection", value: manager.state.text) }
            if let v = manager.version {
                RowDivider()
                Row { LabeledContent("Firmware", value: v.firmware) }
                RowDivider()
                Row { LabeledContent("Hardware", value: v.hardware) }
            }
            if let mac = manager.macAddress {
                RowDivider()
                Row { LabeledContent("MAC", value: mac).font(.body.monospaced()) }
            }
            if !manager.autoCleanSlots.isEmpty {
                RowDivider()
                Row {
                    LabeledContent("Auto-clean at",
                                   value: manager.autoCleanSlots.filter(\.isOn)
                                       .map(\.text).joined(separator: ", "))
                }
            }
            let reminders = manager.reminderSlots.filter(\.isOn)
            if !reminders.isEmpty {
                RowDivider()
                Row {
                    LabeledContent("Reminders",
                                   value: reminders.map(\.text).joined(separator: ", "))
                }
            }
        }
    }

    @ViewBuilder private var diagnostics: some View {
        CardGroup("Diagnostics",
                  footer: "Bytes are written verbatim to A301 — no framing or checksum.") {
            Row { Toggle("Live updates (3s poll)", isOn: $manager.liveUpdates) }
            if let raw = manager.status?.rawHex {
                RowDivider()
                Row(minHeight: 60) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Raw status frame").font(.caption).foregroundStyle(.secondary)
                        Text(raw).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            RowDivider()
            Row {
                let parsed = Data(hexString: rawHex)
                HStack {
                    TextField("e.g. 0E01", text: $rawHex)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                    Button("Send") {
                        if let parsed, !parsed.isEmpty {
                            manager.send(.raw(parsed))
                            rawHex = ""
                        }
                    }
                    .disabled(parsed?.isEmpty ?? true || !ready)
                }
            }
            ForEach(Array(manager.traffic.prefix(25).enumerated()), id: \.element.id) { _, entry in
                RowDivider()
                Row(minHeight: 46) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: entry.direction == .out
                              ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(entry.direction == .out ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.hex).font(.caption.monospaced())
                            Text(entry.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
