import AVFoundation
import SwiftUI

/// The pod's card in the Wearables list.
struct JarvisPodCard: View {
    let pod: JarvisPodDevice
    let status: JarvisPodStatus?

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
                Text(pod.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text(pod.bridgeConnected ? "Home: \(status?.homeTitle ?? "Orb")" : "Jarvis Pod")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if pod.bridgeConnected {
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
        .lastSeenCorner(pod.lastSeen, visible: !pod.bridgeConnected)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

/// The pod's page, pushed from the card. Every control is a `pod_*` skill.
struct JarvisPodView: View {
    let podID: String
    @State private var store = JarvisPodStore.shared
    @State private var voiceChoice: PodVoiceChoice

    init(podID: String) {
        self.podID = podID
        _voiceChoice = State(initialValue: PodVoiceChoice(podID: podID))
    }

    @State private var brightness: Double = 0
    @State private var volume: Double = 0
    @State private var confirmReboot = false
    @State private var confirmRevoke = false
    @State private var showSetupHelp = false
    @State private var pendingDelete: JarvisPodHome?
    @State private var refreshing = false
    @State private var player = PodRecordingPlayer()
    @State private var renaming = false
    @State private var recordingsShown = 30
    @State private var speech = SpeechEngineStore.shared

    private var pod: JarvisPodDevice? { store.pods.first { $0.id == podID } }
    private var status: JarvisPodStatus? { store.statuses[podID] }
    private var settings: JarvisPodSettings? { store.settings[podID] }
    private var online: Bool { pod?.bridgeConnected == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
              VStack(alignment: .leading, spacing: 26) {
                hero
                if let error = store.error {
                    Label(error, jcIcon: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(JcTheme.danger)
                }
                homeSection
                group("Display & sound") {
                    slider("Brightness", "sun.max.fill", value: $brightness) { v in
                        Task { await store.update(podID, ["brightness": Int(v)]) }
                    }
                    divider
                    slider("Volume", "speaker.wave.2.fill", value: $volume) { v in
                        Task { await store.update(podID, ["volume": Int(v)]) }
                    }
                }
                group("Voice & clock") {
                    toggle("Wake word", "Say \u{201C}Jarvis\u{201D} to start talking", "waveform",
                           isOn: Binding(get: { settings?.wakeWord ?? true },
                                         set: { on in Task { await store.update(podID, ["wake_word": on]) } }))
                    divider
                    toggle("Noise cancelling", "Filters out hum on the pod and cleans recordings", "waveform.badge.minus",
                           isOn: Binding(get: { settings?.noiseCancel ?? true },
                                         set: { on in Task { await store.update(podID, ["noise_cancel": on]) } }))
                    divider
                    endPause
                    divider
                    toggle("24-hour time", "For the clock home screen", "clock",
                           isOn: Binding(get: { settings?.clock24h ?? JarvisPodLook.clock24h },
                                         set: { on in Task { await store.update(podID, ["clock_24h": on]) } }))
                }
                deviceSection
              }
              .disabled(!online)
                talkingSection     // kept on the server: usable while the pod is offline
                recordingsSection  // stored on the server: usable while the pod is offline
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
                        JcIcon("arrow.clockwise").foregroundStyle(JcTheme.accent)
                    }
                }
                .accessibilityLabel("Refresh")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", jcIcon: "pencil") { renaming = true }
                    Button("Restart", jcIcon: "arrow.clockwise") { confirmReboot = true }
                    Button("Set up again", jcIcon: "qrcode") { showSetupHelp = true }
                    Button("Revoke", jcIcon: "xmark.octagon", role: .destructive) { confirmRevoke = true }
                } label: {
                    JcIcon("ellipsis").foregroundStyle(JcTheme.accent)
                }
            }
        }
        .task { await reload() }
        .task { await speech.load() }
        .task { await voiceChoice.load() }
        .onDisappear { player.stop() }
        .wearableRename(isPresented: $renaming, current: pod?.name ?? "Jarvis Pod") { name in
            guard !name.isEmpty else { return }
            Task { await store.rename(podID, to: name) }
        }
        .confirmationDialog("Delete \u{201C}\(pendingDelete?.title ?? "")\u{201D}?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let home = pendingDelete { Task { await store.deleteHome(podID, home: home.id) } }
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
            Text("Hold the pod's BOOT button for 5 seconds. It forgets its Wi-Fi and pairing and shows a new QR code — scan it from Devices.")
        }
        .confirmationDialog("Restart the pod?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Restart") { Task { await store.reboot(podID) } }
        }
        .confirmationDialog("Revoke this pod?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                Task {
                    try? await DevicesAPI().revoke(podID)
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
            Text(pod?.name ?? "Jarvis Pod")
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
            JcIcon(symbol).font(.caption2.weight(.bold)).foregroundStyle(tint)
            Text(text).font(.footnote.weight(.semibold)).foregroundStyle(JcTheme.text).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .jcLiquidGlass(in: Capsule())
    }

    private func reload() async {
        refreshing = true
        await store.refresh(force: true)
        await store.loadRecordings(podID)
        if online { await store.loadDetail(podID) }
        refreshing = false
    }

    private var offlineText: String {
        if let note = DisconnectedPill.lastSeenNote(pod?.lastSeen) { return "Offline · \(note)" }
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
                    let homes = store.homes[podID] ?? [JarvisPodHome(id: "orb", title: "Orb", builtin: true),
                                                        JarvisPodHome(id: "clock", title: "Clock", builtin: true)]
                    ForEach(homes) { home in
                        homeTile(home, selected: (settings?.home ?? status?.home) == home.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    private func homeTile(_ home: JarvisPodHome, selected: Bool) -> some View {
        Button {
            Task { await store.update(podID, ["home": home.id]) }
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
                            JcIcon("xmark", size: 10, weight: .bold)
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
                Button("Delete", jcIcon: "trash", role: .destructive) {
                    Task { await store.deleteHome(podID, home: home.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func homePreview(_ home: JarvisPodHome, selected: Bool) -> some View {
        // The current home shows the pod's real screen (a live screenshot).
        if selected && store.loadingScreens.contains(podID) {
            ProgressView().tint(JcTheme.accent)
        } else if selected, let data = store.screens[podID], let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            builtinPreview(home)
        }
    }

    @ViewBuilder
    private func builtinPreview(_ home: JarvisPodHome) -> some View {
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
            JcIcon("sparkles", size: 26, weight: .medium).foregroundStyle(JcTheme.accent)
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
        let all = store.recordings[podID] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            header("Recordings", trailing: all.isEmpty ? nil : "\(all.count)")
            if all.isEmpty {
                GlassCard {
                    Text("Everything you say to the pod is kept here for 30 days.")
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
                                    await store.deleteRecording(podID, rec)
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

    private func recordingRow(_ rec: JarvisPodRecording) -> some View {
        let playing = player.playingID == rec.id
        return HStack(spacing: 12) {
            Button {
                player.toggle(rec) { try await store.recordingAudio(podID, rec) }
            } label: {
                ZStack {
                    Circle().fill(JcTheme.accent.opacity(0.16))
                    if player.loadingID == rec.id {
                        ProgressView().tint(JcTheme.accent)
                    } else {
                        JcIcon(playing ? "pause.fill" : "play.fill")
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
                HStack(spacing: 6) {
                    Text("\(rec.date.formatted(date: .abbreviated, time: .shortened)) · \(rec.durationText)")
                        .font(.caption.monospacedDigit()).foregroundStyle(JcTheme.muted)
                    if rec.cleaned {
                        Text("Cleaned")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(JcTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(JcTheme.accent.opacity(0.14), in: Capsule())
                    }
                }
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
        JcIcon(symbol)
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

    /// How long a pause ends your turn. Longer lets you think mid-sentence; shorter
    /// answers sooner.
    private var endPause: some View {
        let current = settings?.endPauseMs ?? 1000
        return HStack(spacing: 12) {
            iconTile("timer")
            VStack(alignment: .leading, spacing: 2) {
                Text("Pause before Jarvis answers").font(.body.weight(.medium)).foregroundStyle(JcTheme.text)
                Text("How long you can pause mid-sentence").font(.caption).foregroundStyle(JcTheme.muted)
            }
            Spacer()
            Menu {
                ForEach(JarvisPodSettings.endPauseChoices, id: \.self) { ms in
                    Button {
                        Task { await store.update(podID, ["end_pause_ms": ms]) }
                    } label: {
                        if ms == current {
                            Label(JarvisPodSettings.endPauseLabel(ms), jcIcon: "checkmark")
                        } else {
                            Text(JarvisPodSettings.endPauseLabel(ms))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(JarvisPodSettings.endPauseLabel(current))
                    JcIcon("chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(JcTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The chat and model the Pod talks to, and the engine that hears it — the
    /// Pod's own voice settings, like the phone's.
    private var talkingSection: some View {
        group("Talking to Jarvis") {
            NavigationLink { PodChatPicker(choice: voiceChoice) } label: {
                navRow("bubble.left.and.bubble.right", "Chat", voiceChoice.chatTitle)
            }
            .buttonStyle(.plain)
            divider
            NavigationLink { PodModelPicker(choice: voiceChoice) } label: {
                navRow("cpu", "Model", voiceChoice.modelTitle)
            }
            .buttonStyle(.plain)
            divider
            speechModel
        }
    }

    private func navRow(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            iconTile(symbol)
            Text(label).font(.body.weight(.medium)).foregroundStyle(JcTheme.text)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(JcTheme.muted).lineLimit(1)
            JcIcon("chevron.right").font(.caption.weight(.semibold)).foregroundStyle(JcTheme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Which engine hears what you say to the Pod: Soniox, or the server's own
    /// model. A server setting, so it is the same for every Pod.
    private var speechModel: some View {
        let s = speech.settings
        let options = s.engines.filter { $0.available || $0.name == s.pod }
        return HStack(spacing: 12) {
            iconTile("text.bubble")
            VStack(alignment: .leading, spacing: 2) {
                Text("Speech model").font(.body.weight(.medium)).foregroundStyle(JcTheme.text)
                Text(speech.error.isEmpty ? "What turns your voice into text" : speech.error)
                    .font(.caption)
                    .foregroundStyle(speech.error.isEmpty ? JcTheme.muted : JcTheme.danger)
            }
            Spacer()
            Menu {
                ForEach(options) { engine in
                    Button {
                        Task { await speech.setSurface("pod", to: engine.name) }
                    } label: {
                        if engine.name == s.pod { Label(engine.label, jcIcon: "checkmark") } else { Text(engine.label) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(speech.loaded ? s.label(for: s.pod) : "…").lineLimit(1)
                    JcIcon("chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(JcTheme.accent)
            }
            .disabled(!speech.loaded || options.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

private enum PodPlaybackError: LocalizedError {
    case refused
    var errorDescription: String? { "the phone's audio would not start" }
}

/// Plays one pod recording at a time (downloaded on first play).
@Observable
@MainActor
final class PodRecordingPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: String?
    private(set) var loadingID: String?
    private(set) var error: String?
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var cache: [String: Data] = [:]
    @ObservationIgnored private var request = 0

    func toggle(_ rec: JarvisPodRecording, load: @escaping () async throws -> Data) {
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
                // Through the arbiter: setting the category here was refused
                // ('!pri') whenever the keepalive, Voice or Live held the session.
                try AudioSessionArbiter.shared.hold(.playback)
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                guard player.play() else { throw PodPlaybackError.refused }
                audio = player
                playingID = rec.id
            } catch {
                loadingID = nil
                try? AudioSessionArbiter.shared.release(.playback)
                self.error = "Couldn't play that recording: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        request += 1
        if audio != nil { try? AudioSessionArbiter.shared.release(.playback) }
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
                    JcIcon("trash.fill", size: 16, weight: .semibold)
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
