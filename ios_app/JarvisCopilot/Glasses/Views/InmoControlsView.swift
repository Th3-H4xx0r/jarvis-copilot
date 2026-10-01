import Charts
import SwiftUI

/// Operational controls use the same adapter advertised to Jarvis.
struct InmoControlsView: View {
    @ObservedObject private var device = InmoGo3Device.shared
    @ObservedObject private var session = InmoSession.shared
    @State private var brightness = 50.0
    @State private var volume = 50.0
    @State private var title = "Jarvis document"
    @State private var document = ""
    @State private var error: String?
    @State private var result: String?
    @State private var ownerIdentity = ""
    @State private var line = 1
    @State private var percent = 0.0
    @State private var working = false
    @State private var share = true
    @State private var showDetails = false
    @State private var batteryWindow = "24 hours"
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Control connection") {
                LabeledContent("Control", value: String(describing: session.state))
                Text("Audio pairing and control readiness are separate connections.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(session.isReady ? "Disconnect" : "Connect") {
                        Task {
                            do {
                                if session.isReady { session.disconnect() }
                                else { try await session.ensureConnected() }
                            } catch { self.error = "Connect: \(error.localizedDescription) Close INMO and try again." }
                        }
                    }.buttonStyle(.borderedProminent)
                    Button("Refresh Status") { action("glasses_status", [:], query: true) }.buttonStyle(.bordered).disabled(!session.isReady)
                }
                DisclosureGroup("Existing owner setup") {
                    Text("Reconnect using your existing INMO owner identity. Jarvis stores it locally in Keychain and does not acquire new ownership.").font(.caption)
                    SecureField("Owner identity hex", text: $ownerIdentity).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save Reconnect Identity") { saveIdentity() }.disabled(ownerIdentity.isEmpty)
                }
                if let message = error ?? session.lastError { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            }
            section("Live dashboard") {
                LabeledContent("Battery", value: session.status.battery.map { "\($0)%" } ?? "Unknown")
                LabeledContent("Firmware", value: session.status.firmware ?? "Unknown")
                if let date = session.status.lastReceived {
                    HStack { Text("Status received"); Spacer(); Text(date, style: .relative).foregroundStyle(.secondary) }
                    if !session.isReady || Date().timeIntervalSince(date) > 300 { Text("Last reported values are stale.").font(.caption).foregroundStyle(.secondary) }
                } else { Text("Connect and receive device status to populate the dashboard.").font(.caption).foregroundStyle(.secondary) }
                batteryChart
                Button(showDetails ? "Hide Device Details" : "Show Device Details") { showDetails.toggle() }
                if showDetails {
                    LabeledContent("Model", value: session.status.model ?? "Unknown")
                    LabeledContent("Serial (local)", value: session.status.serial ?? "Unknown")
                    LabeledContent("MCU firmware", value: "Not reported")
                    LabeledContent("Charging", value: "No validated signal")
                    LabeledContent("Storage", value: "No validated capacity response")
                    LabeledContent("Screen / worn state", value: "Not reported")
                    LabeledContent("Signal", value: session.rssi.map { "\($0) dBm" } ?? "Unknown")
                    LabeledContent("Protocol frames", value: "\(session.counters.validFrames) valid · \(session.counters.invalidFrames) rejected")
                    LabeledContent("Current module", value: session.status.module.map(String.init) ?? "Unknown")
                    Text("Battery health, temperature and per-app energy use are not reported. Inventory sizes are not total storage use.").font(.caption).foregroundStyle(.secondary)
                }
            }
            section("Remote") {
                trackpad
                // The INMO remote's own order: Back, Home, GO.
                HStack {
                    remoteButton("Back", icon: "chevron.backward", name: "glasses_back")
                    remoteButton("Home", icon: "house", name: "glasses_home")
                    remoteButton("GO", icon: "arrowshape.forward.circle", name: "glasses_go")
                }
                remoteButton("Double GO", icon: "forward.circle", name: "glasses_go_double")
                HStack {
                    directionButton("Left", symbol: "arrow.left", direction: "left")
                    directionButton("Up", symbol: "arrow.up", direction: "up")
                    directionButton("Down", symbol: "arrow.down", direction: "down")
                    directionButton("Right", symbol: "arrow.right", direction: "right")
                }
                Text("Double GO sends two taps on the INMO app's own timing. The additional shortcut icons remain unavailable until their behavior is resolved from source and a device trial.").font(.caption).foregroundStyle(.secondary)
            }
            section("Display and sound") {
                slider("Brightness", value: $brightness, observed: session.status.brightness, command: "glasses_set_brightness")
                slider("Volume", value: $volume, observed: session.status.volume, command: "glasses_set_volume")
                Toggle("Do Not Disturb", isOn: Binding(get: { session.status.dnd ?? false }, set: { action("glasses_set_dnd", ["enabled": $0]) })).disabled(!session.isReady)
                if session.status.dnd == nil { Text("DND state unknown until reported.").font(.caption).foregroundStyle(.secondary) }
                HStack { Text("Screen timeout"); Spacer(); Menu("Set Timeout") { ForEach([15, 30], id: \.self) { seconds in Button("\(seconds) seconds") { action("glasses_set_screen_timeout", ["seconds": seconds]) } } }.disabled(!session.isReady) }
                DisclosureGroup("Additional Settings") {
                    InmoAdvancedControlsView()
                    Toggle("Enable Experimental Controls", isOn: $device.experimentalEnabled)
                    Text("Source-derived controls may differ by model or firmware. This local choice enables their explicit invocation.").font(.caption).foregroundStyle(.secondary)
                    ForEach(InmoGo3Device.settings.keys.sorted(), id: \.self) { setting in
                        HStack { Text(setting.replacingOccurrences(of: "_", with: " ").capitalized); Spacer(); Button("On") { action("glasses_settings", ["setting": setting, "enabled": true]) }; Button("Off") { action("glasses_settings", ["setting": setting, "enabled": false]) } }.disabled(!session.isReady || !device.experimentalEnabled)
                    }
                }
            }
            section("Jarvis on the glasses") {
                Toggle("Use Jarvis for Glasses AI", isOn: Binding(get: { InmoAIChannel.shared.enabled }, set: { enabled in Task { await InmoAIChannel.shared.setEnabled(enabled) } }))
                Text(InmoAIChannel.shared.status).font(.caption).foregroundStyle(.secondary)
                Text("The glasses wake/button microphone path uses the selected Jarvis conversation. Device audio decoding failures are shown explicitly.").font(.caption).foregroundStyle(.secondary)
            }
            section("Teleprompter") {
                TextField("Document title", text: $title).textFieldStyle(.roundedBorder)
                TextEditor(text: $document).frame(minHeight: 140).scrollContentBackground(.hidden).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Teleprompter document")
                HStack {
                    Button("Upload") { action("glasses_teleprompter_upload", ["title": title, "text": document]) }.disabled(document.isEmpty || working || !session.isReady)
                    Button("Start") { action("glasses_teleprompter_start", [:]) }.disabled(working || !session.isReady)
                    Button("Stop") { action("glasses_teleprompter_stop", [:]) }.disabled(!session.isReady)
                }.buttonStyle(.bordered)
                HStack {
                    Button("Previous") { action("glasses_teleprompter_page", ["direction": "previous"]) }
                    Button("Next") { action("glasses_teleprompter_page", ["direction": "next"]) }
                }.buttonStyle(.bordered).disabled(!session.isReady)
                Stepper("Position: line \(line)", value: $line, in: 1...100000)
                Slider(value: $percent, in: 0...100, step: 1).accessibilityLabel("Teleprompter percentage")
                Text("Independent percentage: \(Int(percent))%")
                Button("Go to Position") { action("glasses_teleprompter_progress", ["line": line, "percent": percent]) }.disabled(!session.isReady)
                Text("Line position and reported percentage are separate values. Upload must be acknowledged before Start.").font(.caption).foregroundStyle(.secondary)
            }
            section("Camera") {
                HStack {
                    remoteButton("Photo Page", icon: "camera", name: "glasses_camera_open")
                    remoteButton("Video Page", icon: "video", name: "glasses_video_open")
                    remoteButton("Close", icon: "xmark", name: "glasses_camera_close")
                }
                Text("Opening a page does not take a photo or start recording.").font(.caption).foregroundStyle(.secondary)
                if device.experimentalEnabled {
                    HStack { ForEach(["shutter", "start_recording", "stop_recording"], id: \.self) { name in Button(name.replacingOccurrences(of: "_", with: " ").capitalized) { action("glasses_camera_action", ["action": name]) } } }.disabled(!session.isReady)
                }
            }
            InmoMediaView()
            section("Share with Jarvis") {
                Toggle("Share Glasses Skills", isOn: $share).onChange(of: share) { _, value in BridgeClient.setExposed(value, for: device.deviceID); device.refreshMembership() }
                Text("The same commands power this page, chat, voice and automations.").font(.caption).foregroundStyle(.secondary)
                NavigationLink("All Controls and Availability") { InmoCapabilitiesView(device: device) }
            }
        }
        .onAppear {
            share = BridgeClient.isExposed(device.deviceID)
            InmoTeleprompter.shared.install(on: device)
            brightness = Double(session.status.brightness ?? 50)
            volume = Double(session.status.volume ?? 50)
        }
        .onReceive(session.$status) { status in
            if let value = status.brightness { brightness = Double(value) }
            if let value = status.volume { volume = Double(value) }
        }
    }
    private var batteryChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Battery history", selection: $batteryWindow) { Text("Current session").tag("Current session"); Text("24 hours").tag("24 hours") }.pickerStyle(.segmented)
            let lastConnection = device.history.samples.last?.connection
            let points = device.history.samples.filter { batteryWindow == "Current session" ? $0.connection == lastConnection : Date().timeIntervalSince($0.date) <= 24 * 3600 }
            if points.isEmpty { Text("Battery usage: not enough history").font(.caption).foregroundStyle(.secondary) }
            else {
                Chart(points) { point in LineMark(x: .value("Time", point.date), y: .value("Battery %", point.percent), series: .value("Segment", point.segment.uuidString)) }.chartYScale(domain: 0...100).frame(height: 130).accessibilityLabel("Glasses battery percentage for the selected observation window")
                if let first = points.first, let last = points.last, first.segment == last.segment {
                    Text("Measured change: \(max(0, first.percent - last.percent)) percentage points across \(Int(last.date.timeIntervalSince(first.date) / 60)) minutes").font(.caption)
                }
            }
            if let estimate = device.history.estimate(), session.isReady, let last = device.history.samples.last, Date().timeIntervalSince(last.date) <= 300 {
                Text(String(format: "Estimate from recent use: %.1f points/hour · about %.1f hours remaining", estimate.pointsPerHour, estimate.hoursRemaining)).font(.caption).foregroundStyle(.secondary)
            } else { Text("Estimate: not enough history").font(.caption).foregroundStyle(.secondary) }
            Text("Seven days retained locally. A rise or connection gap starts a new estimation segment.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var trackpad: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.secondary.opacity(0.08))
                Canvas { context, size in
                    for x in stride(from: 12.0, to: size.width, by: 18) { for y in stride(from: 12.0, to: size.height, by: 18) { context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.secondary.opacity(0.35))) } }
                }
                Text("Tap or Swipe").font(.callout).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                let x = Int(min(100, max(0, gesture.location.x / geometry.size.width * 100)))
                let y = Int(min(100, max(0, gesture.location.y / geometry.size.height * 100)))
                let dx = gesture.translation.width, dy = gesture.translation.height
                if hypot(dx, dy) < 12 { action("glasses_touch", ["kind": "click", "x": x, "y": y]) }
                else { action("glasses_touch", ["kind": "drag", "direction": abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up"), "x": x, "y": y]) }
            })
            .accessibilityLabel("Glasses trackpad")
            .accessibilityHint("Use the labeled directional buttons below as an alternative")
        }.frame(height: 160).disabled(!session.isReady)
    }
    private func directionButton(_ title: String, symbol: String, direction: String) -> some View {
        Button { action("glasses_touch", ["kind": "drag", "direction": direction, "x": 50, "y": 50]) } label: { Image(systemName: symbol).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(title).buttonStyle(.bordered).disabled(!session.isReady)
    }
    private func remoteButton(_ title: String, icon: String, name: String) -> some View {
        Button { action(name, [:]) } label: { Label(title, systemImage: icon).frame(minHeight: 44) }.buttonStyle(.bordered).disabled(!session.isReady)
    }
    private func slider(_ title: String, value: Binding<Double>, observed: Int?, command: String) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: observed.map { "\($0)% reported" } ?? "Unknown")
            Slider(value: value, in: 0...100, step: 1, onEditingChanged: { editing in if !editing { action(command, ["value": Int(value.wrappedValue)]) } }).accessibilityLabel(title).disabled(!session.isReady)
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline); GlassCard { VStack(alignment: .leading, spacing: 12) { content() } } }
    }
    private func action(_ name: String, _ args: [String: Any], query: Bool = false) {
        error = nil; working = true
        Task {
            defer { working = false }
            do {
                if query {
                    for type in [27, 31, 32, 33, 35, 38, 28, 2, 29, 30, 34, 37, 39, 41] {
                        try await session.send(InmoCommand.envelope(type: 20, field: 23, payload: InmoWireCodec.uint(1, UInt64(type))))
                    }
                }
                let response = try await device.invoke(name, args: args)
                result = "\(name.replacingOccurrences(of: "glasses_", with: "").replacingOccurrences(of: "_", with: " ").capitalized): \(response["state"] as? String ?? "updated")"
            } catch { self.error = "\(name.replacingOccurrences(of: "glasses_", with: "").replacingOccurrences(of: "_", with: " ").capitalized): \(error.localizedDescription)" }
        }
    }
    private func saveIdentity() {
        let clean = ownerIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count % 2 == 0, clean.count <= 512 else { error = "Owner identity must contain an even number of hex characters (maximum 512)."; return }
        var bytes = Data(); var index = clean.startIndex
        while index < clean.endIndex {
            let end = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<end], radix: 16) else { error = "Owner identity contains non-hex characters."; return }
            bytes.append(byte); index = end
        }
        do { try session.setOwnerIdentity(bytes); ownerIdentity = ""; result = "Reconnect identity saved locally. Tap Connect."; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct InmoCapabilitiesView: View {
    @ObservedObject var device: InmoGo3Device
    var body: some View {
        List {
            ForEach(InmoGo3Device.inventory) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.group).font(.caption).foregroundStyle(.secondary)
                    Text(entry.title).font(.body.weight(.medium))
                    Text(entry.evidence).font(.caption).foregroundStyle(.secondary)
                    if let row = device.inventorySnapshot().first(where: { $0["id"] as? String == entry.id }), let reason = row["reason"] as? String { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    else { Label("Available", systemImage: "checkmark.circle").font(.caption) }
                }.padding(.vertical, 4)
            }
        }.navigationTitle("GO3 Controls")
    }
}
