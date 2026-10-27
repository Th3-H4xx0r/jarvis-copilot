import AVKit
import Charts
import SwiftUI

// The pages behind the glasses page's rows. Each holds what used to sit on the one long page,
// unchanged in what it does; the main page keeps only what's used day to day.

// MARK: - Display & sound

struct GlassesDisplaySoundPage: View {
    @ObservedObject private var session = InmoSession.shared
    @ObservedObject private var actions = GlassesActions.shared
    @State private var brightness = 50.0
    @State private var volume = 50.0
    @State private var speakerTest = GlassesSpeakerTest()
    private let link = GlassesAudioLink.shared

    var body: some View {
        GlassesSubpage("Display & sound") {
            GlassesSection("Lens") {
                slider("sun.max.fill", "Brightness", value: $brightness, observed: session.status.brightness,
                       command: "glasses_set_brightness")
                GlassesToggleRow(symbol: "moon.fill", title: "Do Not Disturb",
                                 subtitle: session.status.dnd == nil ? "Shows once the glasses report it" : nil,
                                 isOn: Binding(get: { session.status.dnd ?? false },
                                               set: { actions.run("glasses_set_dnd", ["enabled": $0]) }))
                    .disabled(!session.isReady)
                GlassRow(symbol: "timer", title: "Screen timeout", last: true) {
                    Menu {
                        ForEach([15, 30], id: \.self) { seconds in
                            Button("\(seconds) seconds") { actions.run("glasses_set_screen_timeout", ["seconds": seconds]) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Choose")
                            JcIcon("chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline).foregroundStyle(JcTheme.accent)
                    }
                    .disabled(!session.isReady)
                }
            }
            GlassesSection("Sound") {
                slider("speaker.wave.2.fill", "Volume", value: $volume, observed: session.status.volume,
                       command: "glasses_set_volume")
                GlassRow(symbol: "airplayaudio", title: "Audio output",
                         subtitle: link.state.speakers ? "Playing through the glasses" : "The glasses or the iPhone") {
                    AudioRoutePicker().frame(width: 34, height: 34)
                }
                GlassRow(symbol: "waveform", title: "Test speakers",
                         subtitle: speakerTest.error ?? "Jarvis says one line through the current output", last: true) {
                    if speakerTest.speaking {
                        Button("Stop") { speakerTest.stop() }.buttonStyle(.jcGlass(compact: true))
                    } else {
                        Button("Play") { speakerTest.play() }.buttonStyle(.jcGlass(compact: true))
                    }
                }
            }
            GlassesActionStatus()
        }
        .onAppear {
            actions.clear()
            brightness = Double(session.status.brightness ?? 50)
            volume = Double(session.status.volume ?? 50)
        }
        .onDisappear { speakerTest.stop() }
        .onReceive(session.$status) { status in
            if let value = status.brightness { brightness = Double(value) }
            if let value = status.volume { volume = Double(value) }
        }
    }

    private func slider(_ symbol: String, _ title: String, value: Binding<Double>, observed: Int?,
                        command: String) -> some View {
        VStack(spacing: 0) {
            GlassRow(symbol: symbol, title: title) {
                Text(observed.map { "\($0)%" } ?? "").font(.subheadline).foregroundStyle(JcTheme.muted)
            }
            Slider(value: value, in: 0...100, step: 1) { editing in
                if !editing { actions.run(command, ["value": Int(value.wrappedValue)]) }
            }
            .tint(JcTheme.accent)
            .accessibilityLabel(title)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .disabled(!session.isReady)
        }
    }
}

// MARK: - Controls

struct GlassesControlsPage: View {
    @ObservedObject private var session = InmoSession.shared
    @ObservedObject private var device = InmoGo3Device.shared
    @ObservedObject private var actions = GlassesActions.shared

    var body: some View {
        GlassesSubpage("Controls") {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Touchpad")
                trackpad
                LiveSettingsNote("Tap or swipe here as you would on the arm.")
            }
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Buttons")
                VStack(spacing: 10) {
                    // The INMO remote's own order: Back, Home, GO.
                    HStack(spacing: 10) {
                        key("Back", "chevron.backward", "glasses_back")
                        key("Home", "house", "glasses_home")
                        key("GO", "arrowshape.forward.circle", "glasses_go")
                    }
                    HStack(spacing: 10) {
                        key("Double GO", "forward.circle", "glasses_go_double")
                    }
                    HStack(spacing: 10) {
                        arrow("Left", "arrow.left", "left")
                        arrow("Up", "arrow.up", "up")
                        arrow("Down", "arrow.down", "down")
                        arrow("Right", "arrow.right", "right")
                    }
                }
                .disabled(!session.isReady)
            }
            GlassesSection("Camera", note: "Opening a page doesn't take a photo or start recording.") {
                camera("camera", "Photo page", "glasses_camera_open")
                camera("video", "Video page", "glasses_video_open")
                camera("xmark.circle", "Close camera", "glasses_camera_close", last: !device.experimentalEnabled)
                if device.experimentalEnabled {
                    GlassRow(symbol: "flask", title: "Experimental", last: true) {
                        HStack(spacing: 6) {
                            ForEach(["shutter", "start_recording", "stop_recording"], id: \.self) { name in
                                Button(name.replacingOccurrences(of: "_", with: " ").capitalized) {
                                    actions.run("glasses_camera_action", ["action": name])
                                }
                                .buttonStyle(.jcGlass(compact: true))
                            }
                        }
                    }
                }
            }
            .disabled(!session.isReady)
            GlassesActionStatus()
        }
        .onAppear { actions.clear() }
    }

    private var trackpad: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous).fill(JcTheme.glassFill)
                RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous).strokeBorder(JcTheme.glassBorder)
                Canvas { context, size in
                    for x in stride(from: 14.0, to: size.width, by: 18) {
                        for y in stride(from: 14.0, to: size.height, by: 18) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.white.opacity(0.12)))
                        }
                    }
                }
                VStack(spacing: 6) {
                    JcIcon("hand.tap", size: 22).foregroundStyle(JcTheme.accent)
                    Text("Tap or swipe").font(.footnote.weight(.medium)).foregroundStyle(JcTheme.muted)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                let x = Int(min(100, max(0, gesture.location.x / geometry.size.width * 100)))
                let y = Int(min(100, max(0, gesture.location.y / geometry.size.height * 100)))
                let dx = gesture.translation.width, dy = gesture.translation.height
                if hypot(dx, dy) < 12 { actions.run("glasses_touch", ["kind": "click", "x": x, "y": y]) }
                else { actions.run("glasses_touch", ["kind": "drag", "direction": abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up"), "x": x, "y": y]) }
            })
            .accessibilityLabel("Glasses touchpad")
            .accessibilityHint("Use the arrow buttons below as an alternative")
        }
        .frame(height: 170)
        .disabled(!session.isReady)
        .opacity(session.isReady ? 1 : 0.5)
    }

    private func key(_ title: String, _ icon: String, _ name: String) -> some View {
        Button { actions.run(name) } label: { Label(title, jcIcon: icon) }
            .buttonStyle(.jcGlass(full: true))
    }

    private func arrow(_ title: String, _ symbol: String, _ direction: String) -> some View {
        Button { actions.run("glasses_touch", ["kind": "drag", "direction": direction, "x": 50, "y": 50]) } label: {
            JcIcon(symbol)
        }
        .buttonStyle(.jcGlass(full: true))
        .accessibilityLabel(title)
    }

    private func camera(_ symbol: String, _ title: String, _ name: String, last: Bool = false) -> some View {
        GlassRow(symbol: symbol, title: title, last: last, action: { actions.run(name) }) {
            GlassesRowValue(value: nil, chevron: false)
        }
    }
}

// MARK: - Talking to Jarvis

struct GlassesTalkingPage: View {
    @State private var speech = SpeechEngineStore.shared
    private let link = GlassesAudioLink.shared

    var body: some View {
        GlassesSubpage("Talking to Jarvis") {
            GlassesSection(nil, note: "The glasses' wake word and button open the selected Jarvis conversation.") {
                GlassesToggleRow(symbol: "sparkles", title: "Use Jarvis for Glasses AI",
                                 subtitle: InmoAIChannel.shared.status,
                                 isOn: Binding(get: { InmoAIChannel.shared.enabled },
                                               set: { on in Task { await InmoAIChannel.shared.setEnabled(on) } }))
                GlassesToggleRow(symbol: "bolt.horizontal.circle", title: "Voice on connect",
                                 subtitle: "Open Voice as soon as the glasses take the audio",
                                 isOn: Binding(get: { link.startsVoiceOnConnect }, set: { link.startsVoiceOnConnect = $0 }))
                speechModel
            }
            Button { Task { await InmoAIChannel.shared.startFromPhone() } } label: {
                Label("Talk to Jarvis", jcIcon: "mic.fill")
            }
            .buttonStyle(.jcGlass(full: true))
        }
        .task { await speech.load() }
    }

    /// The glasses talk to Jarvis through the phone's Voice, so this is the phone's voice speech
    /// setting — the same one the Voice sheet shows.
    private var speechModel: some View {
        let s = speech.settings
        let options = s.engines.filter { $0.available || $0.name == s.voice }
        return GlassRow(symbol: "text.bubble", title: "Speech model",
                        subtitle: speech.error.isEmpty ? "Shared with the phone's Voice" : speech.error, last: true) {
            Menu {
                ForEach(options) { engine in
                    Button {
                        Task { await speech.setSurface("voice", to: engine.name) }
                    } label: {
                        if engine.name == s.voice { Label(engine.label, jcIcon: "checkmark") } else { Text(engine.label) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(speech.loaded ? s.label(for: s.voice) : "…").lineLimit(1)
                    JcIcon("chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(JcTheme.accent)
            }
            .disabled(!speech.loaded || options.isEmpty)
        }
    }
}

// MARK: - Notifications

struct GlassesNotificationsPage: View {
    @State private var notificationsOn = InmoSession.notificationsEnabled
    @ObservedObject private var esp32 = WearablesHub.shared.esp32

    var body: some View {
        GlassesSubpage("Notifications") {
            GlassesSection(nil, note: "Only the title and text show on the lens; iOS asks once to allow it.") {
                GlassesToggleRow(symbol: "bell.badge", title: "Show notifications",
                                 subtitle: "Your iPhone's notifications on the lens",
                                 isOn: Binding(get: { notificationsOn },
                                               set: { on in notificationsOn = on; InmoSession.shared.setNotificationsEnabled(on) }))
                GlassesToggleRow(symbol: "cpu", title: "Relay through ESP32", subtitle: esp32RelaySubtitle, last: true,
                                 isOn: Binding(get: { esp32.relay?.on ?? false },
                                               set: { on in
                                                   if on { notificationsOn = true }  // setRelay turns them on too
                                                   esp32.perform { try await esp32.setRelay(on) }
                                               }))
                    .disabled(esp32.state != .ready || esp32.relay == nil)
            }
            Button { InmoSession.shared.sendTestNotification() } label: {
                Label("Send test notification", jcIcon: "bell.badge.fill")
            }
            .buttonStyle(.jcGlass(full: true))
        }
    }

    /// The paired ESP32 reads the iPhone's notifications instead of the glasses, and Jarvis puts
    /// each one on the lens (Esp32Manager.relayToGlasses).
    private var esp32RelaySubtitle: String {
        guard esp32.state == .ready else { return "Connect your ESP32 board in Wearables first." }
        guard let relay = esp32.relay else { return "Flash ESP32 firmware 1.1 or later." }
        if !relay.on { return "Your ESP32 reads iPhone notifications and Jarvis shows them here." }
        if relay.state == .notShared { return "Settings › Bluetooth › ⓘ on the board › Share System Notifications." }
        return "\(relay.state.label) · \(relay.forwarded) sent"
    }
}

// MARK: - Teleprompter

struct GlassesTeleprompterPage: View {
    @ObservedObject private var session = InmoSession.shared
    @ObservedObject private var actions = GlassesActions.shared
    @State private var title = "Jarvis document"
    @State private var document = ""
    @State private var line = 1
    @State private var percent = 0.0

    var body: some View {
        GlassesSubpage("Teleprompter") {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Document")
                GlassCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Title", text: $title)
                            .font(.body.weight(.semibold))
                        Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
                        TextEditor(text: $document)
                            .frame(minHeight: 160)
                            .scrollContentBackground(.hidden)
                            .accessibilityLabel("Teleprompter document")
                            .overlay(alignment: .topLeading) {
                                if document.isEmpty {
                                    Text("Paste or type what you want to read…").foregroundStyle(JcTheme.muted)
                                        .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                                }
                            }
                    }
                }
                LiveSettingsNote("Send it to the glasses, then Start.")
            }
            HStack(spacing: 10) {
                Button { actions.run("glasses_teleprompter_upload", ["title": title, "text": document]) } label: {
                    Label("Send", jcIcon: "arrow.up.circle")
                }
                .buttonStyle(.jcGlass(full: true))
                .disabled(document.isEmpty || actions.working || !session.isReady)
                Button { actions.run("glasses_teleprompter_start") } label: { Label("Start", jcIcon: "play.fill") }
                    .buttonStyle(.jcGlass(full: true))
                    .disabled(actions.working || !session.isReady)
                Button { actions.run("glasses_teleprompter_stop") } label: { Label("Stop", jcIcon: "stop.fill") }
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                    .disabled(!session.isReady)
            }
            GlassesSection("While reading", note: "Line and percentage are separate positions on the glasses.") {
                GlassRow(symbol: "arrow.left.arrow.right", title: "Page") {
                    HStack(spacing: 6) {
                        Button("Previous") { actions.run("glasses_teleprompter_page", ["direction": "previous"]) }
                        Button("Next") { actions.run("glasses_teleprompter_page", ["direction": "next"]) }
                    }
                    .buttonStyle(.jcGlass(compact: true))
                }
                GlassRow(symbol: "text.line.first.and.arrowtriangle.forward", title: "Line \(line)") {
                    Stepper("", value: $line, in: 1...100000).labelsHidden()
                }
                VStack(spacing: 0) {
                    GlassRow(symbol: "percent", title: "Position") {
                        Text("\(Int(percent))%").font(.subheadline).foregroundStyle(JcTheme.muted)
                    }
                    Slider(value: $percent, in: 0...100, step: 1).tint(JcTheme.accent)
                        .accessibilityLabel("Teleprompter percentage")
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
                GlassRow(symbol: "scope", title: "Go to position", last: true,
                         action: { actions.run("glasses_teleprompter_progress", ["line": line, "percent": percent]) }) {
                    GlassesRowValue(value: nil, chevron: false)
                }
            }
            .disabled(!session.isReady)
            GlassesActionStatus()
        }
        .onAppear {
            actions.clear()
            InmoTeleprompter.shared.install(on: InmoGo3Device.shared)
        }
    }
}

// MARK: - About

struct GlassesAboutPage: View {
    @ObservedObject private var session = InmoSession.shared
    @ObservedObject private var device = InmoGo3Device.shared
    @State private var share = true
    @State private var batteryWindow = "24 hours"
    @State private var confirmForget = false
    private let link = GlassesAudioLink.shared

    var body: some View {
        let details = link.details
        GlassesSubpage("About") {
            GlassesSection(nil, note: staleNote) {
                GlassesInfoRow(symbol: "eyeglasses", title: "Model", value: session.status.model ?? "INMO GO3 · IMG301")
                GlassesInfoRow(symbol: "cpu", title: "Firmware", value: session.status.firmware ?? "—")
                GlassesInfoRow(symbol: "battery.75", title: "Battery", value: session.status.battery.map { "\($0)%" } ?? "—")
                GlassesInfoRow(symbol: "number", title: "Serial", value: session.status.serial ?? "—")
                GlassesInfoRow(symbol: "antenna.radiowaves.left.and.right", title: "Signal",
                               value: session.rssi.map { "\($0) dBm" } ?? "—", last: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Battery")
                GlassCard { batteryChart }
                LiveSettingsNote("Kept for seven days on this iPhone. Charging or a gap starts a new line.")
            }
            GlassesSection("Bluetooth audio") {
                GlassesInfoRow(symbol: "dot.radiowaves.left.and.right", title: "Name", value: link.state.glasses?.name ?? "—")
                GlassesInfoRow(symbol: "waveform", title: "Profiles",
                               value: details.profiles.isEmpty ? "—" : details.profiles.joined(separator: " · "))
                GlassesInfoRow(symbol: "waveform.path", title: "Sample rate",
                               value: details.sampleRate.map { "\(Int(($0 / 1000).rounded())) kHz" } ?? "—")
                GlassesInfoRow(symbol: "timer", title: "Audio delay", value: details.outputLatencyMs.map { "\($0) ms" } ?? "—")
                GlassesInfoRow(symbol: "number", title: "Address", value: link.rememberedKey ?? "—", last: true)
            }
            GlassesSection(nil, note: "The same commands work from this page, chat, voice and automations.") {
                GlassesToggleRow(symbol: "square.and.arrow.up", title: "Share glasses skills with Jarvis",
                                 isOn: $share)
                GlassesLinkRow(symbol: "gearshape.2", title: "Advanced", last: true) { GlassesAdvancedPage() }
            }
            if link.known {
                GlassesSection(nil) {
                    GlassRow(symbol: "xmark.circle", title: "Forget these glasses", last: true, danger: true,
                             action: { confirmForget = true }) { EmptyView() }
                }
            }
        }
        .onAppear { share = BridgeClient.isExposed(device.deviceID) }
        .onChange(of: share) { _, value in BridgeClient.setExposed(value, for: device.deviceID); device.refreshMembership() }
        .alert("Forget these glasses?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { link.forget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Jarvis stops treating this headset as your GO3. Unpair it in Settings › Bluetooth to disconnect it.")
        }
    }

    /// Values are the last the glasses reported; say so when that isn't now.
    private var staleNote: String? {
        guard let date = session.status.lastReceived else {
            return session.isReady ? nil : "Connect the glasses to read these."
        }
        guard !session.isReady || Date().timeIntervalSince(date) > 300 else { return nil }
        return "Last reported \(date.formatted(.relative(presentation: .named)))."
    }

    private var batteryChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Battery history", selection: $batteryWindow) {
                Text("This session").tag("Current session"); Text("24 hours").tag("24 hours")
            }
            .pickerStyle(.segmented)
            let lastConnection = device.history.samples.last?.connection
            let points = device.history.samples.filter {
                batteryWindow == "Current session" ? $0.connection == lastConnection : Date().timeIntervalSince($0.date) <= 24 * 3600
            }
            if points.isEmpty {
                Text("Not enough history yet").font(.footnote).foregroundStyle(JcTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Battery %", point.percent),
                             series: .value("Segment", point.segment.uuidString))
                        .foregroundStyle(JcTheme.accent)
                }
                .chartYScale(domain: 0...100)
                .frame(height: 130)
                .accessibilityLabel("Glasses battery over the selected window")
                if let first = points.first, let last = points.last, first.segment == last.segment {
                    Text("Used \(max(0, first.percent - last.percent))% in \(Int(last.date.timeIntervalSince(first.date) / 60)) min")
                        .font(.footnote).foregroundStyle(JcTheme.muted)
                }
            }
            if let estimate = device.history.estimate(), session.isReady, let last = device.history.samples.last,
               Date().timeIntervalSince(last.date) <= 300 {
                Text(String(format: "About %.1f hours left at %.1f%% an hour", estimate.hoursRemaining, estimate.pointsPerHour))
                    .font(.footnote).foregroundStyle(JcTheme.muted)
            }
        }
    }
}

// MARK: - Advanced

struct GlassesAdvancedPage: View {
    @ObservedObject private var session = InmoSession.shared
    @ObservedObject private var device = InmoGo3Device.shared
    @ObservedObject private var media = InmoMediaTransfer.shared
    @ObservedObject private var actions = GlassesActions.shared

    var body: some View {
        GlassesSubpage("Advanced") {
            GlassesSection("Control link", note: session.lastError.map { "Last error: \($0)" }
                           ?? "Audio and the control link are separate Bluetooth connections.") {
                GlassesInfoRow(symbol: "link", title: "State", value: String(describing: session.state))
                GlassRow(symbol: "power", title: session.isReady ? "Disconnect" : "Connect",
                         action: {
                             Task {
                                 do {
                                     if session.isReady { session.disconnect() }
                                     else { try await session.ensureConnected(force: true) }
                                 } catch { actions.fail("Connect: \(error.localizedDescription) Close INMO and try again.") }
                             }
                         }) { GlassesRowValue(value: nil, chevron: false) }
                GlassRow(symbol: "arrow.clockwise", title: "Refresh status",
                         action: { actions.run("glasses_status", query: true) }) { GlassesRowValue(value: nil, chevron: false) }
                    .disabled(!session.isReady)
                GlassesLinkRow(symbol: "key", title: "Owner identity", last: true) { GlassesOwnerSetupPage() }
            }
            GlassesSection("Diagnostics") {
                GlassesInfoRow(symbol: "square.stack.3d.up", title: "Protocol frames",
                               value: "\(session.counters.validFrames) valid · \(session.counters.invalidFrames) rejected")
                GlassesInfoRow(symbol: "square.grid.2x2", title: "Current module", value: session.status.module.map(String.init) ?? "—")
                if let date = session.status.lastReceived {
                    GlassRow(symbol: "clock", title: "Status received") {
                        Text(date, style: .relative).font(.subheadline).foregroundStyle(JcTheme.muted)
                    }
                }
                GlassesLinkRow(symbol: "list.bullet.rectangle", title: "All controls and availability") {
                    InmoCapabilitiesView(device: device)
                }
                GlassesLinkRow(symbol: "waveform.path.ecg", title: "INMO app traces",
                               subtitle: "Record on your Mac · import, inspect and export", last: true) { InmoTraceView() }
            }
            GlassesSection("Media transfer", note: "The glasses' own Wi-Fi, used when saving photos and videos. The phone's internet pauses while it's joined.") {
                GlassRow(symbol: "wifi", title: "Glasses address", last: true) {
                    TextField("192.168.40.1", text: $media.serverAddress)
                        .keyboardType(.decimalPad).textInputAutocapitalization(.never)
                        .multilineTextAlignment(.trailing).font(.subheadline).foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: 150)
                }
            }
            GlassesSection("Experimental", note: "Controls taken from INMO's app that haven't been tried on every firmware.") {
                GlassesToggleRow(symbol: "flask", title: "Experimental controls", isOn: $device.experimentalEnabled)
                ForEach(InmoGo3Device.settings.keys.sorted(), id: \.self) { setting in
                    GlassRow(symbol: "switch.2", title: Self.settingName(setting)) {
                        HStack(spacing: 6) {
                            Button("On") { actions.run("glasses_settings", ["setting": setting, "enabled": true]) }
                            Button("Off") { actions.run("glasses_settings", ["setting": setting, "enabled": false]) }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                    }
                    .disabled(!session.isReady || !device.experimentalEnabled)
                }
                GlassesLinkRow(symbol: "slider.horizontal.3", title: "Name, language and time", last: true) {
                    GlassesSubpage("Device settings") {
                        GlassCard { InmoAdvancedControlsView().buttonStyle(.jcGlass(compact: true)) }
                    }
                }
            }
            GlassesActionStatus()
        }
        .onAppear { actions.clear() }
    }
}

extension GlassesAdvancedPage {
    /// The firmware's setting keys, as words.
    static func settingName(_ key: String) -> String {
        let names = ["ios_ancs": "Phone notifications (ANCS)", "automatic_illumination": "Auto brightness",
                     "indicator_light": "Indicator light", "system_sounds": "System sounds",
                     "voice_wake": "Voice wake", "wear_detection": "Wear detection"]
        return names[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Reconnecting with the INMO owner identity the official app set up. Reached from the hero's
/// Finish setup and from Advanced.
struct GlassesOwnerSetupPage: View {
    @ObservedObject private var session = InmoSession.shared
    @State private var identity = ""
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        GlassesSubpage("Pairing key") {
            GlassesSection(nil, note: "Jarvis uses the key the INMO app already set up and keeps it in this iPhone's Keychain. It never takes over ownership of the glasses.") {
                GlassRow(symbol: "key.fill", title: "Owner identity", last: true) { EmptyView() }
                SecureField("Paste the owner identity", text: $identity)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 16).padding(.bottom, 14)
            }
            Button { save() } label: { Label("Save and connect", jcIcon: "checkmark.circle") }
                .buttonStyle(.jcGlass(full: true))
                .disabled(identity.isEmpty)
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(failed ? JcTheme.danger : JcTheme.muted)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func save() {
        let clean = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count % 2 == 0, clean.count <= 512 else {
            failed = true; message = "That doesn't look like an owner identity: an even number of hex characters, up to 512."
            return
        }
        var bytes = Data(); var index = clean.startIndex
        while index < clean.endIndex {
            let end = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<end], radix: 16) else {
                failed = true; message = "That has characters that aren't hex."
                return
            }
            bytes.append(byte); index = end
        }
        do {
            try session.setOwnerIdentity(bytes)
            identity = ""; failed = false; message = "Saved. Connecting…"
            Task {
                do { try await session.ensureConnected(force: true); message = "Connected." }
                catch { failed = true; message = error.localizedDescription }
            }
        } catch { failed = true; message = error.localizedDescription }
    }
}

// MARK: - Get started

/// Ticks itself: pairing from the route, the speaker test from where it played, and the mic
/// from the first voice turn that ran through the glasses.
struct GlassesSetupPage: View {
    @State private var speakerTest = GlassesSpeakerTest()
    private let link = GlassesAudioLink.shared

    var body: some View {
        GlassesSubpage("Get started") {
            GlassesSection(nil) {
                step(1, "Pair the glasses", "Pairing mode on the glasses, then Settings › Bluetooth", done: link.known) {
                    if let url = URL(string: "App-Prefs:root=Bluetooth") {
                        Link("Open", destination: url).font(.subheadline.weight(.semibold)).foregroundStyle(JcTheme.accent)
                    }
                }
                step(2, "Hear Jarvis in them", "Play the speaker test with the glasses connected", done: link.heardSpeakers) {
                    Button("Play") { speakerTest.play() }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(!link.state.connected || speakerTest.speaking)
                }
                step(3, "Talk through them", "Start Voice with the glasses on; their mics carry the turn",
                     done: link.usedMic, last: true) {
                    Button("Talk") { Task { await InmoAIChannel.shared.startFromPhone() } }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(!link.state.connected)
                }
            }
        }
        .onDisappear { speakerTest.stop() }
    }

    private func step<Action: View>(_ number: Int, _ title: String, _ subtitle: String, done: Bool, last: Bool = false,
                                    @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(done ? JcTheme.success.opacity(0.18) : JcTheme.accent.opacity(0.14))
                    if done {
                        JcIcon("checkmark", size: 13, weight: .bold).foregroundStyle(JcTheme.success)
                    } else {
                        Text("\(number)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(JcTheme.accent)
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(JcText.body.weight(.semibold))
                        .foregroundStyle(done ? JcTheme.muted : JcTheme.text)
                        .strikethrough(done, color: JcTheme.muted)
                    Text(subtitle).font(JcText.small).foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !done { action() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if !last { Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 68) }
        }
    }
}

// MARK: - Capabilities

struct InmoCapabilitiesView: View {
    @ObservedObject var device: InmoGo3Device

    var body: some View {
        GlassesSubpage("GO3 controls") {
            GlassesSection(nil) {
                ForEach(Array(InmoGo3Device.inventory.enumerated()), id: \.element.id) { index, entry in
                    let reason = device.inventorySnapshot().first(where: { $0["id"] as? String == entry.id })?["reason"] as? String
                    GlassRow(symbol: reason == nil ? "checkmark.circle" : "minus.circle", title: entry.title,
                             subtitle: reason ?? entry.evidence, subtitleLineLimit: 3,
                             last: index == InmoGo3Device.inventory.count - 1) { EmptyView() }
                }
            }
        }
    }
}

// MARK: - Audio route button

/// The system's audio-route button — the same picker as Control Center's.
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(JcTheme.accent)
        picker.activeTintColor = UIColor(JcTheme.accent)
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
