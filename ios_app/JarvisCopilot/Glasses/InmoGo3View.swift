import AVKit
import SwiftUI

// MARK: - Card

/// The glasses' card in the Devices list. Always shown — it is how the glasses are found
/// before they have ever been paired — and lit up while iOS has them on the audio route.
///
/// "Connected" means on the audio route: that is all iOS tells an app about a headset,
/// so a pair playing nothing, or sending audio to the iPhone, reads "Not on audio".
struct GlassesCard: View {
    let route: GlassesRouteState
    /// Nil until the glasses have been on the route once (or since they were forgotten).
    let lastSeen: Date?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                // Turning costs a continuous render; a card for glasses never seen stays still.
                GlassesSceneView(spin: route.connected || lastSeen != nil, lit: route.connected)
                    .frame(width: 124, height: 124)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(InmoGo3.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("INMO GO3 smart glasses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if route.connected {
                        MetricPill(icon: "checkmark.circle.fill", label: "Status", value: "Connected",
                                   tint: JcTheme.success)
                        MetricPill(icon: "speaker.wave.2.fill", label: "Audio",
                                   value: route.speakers ? "Glasses" : "iPhone", tint: JcTheme.accent)
                    } else if lastSeen == nil {
                        MetricPill(icon: "link", label: "Status", value: "Not paired yet", tint: .secondary)
                    } else {
                        MetricPill(icon: "speaker.slash.fill", label: "Status", value: "Not on audio",
                                   tint: .secondary)
                    }
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .lastSeenCorner(lastSeen, visible: !route.connected)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

// MARK: - Page

/// The glasses' page, laid out like the Jarvis Pod's. Everything on it works over
/// standard Bluetooth audio; the lens, touchpad, GO key, camera and battery are shown
/// as tiles where they will hook in once Jarvis has a control link to the glasses.
struct InmoGo3View: View {
    private let link = GlassesAudioLink.shared
    @State private var speakerTest = GlassesSpeakerTest()
    @State private var speech = SpeechEngineStore.shared
    @State private var renaming = false
    @State private var confirmForget = false
    /// Optional so previews and tests without the shell still build the screen.
    @Environment(AppRouter.self) private var router: AppRouter?

    private var route: GlassesRouteState { link.state }
    private var known: Bool { link.known }
    private var name: String { InmoGo3.name }
    private var stepsDone: Int { [known, link.heardSpeakers, link.usedMic].filter { $0 }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                talkButton
                if stepsDone < 3 { setupSection }
                // Only while the glasses are unknown: once known, a headset on the route
                // (AirPods, say) is not an invitation to re-pick them.
                if !known, let headset = route.otherHeadset { claimSection(headset) }
                soundSection
                talkingSection
                deviceSection
                laterSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            WearableToolbarButton(title: "Refresh", icon: "arrow.clockwise") { link.refresh() }
            WearableMoreMenu(onRename: { renaming = true }, extra: {
                if known {
                    Button("Forget these glasses", jcIcon: "xmark.circle", role: .destructive) { confirmForget = true }
                }
            })
        }
        .task { await speech.load() }
        .onAppear { link.refresh() }
        .onDisappear { speakerTest.stop() }
        .wearableRename(isPresented: $renaming, current: name) {
            WearableNames.shared.rename(WearableKeepAlive.glasses, to: $0)
        }
        .confirmationDialog("Forget these glasses?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { link.forget() }
        } message: {
            Text("Jarvis stops treating this headset as your GO3. Unpair it in Settings › Bluetooth to disconnect it.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            // Closer than the card's 4.2: the frame is wide, and the field of view is vertical.
            GlassesSceneView(spin: true, entrance: true, lit: route.connected, cameraDistance: 3.4)
                .frame(height: 210)
                .frame(maxWidth: .infinity)
            Text(name)
                .font(.title.weight(.bold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            HStack(spacing: 8) {
                if route.connected {
                    chip("Connected", symbol: "circle.fill", tint: JcTheme.success)
                    chip(route.speakers ? "Glasses audio" : "iPhone audio", symbol: "speaker.wave.2.fill",
                         tint: JcTheme.accent)
                    if route.microphone { chip("Glasses mic", symbol: "mic.fill", tint: JcTheme.accent) }
                } else if known {
                    chip(offlineText, symbol: "speaker.slash.fill", tint: JcTheme.muted)
                } else {
                    chip("Not paired yet", symbol: "link", tint: JcTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var offlineText: String {
        if let note = DisconnectedPill.lastSeenNote(WearableIdentity.lastSeen(WearableKeepAlive.glasses)) {
            return "Not on audio · \(note)"
        }
        return "Not on audio"
    }

    /// Starts Voice, the same way Control Center does. With the glasses on the route the
    /// whole conversation runs through their mics and speakers.
    private var talkButton: some View {
        VStack(spacing: 8) {
            Button {
                router?.requestVoiceLaunch()
            } label: {
                Label("Talk to Jarvis", jcIcon: "mic.fill")
            }
            .buttonStyle(.jcGlass(full: true))
            Text(route.connected ? "Through the glasses' mics and speakers"
                                 : "Uses the iPhone until the glasses are connected")
                .font(.caption)
                .foregroundStyle(JcTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Get started

    /// Ticks itself: pairing from the route, the speaker test from where it played,
    /// and the mic from the first voice turn that ran through the glasses.
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Get started", trailing: "\(stepsDone) of 3")
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    step(1, "Pair the glasses", "Pairing mode on the glasses, then Settings › Bluetooth",
                         done: known) {
                        if let url = URL(string: "App-Prefs:root=Bluetooth") {
                            Link("Open", destination: url)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(JcTheme.accent)
                        }
                    }
                    divider
                    step(2, "Hear Jarvis in them", "Play the speaker test with the glasses connected",
                         done: link.heardSpeakers) {
                        Button("Play") { speakerTest.play() }
                            .buttonStyle(.jcGlass(compact: true))
                            .disabled(!route.connected || speakerTest.speaking)
                    }
                    divider
                    step(3, "Talk through them", "Start Voice with the glasses on; their mics carry the turn",
                         done: link.usedMic) {
                        Button("Talk") { router?.requestVoiceLaunch() }
                            .buttonStyle(.jcGlass(compact: true))
                            .disabled(!route.connected)
                    }
                }
            }
        }
    }

    private func step<Action: View>(_ number: Int, _ title: String, _ subtitle: String, done: Bool,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? JcTheme.success.opacity(0.18) : JcTheme.accent.opacity(0.14))
                if done {
                    JcIcon("checkmark", size: 13, weight: .bold).foregroundStyle(JcTheme.success)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(JcTheme.accent)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                    .foregroundStyle(done ? JcTheme.muted : JcTheme.text)
                    .strikethrough(done, color: JcTheme.muted)
                Text(subtitle).font(.caption).foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !done { action() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The GO3's Bluetooth name is a guess until one is paired, so an unrecognised headset
    /// is offered rather than assumed.
    private func claimSection(_ headset: GlassesAudioPort) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Are these your glasses?")
            GlassCard(padding: 0) {
                HStack(spacing: 12) {
                    iconTile("headphones")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headset.name).font(.body.weight(.medium)).foregroundStyle(JcTheme.text).lineLimit(1)
                        Text("Connected over Bluetooth — only if it's your GO3 under another name")
                            .font(.caption).foregroundStyle(JcTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Use") { link.claim(headset) }
                        .buttonStyle(.jcGlass(compact: true))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: Sound

    private var soundSection: some View {
        group("Sound") {
            HStack(spacing: 12) {
                iconTile("airplayaudio")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio output").font(.body.weight(.medium)).foregroundStyle(JcTheme.text)
                    Text(route.speakers ? "Playing through the glasses" : "Choose the glasses or the iPhone")
                        .font(.caption).foregroundStyle(JcTheme.muted)
                }
                Spacer()
                AudioRoutePicker().frame(width: 34, height: 34)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            divider
            HStack(spacing: 12) {
                iconTile("speaker.wave.2.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Test speakers").font(.body.weight(.medium)).foregroundStyle(JcTheme.text)
                    Text(speakerTest.error ?? "Jarvis says one line through the current output")
                        .font(.caption)
                        .foregroundStyle(speakerTest.error == nil ? JcTheme.muted : JcTheme.danger)
                }
                Spacer()
                if speakerTest.speaking {
                    Button("Stop") { speakerTest.stop() }.buttonStyle(.jcGlass(compact: true))
                } else {
                    Button("Play") { speakerTest.play() }.buttonStyle(.jcGlass(compact: true))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: Talking to Jarvis

    private var talkingSection: some View {
        group("Talking to Jarvis") {
            toggle("Voice on connect", "Opens Voice as soon as the glasses take the audio",
                   "bolt.horizontal.circle",
                   isOn: Binding(get: { link.startsVoiceOnConnect }, set: { link.startsVoiceOnConnect = $0 }))
            divider
            speechModel
        }
    }

    /// The glasses talk to Jarvis through the phone's Voice, so this is the phone's
    /// voice speech setting — the same one the Voice sheet shows.
    private var speechModel: some View {
        let s = speech.settings
        let options = s.engines.filter { $0.available || $0.name == s.voice }
        return HStack(spacing: 12) {
            iconTile("text.bubble")
            VStack(alignment: .leading, spacing: 2) {
                Text("Speech model").font(.body.weight(.medium)).foregroundStyle(JcTheme.text)
                Text(speech.error.isEmpty ? "Shared with the phone's Voice" : speech.error)
                    .font(.caption)
                    .foregroundStyle(speech.error.isEmpty ? JcTheme.muted : JcTheme.danger)
            }
            Spacer()
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Device

    /// What iOS reports about the glasses' audio link — read live, only while connected.
    private var deviceSection: some View {
        let details = link.details
        return group("Device") {
            info("eyeglasses", "Model", "INMO GO3 · IMG301")
            divider
            info("dot.radiowaves.left.and.right", "Bluetooth name", route.glasses?.name ?? "—")
            divider
            info("waveform", "Profiles", details.profiles.isEmpty ? "—" : details.profiles.joined(separator: " · "))
            divider
            info("waveform.path", "Sample rate", details.sampleRate.map { "\(Int(($0 / 1000).rounded())) kHz" } ?? "—")
            divider
            info("timer", "Audio delay", details.outputLatencyMs.map { "\($0) ms" } ?? "—")
            divider
            info("number", "Address", link.rememberedKey ?? "—")
        }
    }

    // MARK: Later

    /// Where the rest of the glasses hooks in. Nothing here is wired, and the tiles say so.
    private var laterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("With the control link", trailing: "Not yet")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Self.later, id: \.title) { item in
                        VStack(spacing: 10) {
                            JcIcon(item.icon, size: 24, weight: .medium)
                                .foregroundStyle(JcTheme.muted)
                                .frame(width: 72, height: 72)
                                .background(Color.white.opacity(0.05), in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.1)))
                            VStack(spacing: 2) {
                                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(JcTheme.text)
                                    .lineLimit(1)
                                Text(item.detail).font(.caption).foregroundStyle(JcTheme.muted).lineLimit(1)
                            }
                        }
                        .frame(width: 92)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            .opacity(0.6)
            Text("INMO's own app drives these today. They light up here once Jarvis has a link to the glasses.")
                .font(.caption)
                .foregroundStyle(JcTheme.muted)
                .padding(.horizontal, 4)
        }
    }

    private static let later: [(title: String, detail: String, icon: String)] = [
        ("Lens", "Replies in view", "text.viewfinder"),
        ("Touchpad", "Swipe & tap", "hand.tap"),
        ("GO key", "Shortcut", "button.programmable"),
        ("Camera", "Ask about it", "camera"),
        ("Battery", "Level", "battery.75"),
        ("Alerts", "On the lens", "bell.badge"),
    ]

    // MARK: Building blocks (the Pod page's)

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

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            JcIcon(symbol).font(.caption2.weight(.bold)).foregroundStyle(tint)
            Text(text).font(.footnote.weight(.semibold)).foregroundStyle(JcTheme.text).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .jcLiquidGlass(in: Capsule())
    }

    private func iconTile(_ symbol: String) -> some View {
        JcIcon(symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(JcTheme.accent)
            .frame(width: 30, height: 30)
            .background(JcTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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

/// The system's audio-route button — the same picker as Control Center's.
private struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(JcTheme.accent)
        picker.activeTintColor = UIColor(JcTheme.accent)
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
