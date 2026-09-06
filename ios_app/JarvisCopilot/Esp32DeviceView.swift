import SwiftUI

struct Esp32DeviceView: View {
    @ObservedObject var manager: Esp32Manager
    let board: DiscoveredEsp32

    @StateObject private var bridge = BridgeClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingWifiSheet = false
    @State private var preference: Esp32LinkPreference = .auto
    @State private var linking = false
    @State private var linkMessage: String?

    private var ready: Bool { manager.state == .ready }
    /// While a script owns the pins, manual controls step aside.
    private var scriptRunning: Bool { manager.script?.state == .running }
    private var blue: Color { Color(red: 0.30, green: 0.62, blue: 1.0) }
    private var green: Color { Color(red: 0.29, green: 0.82, blue: 0.49) }
    private var red: Color { Color(red: 1.0, green: 0.31, blue: 0.27) }

    /// The stable ID once the handshake has run; the card's ID before that.
    private var deviceID: String { manager.info?.deviceID ?? board.record?.deviceID ?? board.id }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                if let error = manager.lastError { errorBanner(error) }
                quickActions
                program
                connection
                pins
                consoleCard
                sharing
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(board.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            preference = Esp32Manager.linkPreference(for: deviceID)
            if manager.connected?.id != board.id { manager.connect(board) }
        }
        // Leaving the screen keeps the session: only the Disconnect button ends it.
        .sheet(isPresented: $showingWifiSheet) {
            Esp32WifiSheet(manager: manager)
        }
        .alert("Jarvis link", isPresented: Binding(get: { linkMessage != nil }, set: { if !$0 { linkMessage = nil } })) {
            Button("OK") { linkMessage = nil }
        } message: {
            Text(linkMessage ?? "")
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                manager.perform { try await manager.refreshState(); try await manager.refreshWifi() }
            }
            .disabled(!ready)
            Button("Disconnect", systemImage: "xmark.circle") {
                manager.disconnect()
                dismiss()
            }
            .disabled(manager.connected?.id != board.id)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(blue.opacity(0.12)).frame(width: 120, height: 120)
                Image(systemName: "cpu")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(blue)
                    .symbolEffect(.pulse, isActive: manager.state == .connecting || manager.state == .discovering)
            }
            .padding(.top, 8)

            Text(manager.state.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                if let link = manager.activeLink {
                    MetricPill(icon: link.icon, label: "Link", value: link.label, tint: ready ? green : .orange)
                }
                if let info = manager.info {
                    MetricPill(icon: "number", label: "Firmware", value: info.firmwareString, tint: blue)
                    MetricPill(icon: "clock", label: "Up", value: uptimeText(info.uptimeSeconds), tint: blue)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func uptimeText(_ s: UInt32) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 0) {
            ActionButton(title: manager.ledOn ? "LED on" : "LED off",
                         icon: "lightbulb.fill",
                         isOn: manager.ledOn,
                         tint: blue) {
                let target = !manager.ledOn
                manager.perform { try await manager.setLED(target) }
            }
            .disabled(scriptRunning)
            .opacity(scriptRunning ? 0.4 : 1)
            ActionButton(title: manager.ledBlinking ? "Blinking" : "Blink",
                         icon: "sparkles",
                         isOn: manager.ledBlinking,
                         tint: green) {
                if manager.ledBlinking {
                    manager.perform { try await manager.stopBlink() }
                } else {
                    manager.perform { try await manager.blinkLED(count: 5, periodMs: 300) }
                }
            }
            .disabled(scriptRunning)
            .opacity(scriptRunning ? 0.4 : 1)
            ActionButton(title: "All off",
                         icon: "power",
                         isOn: false,
                         tint: red) {
                manager.perform { try await manager.allOff() }
            }
        }
        .disabled(!ready)
        .opacity(ready ? 1 : 0.4)
        .padding(.horizontal, 8)
    }

    // MARK: Program

    private var program: some View {
        VStack(spacing: 22) {
            CardGroup("Program") {
                NavigationLink {
                    Esp32ChatView(manager: manager, board: board)
                } label: {
                    Row {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                            Text("Program with Jarvis")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(!ready)
            }
            scriptCard
        }
    }

    /// What is running on the board right now: name, state, the summary Jarvis wrote
    /// at the top of the script, and the controls to pause or clear it.
    private var scriptCard: some View {
        CardGroup("Script") {
            if let s = manager.script, s.state != .none {
                Row(minHeight: 56) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "scroll.fill")
                            .foregroundStyle(scriptTint(s.state))
                            .frame(width: 26, height: 26)
                            .background(scriptTint(s.state).opacity(0.16), in: Circle())
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(s.name.isEmpty ? "Script" : s.name).font(.headline)
                                Spacer()
                                Text(s.state.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(scriptTint(s.state))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(scriptTint(s.state).opacity(0.14), in: Capsule())
                            }
                            if let info = manager.scriptInfo, info.name == s.name, !info.summary.isEmpty {
                                Text(info.summary).font(.subheadline).foregroundStyle(.secondary)
                                Text(info.installedAt.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            if !s.error.isEmpty {
                                Text(s.error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
                RowDivider()
                Row {
                    HStack(spacing: 22) {
                        if s.state == .running {
                            Button { manager.perform { try await manager.stopScript() } } label: { Label("Pause", systemImage: "pause.fill") }
                        } else {
                            Button { manager.perform { try await manager.startScript() } } label: { Label("Start", systemImage: "play.fill") }
                        }
                        Button(role: .destructive) {
                            manager.perform { try await manager.deleteScript() }
                        } label: { Label("Clear", systemImage: "trash") }
                        Spacer()
                    }
                    .font(.subheadline)
                }
            } else {
                Row {
                    HStack(spacing: 12) {
                        Image(systemName: "scroll").foregroundStyle(.secondary)
                        Text("No script").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(!ready)
    }

    private func scriptTint(_ state: Esp32Protocol.ScriptState) -> Color {
        switch state {
        case .running:  return green
        case .error:    return red
        case .finished: return blue
        default:        return .orange
        }
    }

    // MARK: Connection

    private var wifiValue: String {
        guard let w = manager.wifi else { return "—" }
        switch w.state {
        case .off:        return "Not set up"
        case .connecting: return "Joining…"
        case .failed:     return "Can't join"
        case .connected:  return w.ssid.isEmpty ? "Connected" : w.ssid
        }
    }

    private var wifiDetail: String? {
        guard let w = manager.wifi, w.state == .connected else {
            if let w = manager.wifi, w.state == .failed, !w.ssid.isEmpty { return "Check the password for \(w.ssid) and that it is a 2.4 GHz network." }
            return nil
        }
        return [w.ip, "\(w.rssi) dBm", w.hostname.isEmpty ? nil : "\(w.hostname).local"].compactMap { $0 }.joined(separator: " · ")
    }

    private var connection: some View {
        VStack(spacing: 22) {
            CardGroup("Network") {
                Row {
                    HStack {
                        Text("Prefer")
                        Spacer(minLength: 12)
                        Picker("Prefer", selection: $preference) {
                            ForEach(Esp32LinkPreference.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
                RowDivider()
                DetailRow(icon: "wifi", tint: manager.wifi?.state == .connected ? green : .secondary,
                          title: "Wi‑Fi", value: wifiValue, detail: manager.wifi?.state == .connected ? manager.wifi?.ip : nil)
                RowDivider()
                Row {
                    Button {
                        showingWifiSheet = true
                    } label: {
                        HStack {
                            Text(manager.wifi?.state == .off ? "Set up network" : "Change network")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!ready || manager.activeLink != .bluetooth)
                }
                if let w = manager.wifi, w.state != .off {
                    RowDivider()
                    Row {
                        Button("Forget network", role: .destructive) {
                            manager.perform { try await manager.forgetWifi() }
                        }
                        .disabled(!ready || manager.activeLink != .bluetooth)
                    }
                }
            }
            .onChange(of: preference) { _, p in
                Esp32Manager.setLinkPreference(p, for: deviceID)
                if p == .bluetooth, manager.cloud?.cloudMode == true, manager.state == .ready {
                    // The board has Bluetooth off while on its own link; ask it to come back.
                    manager.perform { try await manager.pauseBoardCloudMode() }
                } else {
                    manager.reconnect()
                }
            }

            CardGroup("Jarvis") {
                DetailRow(icon: cloudIcon, tint: cloudTint, title: "Direct link",
                          value: manager.cloud?.state.label ?? "—", detail: cloudDetail)
                RowDivider()
                Row {
                    switch manager.cloud?.state ?? .off {
                    case .paired, .connecting, .connected:
                        Button("Unlink", role: .destructive) {
                            manager.perform { try await manager.unlinkBoardFromJarvis() }
                        }
                        .disabled(!ready)
                    case .off, .failed, .expired:
                        Button {
                            linkBoard()
                        } label: {
                            HStack {
                                Text(linking ? "Linking…" : (manager.cloud?.state == .off ? "Link directly" : "Retry link"))
                                Spacer()
                                if linking { ProgressView().controlSize(.small) }
                                else { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!ready || linking)
                    }
                }
            }
        }
    }

    private func linkBoard() {
        guard !linking else { return }
        linking = true
        Task {
            do {
                try await manager.linkBoardToJarvis()
                linkMessage = "The board accepted the link and is pairing with Jarvis now. It turns Bluetooth off, pairs over Wi‑Fi and restarts; the app reconnects over Wi‑Fi in a moment. The Direct link row shows the result."
            } catch {
                linkMessage = "Could not link the board: \(error.localizedDescription)"
            }
            linking = false
        }
    }

    private var cloudIcon: String {
        switch manager.cloud?.state ?? .off {
        case .connected:  return "checkmark.icloud.fill"
        case .connecting: return "arrow.triangle.2.circlepath.icloud"
        case .failed, .expired: return "exclamationmark.icloud"
        case .paired:     return "icloud"
        case .off:        return "icloud.slash"
        }
    }

    private var cloudTint: Color {
        switch manager.cloud?.state ?? .off {
        case .connected:        return green
        case .connecting, .paired: return blue
        case .failed, .expired: return red
        case .off:              return .secondary
        }
    }

    private var cloudDetail: String? {
        guard let c = manager.cloud else { return nil }
        if !c.error.isEmpty { return shortError(c.error) }
        if c.state == .off, manager.wifi?.state != .connected { return "Needs Wi‑Fi" }
        if c.state == .connected { return "Runs on its own · Bluetooth off" }
        if c.state == .paired { return "Switches over when no phone is around" }
        return nil
    }

    /// One readable line out of the board's diagnostic text.
    private func shortError(_ e: String) -> String {
        let lower = e.lowercased()
        if lower.contains("dns") { return "Can't resolve the server address" }
        if lower.contains("memory") { return "Board ran out of memory — retry" }
        if lower.contains("tls") { return "Secure connection failed" }
        if lower.contains("rejected") { return "Pairing code rejected" }
        if lower.contains("wi‑fi") || lower.contains("wifi") { return "Needs Wi‑Fi" }
        let firstLine = e.split(whereSeparator: \.isNewline).first.map(String.init) ?? e
        return firstLine.count > 70 ? String(firstLine.prefix(69)) + "…" : firstLine
    }

    private var networkFooter: String {
        if manager.activeLink == .wifi {
            return "Wi‑Fi settings change over Bluetooth. Switch Prefer to Bluetooth to edit them."
        }
        return "Auto uses Wi‑Fi when the board is on the network and falls back to Bluetooth."
    }

    private var cloudFooter: String {
        if manager.cloud?.cloudMode == true {
            return "In this mode Bluetooth is off; the phone reaches the board over the LAN. Hold the board's BOOT button 3 s to return to Bluetooth."
        }
        return "Linking turns Bluetooth off and restarts the board; the app reconnects over Wi‑Fi."
    }

    // MARK: Pins

    private var pins: some View {
        CardGroup("GPIO") {
            if scriptRunning {
                Row(minHeight: 44) {
                    HStack(spacing: 10) {
                        Image(systemName: "scroll.fill").foregroundStyle(green)
                        Text("Script running — controls paused").font(.footnote)
                        Spacer(minLength: 0)
                    }
                }
                RowDivider()
            }
            if manager.pins.isEmpty {
                Row { Text("Waiting for the board…").foregroundStyle(.secondary) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                    ForEach(manager.pins) { pin in
                        Esp32PinTile(pin: pin, state: manager.pinStates[pin.gpio], manager: manager)
                    }
                }
                .padding(12)
                .disabled(scriptRunning)
                .opacity(scriptRunning ? 0.45 : 1)
            }
        }
        .disabled(!ready)
        .opacity(ready ? 1 : 0.5)
    }

    // MARK: Console

    private var consoleCard: some View {
        CardGroup("Console") {
            if manager.scriptLog.isEmpty {
                Row { Text("No output yet").foregroundStyle(.secondary) }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(manager.scriptLog.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("error") ? .red : line.hasPrefix("→") || line.hasPrefix("←") || line.hasPrefix("—") ? .secondary : .primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contextMenu {
                    Button { UIPasteboard.general.string = manager.scriptLog.joined(separator: "\n") } label: { Label("Copy all", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { manager.clearScriptLog() } label: { Label("Clear", systemImage: "trash") }
                }
            }
        }
    }

    // MARK: Sharing

    private var sharing: some View {
        CardGroup("Sharing", footer: bridge.isPaired ? nil : "Pair with Jarvis in Settings first.") {
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

// MARK: - Pin tile

private struct Esp32PinTile: View {
    let pin: Esp32Protocol.PinInfo
    let state: Esp32Protocol.PinState?
    @ObservedObject var manager: Esp32Manager

    private var mode: Esp32Protocol.PinMode { state?.mode ?? .unset }
    private var value: Int { Int(state?.value ?? 0) }
    private var isHigh: Bool { value != 0 }
    private var canOutput: Bool { pin.capabilities.contains(.output) }

    private var tint: Color {
        if pin.capabilities.contains(.led) { return Color(red: 0.30, green: 0.62, blue: 1.0) }
        if !canOutput { return .orange }
        return Color(red: 0.29, green: 0.82, blue: 0.49)
    }

    private var modeText: String {
        switch mode {
        case .unset:         return canOutput ? "—" : "in"
        case .output:        return "out"
        case .input:         return "in"
        case .inputPullup:   return "in ↑"
        case .inputPulldown: return "in ↓"
        case .pwm:           return "pwm \(value * 100 / 255)%"
        }
    }

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 5) {
                HStack(spacing: 3) {
                    Text("\(pin.gpio)")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    if pin.capabilities.contains(.strapping) {
                        Text("⚠︎").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Circle()
                    .fill(isHigh ? tint : Color.secondary.opacity(0.25))
                    .frame(width: 12, height: 12)
                    .shadow(color: isHigh ? tint.opacity(0.7) : .clear, radius: 5)
                Text(modeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 74)
            .padding(.vertical, 8)
            .background(isHigh ? tint.opacity(0.16) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isHigh ? tint.opacity(0.5) : .white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: isHigh)
        .contextMenu { menu }
    }

    private func tap() {
        if !canOutput || mode.isInput {
            manager.perform { _ = try await manager.readPin(pin.gpio) }
        } else if mode == .pwm {
            let duty = value > 0 ? 0 : 255
            manager.perform { try await manager.setPWM(pin.gpio, duty: duty) }
        } else {
            let target = !isHigh
            manager.perform { try await manager.writePin(pin.gpio, high: target) }
        }
    }

    @ViewBuilder private var menu: some View {
        Section("Mode") {
            if canOutput {
                Button("Output") { manager.perform { try await manager.setPinMode(pin.gpio, .output) } }
            }
            Button("Input") { manager.perform { try await manager.setPinMode(pin.gpio, .input) } }
            if canOutput {
                Button("Input, pull-up") { manager.perform { try await manager.setPinMode(pin.gpio, .inputPullup) } }
                Button("Input, pull-down") { manager.perform { try await manager.setPinMode(pin.gpio, .inputPulldown) } }
            }
        }
        if pin.capabilities.contains(.pwm) {
            Section("PWM") {
                ForEach([25, 50, 75, 100], id: \.self) { pct in
                    Button("\(pct)%") { manager.perform { try await manager.setPWM(pin.gpio, duty: pct * 255 / 100) } }
                }
            }
        }
        if canOutput {
            Section("Pulse high") {
                ForEach([100, 500, 1000], id: \.self) { ms in
                    Button(ms < 1000 ? "\(ms) ms" : "\(ms / 1000) s") {
                        manager.perform { try await manager.pulsePin(pin.gpio, high: true, durationMs: ms) }
                    }
                }
            }
        }
        Button("Read level") { manager.perform { _ = try await manager.readPin(pin.gpio) } }
    }
}

// MARK: - Wi‑Fi sheet

/// Networks come from the board's own scan: iOS gives apps no way to list nearby
/// networks, and the board's list is the honest one anyway — it only shows the 2.4 GHz
/// networks the ESP32 can actually join.
private struct Esp32WifiSheet: View {
    @ObservedObject var manager: Esp32Manager
    @Environment(\.dismiss) private var dismiss
    @State private var networks: [Esp32Protocol.WifiNetwork] = []
    @State private var scanning = false
    /// The network whose password popup is showing.
    @State private var prompting: Esp32Protocol.WifiNetwork?
    @State private var password = ""
    @State private var joining: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if networks.isEmpty {
                        HStack(spacing: 10) {
                            if scanning { ProgressView() }
                            Text(scanning ? "Scanning from the board…" : "No networks found")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(networks) { n in
                        Button { password = ""; prompting = n } label: {
                            HStack {
                                Text(n.ssid)
                                if n.ssid == manager.wifi?.ssid {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                                Spacer()
                                if joining == n.ssid { ProgressView().controlSize(.small) }
                                if n.secure { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                                Image(systemName: n.rssi >= -75 ? "wifi" : "wifi.exclamationmark").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(joining != nil)
                    }
                } header: {
                    HStack {
                        Text("Networks the board can see")
                        Spacer()
                        Button("Rescan") { Task { await scan() } }.disabled(scanning || joining != nil).font(.caption)
                    }
                } footer: {
                    Text("2.4 GHz only — the ESP32 has no 5 GHz radio. The password is sent over the encrypted Bluetooth link and stored on the board.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let w = manager.wifi, w.state != .off {
                    Section("Current") {
                        LabeledContent("Network", value: w.ssid)
                        LabeledContent("Status", value: w.state.label)
                        if let ip = w.ip { LabeledContent("IP", value: ip) }
                        LabeledContent("Hostname", value: "\(w.hostname).local")
                    }
                }
            }
            .navigationTitle("Wi‑Fi network")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task { await scan() }
            // The system alert with a text field is the same popup iOS uses in Settings.
            .alert("Enter the password for “\(prompting?.ssid ?? "")”",
                   isPresented: Binding(get: { prompting != nil }, set: { if !$0 { prompting = nil } }),
                   presenting: prompting) { network in
                if network.secure {
                    SecureField("Password", text: $password)
                }
                Button("Cancel", role: .cancel) { prompting = nil }
                Button("Join") { join(network) }
                    .disabled(network.secure && password.isEmpty)
            } message: { network in
                Text(network.secure ? "The board will join this network and remember it."
                                    : "This is an open network with no password.")
            }
        }
    }

    private func scan() async {
        scanning = true; error = nil
        do { networks = try await manager.scanWifi() }
        catch { self.error = "Scan failed: \(error.localizedDescription)" }
        scanning = false
    }

    private func join(_ network: Esp32Protocol.WifiNetwork) {
        prompting = nil
        joining = network.ssid; error = nil
        let pass = password
        password = ""
        Task {
            do {
                try await manager.setWifi(ssid: network.ssid, password: pass)
                // Give the board a moment to join so the status row is meaningful.
                for _ in 0..<6 {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    try await manager.refreshWifi()
                    if let s = manager.wifi?.state, s == .connected || s == .failed { break }
                }
                if manager.wifi?.state == .failed {
                    error = "The board could not join “\(network.ssid)”. Check the password and that it is a 2.4 GHz network."
                } else {
                    dismiss()
                }
            } catch {
                self.error = error.localizedDescription
            }
            joining = nil
        }
    }
}

// MARK: - Card for the device list

struct Esp32Card: View {
    let board: DiscoveredEsp32
    /// Link the manager currently holds to this board, if any.
    var activeLink: Esp32Link? = nil

    private var blue: Color { Color(red: 0.30, green: 0.62, blue: 1.0) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                Image(systemName: "cpu")
                    .font(.system(size: 64, weight: .ultraLight))
                    .foregroundStyle(blue.opacity(0.7))
                    .padding(.trailing, 34)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(board.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: 190, alignment: .leading)
                Text("ESP32 DevKit V1")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let activeLink {
                        MetricPill(icon: activeLink.icon, label: "Connected", value: activeLink.label,
                                   tint: Color(red: 0.29, green: 0.82, blue: 0.49))
                    } else if board.isOnWifi {
                        MetricPill(icon: "wifi", label: "Seen on", value: "Wi‑Fi",
                                   tint: Color(red: 0.29, green: 0.82, blue: 0.49))
                        if board.record == nil && board.peripheral == nil {
                            Text("needs Bluetooth setup").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if board.rssi == 0 {
                        MetricPill(icon: board.canUseWifi ? "wifi" : "antenna.radiowaves.left.and.right",
                                   label: "Signal", value: board.canUseWifi ? "Wi‑Fi" : "Known", tint: blue)
                    } else {
                        MetricPill(icon: "antenna.radiowaves.left.and.right", label: "Signal",
                                   value: "\(board.rssi) dBm", tint: signalTint)
                    }
                    if board.isOnWifi && board.rssi != 0 && activeLink == nil {
                        Image(systemName: "wifi").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }

    private var signalTint: Color {
        switch board.rssi {
        case (-68)...:      return Color(red: 0.29, green: 0.82, blue: 0.49)
        case (-82)..<(-68): return .orange
        default:            return Color(red: 1.0, green: 0.31, blue: 0.27)
        }
    }
}


/// Icon, title and a right-aligned value on one line, with an optional secondary line
/// beneath that wraps — long status text never collides with the title.
private struct DetailRow: View {
    let icon: String
    var tint: Color = .secondary
    let title: String
    let value: String
    var detail: String? = nil

    var body: some View {
        Row(minHeight: 52) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 22)
                    Text(title)
                    Spacer(minLength: 12)
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 32)
                }
            }
            .padding(.vertical, 8)
        }
    }
}
