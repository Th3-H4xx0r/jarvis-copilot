import SwiftUI

/// Everything configurable on the X5, plus device identity and the decoded log.
struct X5SettingsView: View {
    @ObservedObject var manager: X5Manager
    @ObservedObject private var session: X5Session
    @StateObject private var bridge = BridgeClient.shared

    @State private var error: String?
    @State private var confirmPowerOff = false
    @State private var confirmClear = false
    @State private var confirmForget = false
    @State private var showRawBytes = false
    @State private var healthRing = HealthRing.current
    @Environment(\.dismiss) private var dismiss

    init(manager: X5Manager) {
        self.manager = manager
        _session = ObservedObject(wrappedValue: manager.session)
    }

    private var ready: Bool { manager.state == .ready }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                sharing
                if HealthRing.bothPaired() { health }
                monitoring
                maintenance
                deviceInfo
                diagnostics
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle("X5 settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Power the X5 off?", isPresented: $confirmPowerOff, titleVisibility: .visible) {
            Button("Power off", role: .destructive) { apply { try await session.powerOff() } }
        } message: {
            Text("It turns back on when you put it on its charger.")
        }
        .confirmationDialog("Clear the ring's history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear ring history", role: .destructive) {
                apply {
                    try await session.clearHistory()
                    // The ring no longer holds the entries the cursors point at.
                    if let id = manager.deviceID { X5Cursors(deviceID: id).reset() }
                }
            }
        } message: {
            Text("Deletes what is stored on the ring. Everything already on this phone is kept.")
        }
        .confirmationDialog("Forget this X5?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget ring", role: .destructive) {
                Task {
                    await manager.forget()
                    dismiss()
                }
            }
        } message: {
            Text("Unpairs it from Jarvis. Its history stays on this phone.")
        }
    }

    private func apply(_ work: @escaping () async throws -> Void) {
        error = nil
        Task {
            do {
                guard await manager.ensureConnected(timeout: 12) else { throw DeviceError.notConnected }
                try await work()
            } catch {
                self.error = error.localizedDescription
            }
            manager.releaseIfIdle()
        }
    }

    // MARK: Sections

    @ViewBuilder private var sharing: some View {
        if let deviceID = manager.exposedDeviceID {
            CardGroup("Jarvis Copilot",
                      footer: bridge.isPaired ? "Lets Jarvis read this ring's data and run its commands."
                                              : "Pair with a Jarvis Copilot server first — Settings on the device list.") {
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
        CardGroup("Connection", footer: WearableKeepAliveToggle.footer) {
            Row {
                WearableKeepAliveToggle(device: WearableKeepAlive.x5ring) { on in
                    if on { Task { _ = await manager.ensureConnected(timeout: 10) } } else { manager.releaseIfIdle() }
                }
            }
        }
    }

    private var health: some View {
        CardGroup("Jarvis Health", footer: "Both rings keep their own history; Jarvis Health reads one.") {
            Row {
                Picker("Ring for Jarvis Health", selection: Binding(
                    get: { healthRing },
                    set: { ring in
                        healthRing = ring
                        HealthRing.choose(ring)
                    })) {
                    ForEach(HealthRing.allCases.filter { WearableIdentity.remembered($0.kind) != nil }) { Text($0.label).tag($0) }
                }
            }
        }
    }

    private var monitoring: some View {
        CardGroup("Automatic measurements", footer: "The ring measures on its own and keeps the readings until it syncs.") {
            ForEach(Array([X5MonitorType.heartRate, .spo2, .hrv].enumerated()), id: \.offset) { index, type in
                if index > 0 { RowDivider() }
                let schedule = session.monitoring[type] ?? X5Session.defaultMonitoring.first { $0.type == type }!
                NavigationLink {
                    X5MonitoringEditor(manager: manager, title: label(type), schedule: schedule)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(type)).font(.subheadline)
                            if let window = schedule.window, schedule.on {
                                Text(window).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(session.monitoring[type] == nil ? "—" : schedule.value)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
    }

    private func label(_ type: X5MonitorType) -> String {
        switch type {
        case .heartRate: return "Heart rate"
        case .hrv: return "HRV, stress & blood pressure"
        case .spo2: return "Blood oxygen"
        }
    }

    private var maintenance: some View {
        CardGroup("Maintenance") {
            Row {
                Button("Restart the ring") { apply { try await session.restart() } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            RowDivider()
            Row {
                Button("Clear ring history…", role: .destructive) { confirmClear = true }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            RowDivider()
            Row {
                Button("Power off…", role: .destructive) { confirmPowerOff = true }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            RowDivider()
            Row {
                Button("Forget this ring…", role: .destructive) { confirmForget = true }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(!ready)
    }

    private var deviceInfo: some View {
        CardGroup("This ring") {
            Row { LabeledContent("Model", value: X5Ring.model) }
            if let fw = session.firmware { RowDivider(); Row { LabeledContent("Firmware", value: fw.version) } }
            if let mac = session.mac { RowDivider(); Row { LabeledContent("MAC", value: mac) } }
            if let mv = session.millivolts, mv > 0 {
                RowDivider()
                Row { LabeledContent("Battery voltage", value: String(format: "%.2f V", Double(mv) / 1000)) }
            }
            RowDivider()
            Row {
                LabeledContent("Extra features",
                               value: session.features.isEmpty ? "None found" : session.features.map(\.label).sorted().joined(separator: ", "))
            }
        }
    }

    private var diagnostics: some View {
        CardGroup("What the ring said") {
            Row { Toggle("Show raw bytes", isOn: $showRawBytes) }
            ForEach(session.log.entries.prefix(40)) { entry in
                RowDivider()
                Row {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.title).font(.caption.weight(.medium))
                            Spacer()
                            Text(entry.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                        }
                        if !entry.detail.isEmpty { Text(entry.detail).font(.caption2).foregroundStyle(.secondary) }
                        if showRawBytes, entry.frame.cmd != 0 {
                            Text(entry.hex).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
