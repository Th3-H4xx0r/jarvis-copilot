import AVFoundation
import SwiftUI

/// The ball's card in the Wearables list.
struct JarvisBallCard: View {
    let ball: JarvisBallDevice
    let status: JarvisBallStatus?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                VoiceOrb(state: .idle, amplitude: 0, size: 112, animating: false)
                    .frame(width: 112, height: 112)
                    .padding(.trailing, 18)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(ball.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text(ball.bridgeConnected ? "Home: \(status?.homeTitle ?? "Orb")" : "Jarvis Ball")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if ball.bridgeConnected {
                        MetricPill(icon: "checkmark.circle.fill", label: "Status", value: "Connected", tint: JcTheme.accent)
                        if let level = status?.battery {
                            MetricPill(icon: status?.charging == true ? "bolt.fill" : "battery.75", label: "Battery",
                                       value: "\(level)%", tint: JcTheme.success)
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

/// The ball's page, pushed from the card. Every control is a `ball_*` skill.
struct JarvisBallView: View {
    let ballID: String
    @State private var store = JarvisBallStore.shared
    @State private var brightness: Double = 0
    @State private var volume: Double = 0
    @State private var confirmReboot = false
    @State private var confirmRevoke = false
    @State private var showSetupHelp = false
    @State private var pendingDelete: JarvisBallHome?
    @State private var refreshing = false
    @State private var player = BallRecordingPlayer()
    @State private var recordingsShown = 30

    private var ball: JarvisBallDevice? { store.balls.first { $0.id == ballID } }
    private var status: JarvisBallStatus? { store.statuses[ballID] }
    private var settings: JarvisBallSettings? { store.settings[ballID] }
    private var online: Bool { ball?.bridgeConnected == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
              VStack(alignment: .leading, spacing: 26) {
                hero
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(JcTheme.danger)
                }
                homeSection
                group("Display & sound") {
                    slider("Brightness", "sun.max.fill", value: $brightness) { v in
                        Task { await store.update(ballID, ["brightness": Int(v)]) }
                    }
                    divider
                    slider("Volume", "speaker.wave.2.fill", value: $volume) { v in
                        Task { await store.update(ballID, ["volume": Int(v)]) }
                    }
                }
                group("Voice & clock") {
                    toggle("Wake word", "Say \u{201C}Jarvis\u{201D} to start talking", "waveform",
                           isOn: Binding(get: { settings?.wakeWord ?? true },
                                         set: { on in Task { await store.update(ballID, ["wake_word": on]) } }))
                    divider
                    toggle("24-hour time", "For the clock home screen", "clock",
                           isOn: Binding(get: { settings?.clock24h ?? JarvisBallLook.clock24h },
                                         set: { on in Task { await store.update(ballID, ["clock_24h": on]) } }))
                }
                deviceSection
              }
              .disabled(!online)
                recordingsSection  // stored on the server: usable while the ball is offline
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .refreshable { await reload() }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    if refreshing {
                        ProgressView().tint(JcTheme.accent)
                    } else {
                        Image(systemName: "arrow.clockwise").foregroundStyle(JcTheme.accent)
                    }
                }
                .accessibilityLabel("Refresh")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Restart", systemImage: "arrow.clockwise") { confirmReboot = true }
                    Button("Set up again", systemImage: "qrcode") { showSetupHelp = true }
                    Button("Revoke", systemImage: "xmark.octagon", role: .destructive) { confirmRevoke = true }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(JcTheme.accent)
                }
            }
        }
        .task { await reload() }
        .onDisappear { player.stop() }
        .confirmationDialog("Delete \u{201C}\(pendingDelete?.title ?? "")\u{201D}?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let home = pendingDelete { Task { await store.deleteHome(ballID, home: home.id) } }
                pendingDelete = nil
            }
        }
        .onChange(of: settings, initial: true) { _, s in
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

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            VoiceOrb(state: online ? .idle : .error, amplitude: 0, size: 168, animating: false)
                .frame(height: 168)
                .opacity(online ? 1 : 0.55)
            Text(ball?.name ?? "Jarvis Ball")
                .font(.title.weight(.bold))
                .foregroundStyle(JcTheme.text)
            HStack(spacing: 8) {
                chip(online ? "Connected" : offlineText, symbol: online ? "circle.fill" : "moon.zzz.fill",
                     tint: online ? JcTheme.accent : JcTheme.muted)
                if online, let level = status?.battery {
                    chip("\(level)%", symbol: status?.charging == true ? "bolt.fill" : batterySymbol(level), tint: JcTheme.success)
                }
                if online, let rssi = status?.rssi {
                    chip(signalText(rssi), symbol: "wifi", tint: JcTheme.text)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundStyle(tint)
            Text(text).font(.footnote.weight(.semibold)).foregroundStyle(JcTheme.text).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .jcLiquidGlass(in: Capsule())
    }

    private func reload() async {
        refreshing = true
        await store.refresh(force: true)
        await store.loadRecordings(ballID)
        if online { await store.loadDetail(ballID) }
        refreshing = false
    }

    private var offlineText: String {
        if let note = DisconnectedPill.lastSeenNote(ball?.lastSeen) { return "Offline · \(note)" }
        return "Offline"
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }

    private func signalText(_ rssi: Int) -> String {
        rssi >= -60 ? "Strong" : rssi >= -72 ? "Good" : "Weak"
    }

    // MARK: Home screen

    private var homeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Home screen", trailing: "Ask Jarvis for a new one")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    let homes = store.homes[ballID] ?? [JarvisBallHome(id: "orb", title: "Orb", builtin: true),
                                                        JarvisBallHome(id: "clock", title: "Clock", builtin: true)]
                    ForEach(homes) { home in
                        homeTile(home, selected: (settings?.home ?? status?.home) == home.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    private func homeTile(_ home: JarvisBallHome, selected: Bool) -> some View {
        Button {
            Task { await store.update(ballID, ["home": home.id]) }
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.05))
                    homePreview(home, selected: selected)
                }
                .frame(width: 92, height: 92)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(selected ? JcTheme.accent : Color.white.opacity(0.1), lineWidth: selected ? 2.5 : 1))
                .shadow(color: selected ? JcTheme.accent.opacity(0.35) : .clear, radius: 12)
                .overlay(alignment: .topTrailing) {
                    if !home.builtin {
                        Button { pendingDelete = home } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(JcTheme.text)
                                .frame(width: 24, height: 24)
                                .jcLiquidGlass(in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(home.title)")
                        .offset(x: 4, y: -2)
                    }
                }
                VStack(spacing: 2) {
                    Text(home.title).font(.subheadline.weight(.semibold)).foregroundStyle(JcTheme.text).lineLimit(1)
                    Text(selected ? "Current" : home.builtin ? "Built in" : "Made by Jarvis")
                        .font(.caption).foregroundStyle(selected ? JcTheme.accent : JcTheme.muted)
                }
            }
            .frame(width: 108)
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

    @ViewBuilder
    private func homePreview(_ home: JarvisBallHome, selected: Bool) -> some View {
        // The current home shows the ball's real screen (a live screenshot).
        if selected && store.loadingScreens.contains(ballID) {
            ProgressView().tint(JcTheme.accent)
        } else if selected, let data = store.screens[ballID], let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            builtinPreview(home)
        }
    }

    @ViewBuilder
    private func builtinPreview(_ home: JarvisBallHome) -> some View {
        switch home.id {
        case "orb":
            VoiceOrb(state: .idle, amplitude: 0, size: 64, animating: false).frame(width: 64, height: 64)
        case "clock":
            VStack(spacing: 1) {
                Text(Date.now, format: .dateTime.hour().minute())
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(JcTheme.text)
                Text(Date.now, format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(JcTheme.muted)
            }
        default:
            Image(systemName: "sparkles").font(.system(size: 26, weight: .medium)).foregroundStyle(JcTheme.accent)
        }
    }

    // MARK: Device

    private var deviceSection: some View {
        group("Device") {
            info("wifi", "Wi-Fi", status.map { $0.ssid.isEmpty ? "—" : "\($0.ssid)\($0.rssi.map { " · \($0) dBm" } ?? "")" } ?? "—")
            divider
            info("battery.75", "Battery", status?.battery.map { "\($0)%\(status?.charging == true ? " · charging" : "")" } ?? "—")
            divider
            info("cpu", "Firmware", status?.firmware ?? "—")
            divider
            info("network", "IP address", status?.ip.isEmpty == false ? status!.ip : "—")
        }
    }

    // MARK: Recordings

    private var recordingsSection: some View {
        let all = store.recordings[ballID] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            header("Recordings", trailing: all.isEmpty ? nil : "\(all.count)")
            if all.isEmpty {
                GlassCard {
                    Text("Everything you say to the ball is kept here for 30 days.")
                        .font(.subheadline).foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                GlassCard(padding: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(all.prefix(recordingsShown).enumerated()), id: \.element.id) { index, rec in
                            if index > 0 { divider }
                            SwipeToDelete {
                                Task {
                                    if player.playingID == rec.id { player.stop() }
                                    await store.deleteRecording(ballID, rec)
                                }
                            } content: {
                                recordingRow(rec)
                            }
                        }
                    }
                }
                if all.count > recordingsShown {
                    Button("Show more") { recordingsShown += 30 }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(JcTheme.accent)
                        .frame(maxWidth: .infinity)
                }
            }
            if let error = player.error {
                Text(error).font(.caption).foregroundStyle(JcTheme.danger).padding(.horizontal, 4)
            }
        }
    }

    private func recordingRow(_ rec: JarvisBallRecording) -> some View {
        let playing = player.playingID == rec.id
        return HStack(spacing: 12) {
            Button {
                player.toggle(rec) { try await store.recordingAudio(ballID, rec) }
            } label: {
                ZStack {
                    Circle().fill(JcTheme.accent.opacity(0.16))
                    if player.loadingID == rec.id {
                        ProgressView().tint(JcTheme.accent)
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(JcTheme.accent)
                    }
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Pause" : "Play")
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.transcript.isEmpty ? "No words recognised" : rec.transcript)
                    .font(.subheadline)
                    .foregroundStyle(rec.transcript.isEmpty ? JcTheme.muted : JcTheme.text)
                    .lineLimit(2)
                Text("\(rec.date.formatted(date: .abbreviated, time: .shortened)) · \(rec.durationText)")
                    .font(.caption.monospacedDigit()).foregroundStyle(JcTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: Building blocks

    private func header(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline).foregroundStyle(JcTheme.text)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(JcTheme.muted) }
        }
        .padding(.horizontal, 4)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title)
            GlassCard(padding: 0) {
                VStack(spacing: 0) { content() }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 52)
    }

    private func iconTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(JcTheme.accent)
            .frame(width: 30, height: 30)
            .background(JcTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func slider(_ title: String, _ symbol: String, value: Binding<Double>, onCommit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                iconTile(symbol)
                Text(title).font(.body.weight(.medium)).foregroundStyle(JcTheme.text)
                Spacer()
                Text("\(Int(value.wrappedValue))%").font(.subheadline.monospacedDigit()).foregroundStyle(JcTheme.muted)
            }
            Slider(value: value, in: 0...100, step: 1) { editing in
                if !editing { onCommit(value.wrappedValue) }
            }
            .tint(JcTheme.accent)
            .padding(.leading, 42)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func toggle(_ title: String, _ subtitle: String, _ symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            iconTile(symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(JcTheme.text)
                Text(subtitle).font(.caption).foregroundStyle(JcTheme.muted)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(JcTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func info(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            iconTile(symbol)
            Text(label).font(.body).foregroundStyle(JcTheme.text)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(JcTheme.muted).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Plays one ball recording at a time (downloaded on first play).
@Observable
@MainActor
final class BallRecordingPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: String?
    private(set) var loadingID: String?
    private(set) var error: String?
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var cache: [String: Data] = [:]
    @ObservationIgnored private var request = 0

    func toggle(_ rec: JarvisBallRecording, load: @escaping () async throws -> Data) {
        if playingID == rec.id { return stop() }
        stop()
        error = nil
        request += 1
        let token = request
        Task {
            do {
                var data = cache[rec.id]
                if data == nil {
                    loadingID = rec.id
                    data = try await load()
                    cache[rec.id] = data
                }
                guard token == self.request, let data else { return }  // stopped or replaced meanwhile
                loadingID = nil
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.play()
                audio = player
                playingID = rec.id
            } catch {
                loadingID = nil
                self.error = "Couldn't play that recording: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        request += 1
        audio?.stop()
        audio = nil
        playingID = nil
        loadingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            if let audio = self.audio, ObjectIdentifier(audio) == finished { self.stop() }
        }
    }
}

/// Drag a row left to reveal Delete (the page is a ScrollView, so no List swipe actions).
private struct SwipeToDelete<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var base: CGFloat = 0
    private let revealed: CGFloat = -84

    var body: some View {
        content()
            .offset(x: offset)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Button(role: .destructive) {
                    close()
                    onDelete()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: -revealed)
                        .frame(maxHeight: .infinity)
                        .background(JcTheme.danger)
                }
                .offset(x: -revealed + offset)
                .allowsHitTesting(offset < 0)
                .accessibilityLabel("Delete")
            }
            .clipped()
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { g in
                        guard abs(g.translation.width) > abs(g.translation.height) else { return }
                        offset = min(0, max(revealed * 1.4, base + g.translation.width))
                    }
                    .onEnded { g in
                        withAnimation(.snappy) {
                            offset = base + g.translation.width < revealed / 2 ? revealed : 0
                        }
                        base = offset
                    }
            )
    }

    private func close() {
        withAnimation(.snappy) { offset = 0 }
        base = 0
    }
}
