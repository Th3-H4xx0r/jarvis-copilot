import SwiftUI

/// The ball's card in the Wearables list.
struct JarvisBallCard: View {
    let ball: JarvisBallDevice
    let status: JarvisBallStatus?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                BallGlyph(size: 104)
                    .padding(.trailing, 22)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(ball.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text("Jarvis Ball").font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                if let status, ball.bridgeConnected {
                    Text("Home: \(status.homeTitle)").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if ball.bridgeConnected {
                        MetricPill(icon: "checkmark.circle.fill", label: "Status", value: "Connected", tint: JcTheme.accent)
                        if let level = status?.battery {
                            MetricPill(icon: status?.charging == true ? "bolt.fill" : "battery.75", label: "Battery",
                                       value: "\(level)%", tint: JcTheme.success)
                        }
                        if let rssi = status?.rssi {
                            MetricPill(icon: "wifi", label: "Wi-Fi", value: "\(rssi) dBm", tint: JcTheme.accent)
                        }
                    } else {
                        DisconnectedPill()
                    }
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .lastSeenCorner(ball.lastSeen, visible: !ball.bridgeConnected)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

/// A small static orb in the accent: the ball's signature look.
struct BallGlyph: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(JcTheme.accent.opacity(0.18)).frame(width: size, height: size)
            Circle().fill(JcTheme.accent.opacity(0.35)).frame(width: size * 0.72, height: size * 0.72)
            Circle().fill(JcAccent.bright).frame(width: size * 0.44, height: size * 0.44)
                .shadow(color: JcTheme.accent.opacity(0.8), radius: size * 0.12)
        }
        .allowsHitTesting(false)
    }
}

/// The ball's settings page, pushed from the card. Every control is a `ball_*` skill.
struct JarvisBallView: View {
    let ballID: String
    @State private var store = JarvisBallStore.shared
    @State private var brightness: Double = 0
    @State private var volume: Double = 0
    @State private var confirmReboot = false
    @State private var confirmRevoke = false
    @State private var showSetupHelp = false

    private var ball: JarvisBallDevice? { store.balls.first { $0.id == ballID } }
    private var status: JarvisBallStatus? { store.statuses[ballID] }
    private var settings: JarvisBallSettings? { store.settings[ballID] }
    private var online: Bool { ball?.bridgeConnected == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !online {
                    Text(offlineText)
                        .font(.subheadline)
                        .foregroundStyle(JcTheme.muted)
                }
                if let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(JcTheme.danger)
                }
                homeSection
                section("Display & sound") {
                    slider("Brightness", "sun.max.fill", value: $brightness) { v in
                        Task { await store.update(ballID, ["brightness": Int(v)]) }
                    }
                    slider("Volume", "speaker.wave.2.fill", value: $volume) { v in
                        Task { await store.update(ballID, ["volume": Int(v)]) }
                    }
                }
                section("Voice") {
                    Toggle(isOn: Binding(get: { settings?.wakeWord ?? true },
                                         set: { on in Task { await store.update(ballID, ["wake_word": on]) } })) {
                        Label("Wake word \u{201C}Jarvis\u{201D}", systemImage: "waveform").foregroundStyle(JcTheme.text)
                    }
                    .tint(JcTheme.accent)
                }
                section("Clock") {
                    Toggle(isOn: Binding(get: { settings?.clock24h ?? JarvisBallLook.clock24h },
                                         set: { on in Task { await store.update(ballID, ["clock_24h": on]) } })) {
                        Label("24-hour time", systemImage: "clock").foregroundStyle(JcTheme.text)
                    }
                    .tint(JcTheme.accent)
                }
                deviceSection
            }
            .padding(16)
            .disabled(!online)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle(ball?.name ?? "Jarvis Ball")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Set up again", systemImage: "qrcode") { showSetupHelp = true }
                    Button("Revoke", systemImage: "xmark.octagon", role: .destructive) { confirmRevoke = true }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(JcTheme.accent)
                }
            }
        }
        .task {
            await store.refresh(force: true)
            if online { await store.loadDetail(ballID) }
        }
        .onChange(of: settings) { _, s in
            if let s {
                brightness = Double(s.brightness)
                volume = Double(s.volume)
            }
        }
        .alert("Set up again", isPresented: $showSetupHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Hold the ball's BOOT button for 5 seconds. It forgets its Wi-Fi and pairing and shows a new QR code — scan it from Devices.")
        }
        .confirmationDialog("Restart the ball?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Restart") { Task { await store.reboot(ballID) } }
        }
        .confirmationDialog("Revoke this ball?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                Task {
                    try? await DevicesAPI().revoke(ballID)
                    await store.refresh(force: true)
                }
            }
        } message: {
            Text("It stops reaching Jarvis until it's set up again.")
        }
    }

    private var offlineText: String {
        if let note = DisconnectedPill.lastSeenNote(ball?.lastSeen) { return "The ball is offline, last seen \(note)." }
        return "The ball is offline."
    }

    private var header: some View {
        HStack(spacing: 16) {
            BallGlyph(size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(ball?.name ?? "Jarvis Ball").font(.title3.weight(.semibold)).foregroundStyle(JcTheme.text)
                Text(headerLine).font(.subheadline).foregroundStyle(online ? JcTheme.accent : JcTheme.muted)
            }
        }
    }

    private var headerLine: String {
        guard online else { return "Offline" }
        var parts = ["Connected"]
        if let level = status?.battery { parts.append("\(level)%") }
        if let ssid = status?.ssid, !ssid.isEmpty { parts.append(ssid) }
        return parts.joined(separator: " · ")
    }

    private var homeSection: some View {
        section("Home screen") {
            let homes = store.homes[ballID] ?? [JarvisBallHome(id: "orb", title: "Orb", builtin: true),
                                                 JarvisBallHome(id: "clock", title: "Clock", builtin: true)]
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(homes) { home in
                    let selected = (settings?.home ?? status?.home) == home.id
                    Button {
                        Task { await store.update(ballID, ["home": home.id]) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: home.id == "orb" ? "circle.circle.fill" : home.id == "clock" ? "clock.fill" : "sparkles")
                                .font(.title2)
                                .foregroundStyle(selected ? JcTheme.accent : JcTheme.muted)
                            Text(home.title).font(.subheadline.weight(.semibold)).foregroundStyle(JcTheme.text).lineLimit(1)
                            Text(home.builtin ? "Built in" : "Made by Jarvis").font(.caption).foregroundStyle(JcTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(selected ? JcTheme.accent.opacity(0.14) : JcTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(selected ? JcTheme.accent : .white.opacity(0.06), lineWidth: selected ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !home.builtin {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await store.deleteHome(ballID, home: home.id) }
                            }
                        }
                    }
                }
            }
            Text("Ask Jarvis to design a new home page, by voice or chat.")
                .font(.footnote).foregroundStyle(JcTheme.muted)
        }
    }

    private var deviceSection: some View {
        section("Device") {
            infoRow("Wi-Fi", status.map { $0.ssid.isEmpty ? "—" : "\($0.ssid)\($0.rssi.map { " · \($0) dBm" } ?? "")" } ?? "—")
            infoRow("Battery", status?.battery.map { "\($0)%\(status?.charging == true ? " · charging" : "")" } ?? "—")
            infoRow("Firmware", status?.firmware ?? "—")
            infoRow("IP address", status?.ip.isEmpty == false ? status!.ip : "—")
            Button("Restart", systemImage: "arrow.clockwise") { confirmReboot = true }
                .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(JcTheme.muted).textCase(.uppercase)
            content()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(JcTheme.muted)
            Spacer()
            Text(value).foregroundStyle(JcTheme.text).lineLimit(1)
        }
        .font(.subheadline)
    }

    private func slider(_ title: String, _ icon: String, value: Binding<Double>, onCommit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(JcTheme.accent).frame(width: 22)
            Text(title).foregroundStyle(JcTheme.text).frame(width: 84, alignment: .leading)
            Slider(value: value, in: 0...100, step: 1) { editing in
                if !editing { onCommit(value.wrappedValue) }
            }
            .tint(JcTheme.accent)
            Text("\(Int(value.wrappedValue))%").font(.caption.monospacedDigit()).foregroundStyle(JcTheme.muted).frame(width: 40)
        }
    }
}
