import AVKit
import SwiftUI

/// The Sim tab: the glasses in your hand. Hero + status, talk to them, their touchpad and capture
/// button, their physical state, the live command feed, the camera/live view, storage and settings.
struct MetaSimScreen: View {
    @ObservedObject var sim: SimulatedGlassesTransport
    @ObservedObject var hub: MetaGlassesHub

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetaSimHero(sim: sim)
            MetaCallCard(sim: sim)
            MetaTouchpadCard(sim: sim)
            MetaLiveCard(sim: sim, hub: hub)        // up here so Call view / FaceTime are easy to find
            MetaTalkCard(sim: sim)
            MetaGlassesStateCard(sim: sim)
            MetaFeedCard(feed: hub.feed, emptyText: "Ask Jarvis something about your glasses, or use the controls above.")
            MetaStorageCard(sim: sim)
            MetaSimSettingsCard(sim: sim)
            MetaTouchSettingsCard(hub: hub)
            MetaLimitsCard()
        }
        .task { _ = await MetaPhoneCamera.requestAccess() }
    }
}

private struct MetaSimHero: View {
    @ObservedObject var sim: SimulatedGlassesTransport

    var body: some View {
        VStack(spacing: 10) {
            MetaGlassesSceneView(spin: true, ledOn: sim.ledLit, folded: sim.hw.folded, focus: sim.focus)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .animation(.easeInOut(duration: 0.3), value: sim.focus)
            HStack(spacing: 8) {
                chip(sim.hw.charging ? "battery.100.bolt" : "battery.75", "\(Int(sim.hw.battery.rounded()))%",
                     sim.hw.battery <= 20 ? JcTheme.danger : JcTheme.text)
                chip("thermometer.medium", sim.hw.heatLabel, sim.hw.cameraTooHot ? JcTheme.danger : JcTheme.text)
                chip("internaldrive", "\(sim.hw.storageFree / 1_000_000_000) GB free", JcTheme.text)
                chip(sim.hw.worn ? "eyeglasses" : "eyeglasses.slash", sim.hw.inCase ? "In case" : sim.hw.folded ? "Folded" : sim.hw.worn ? "Worn" : "Off face", JcTheme.text)
            }
            if sim.phoneOnGlassesWiFi {
                Label("Phone on the glasses' Wi-Fi — Jarvis traffic goes over cellular", systemImage: "wifi")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
            switch sim.hw.call {
            case .ringing(let from, _):
                Label("Call from \(from) · ringing", systemImage: "phone.arrow.down.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JcTheme.text)
            case .active(_, let seconds):
                Label("On a call · \(MetaCallRules.clock(seconds))", systemImage: "phone.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JcTheme.text)
            case .none:
                EmptyView()
            }
            if sim.hw.recording != nil || sim.hw.streaming {
                Label(sim.hw.streaming ? "Live streaming · LED on" : "Recording \(Int(sim.hw.recording?.elapsed ?? 0)) s · LED on",
                      systemImage: "record.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JcTheme.danger)
            }
        }
    }

    private func chip(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(JcButton.fill))
    }
}

/// Talk to the glasses: hold to talk with your own voice (the one white button), or type it.
private struct MetaTalkCard: View {
    @ObservedObject var sim: SimulatedGlassesTransport
    @StateObject private var runner = MetaGlassesSimRunner(target: {
        guard let glasses = MetaGlassesHub.shared.device,
              let sim = glasses.transport as? SimulatedGlassesTransport else { return nil }
        return (glasses.session, sim)
    })
    @StateObject private var mic = MetaSimMic()
    @State private var micError: String?
    /// The finger is down: the gesture reports every movement, so start the mic once per press.
    @State private var pressing = false
    @StateObject private var listener = MetaSimWakeListener()
    @ObservedObject private var realCalls = MetaRealCallWatch.shared
    @AppStorage("meta.sim.listenWake") private var listenWake = false
    @State private var enrolling = false
    @State private var visible = false
    /// From releasing Hold to talk (or the wake word firing) until Jarvis's turn has ended.
    @State private var handingOff = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Hey Jarvis")
            JcCard {
                VStack(alignment: .leading, spacing: 12) {
                    wakeRow
                    holdToTalk
                    HStack(spacing: 8) {
                        TextField("Or type what you'd say", text: $runner.prompt)
                            .font(.system(size: 15))
                            .focused($typing)
                            .submitLabel(.go)
                            .onSubmit(runTyped)
                            .disabled(runner.isRunning)
                        Button(action: runner.isRunning ? stop : runTyped) {
                            Image(systemName: runner.isRunning ? "stop.fill" : "arrow.up")
                        }
                        .buttonStyle(.jcGlass)
                    }
                    if let why = failure {
                        Label(why, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(JcTheme.muted)
                    }
                }
            }
            if !runner.rows.isEmpty || runner.isRunning {
                JcSectionLabel("Last turn")
                JcCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(runner.rows) { row in turnRow(row) }
                        if let latency = runner.wakeToAnswer, !runner.isRunning {
                            JcRow(symbol: "timer", title: "Wake → Jarvis speaking", value: MetaGlassesView.seconds(latency), last: true)
                        }
                    }
                }
            }
        }
        .onAppear {
            visible = true
            listener.onWake = { pcm in send(pcm) }
            listener.onHeard = { sim.show(.mic, .listening, for: 12) }
            updateListener()
        }
        .onDisappear { visible = false; listener.stop() }
        .onChange(of: listenWake) { _, _ in updateListener() }
        .onChange(of: runner.isRunning) { _, _ in updateListener() }
        .onChange(of: sim.wakePhrase) { _, _ in updateListener() }
        .onChange(of: pressing) { _, _ in updateListener() }
        .onChange(of: sim.capturingQuestion) { _, _ in updateListener() }
        .onChange(of: sim.hw.voiceActive) { _, _ in updateListener() }
        .onChange(of: sim.assistantBusy) { _, _ in updateListener() }
        .onChange(of: handingOff) { _, _ in updateListener() }
        .onChange(of: sim.hw.call.isActive) { _, _ in updateListener() }
        .onChange(of: realCalls.busy) { _, _ in updateListener() }
        .onChange(of: scenePhase) { _, _ in updateListener() }
        .sheet(isPresented: $enrolling) {
            MetaWakeEnrolmentView(phrase: "Hey Jarvis") { samples in
                listener.stop()
                guard let session = MetaGlassesHub.shared.device?.session else {
                    throw MetaGlassesError.notReady
                }
                try await session.enrolWakeWord(phrase: "Hey Jarvis", samples: samples)
            }
        }
    }

    /// Hands-free "Hey Jarvis": set it up once, then the switch listens while this screen is open.
    @ViewBuilder private var wakeRow: some View {
        if let phrase = sim.wakePhrase {
            Toggle(isOn: $listenWake) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listen for “\(phrase)”").font(.system(size: 15, weight: .medium))
                    Text(listenerStatus).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            }
            Button("Set up “\(phrase)” again") { enrolling = true }
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
        } else {
            Button { enrolling = true } label: {
                Label("Set up “Hey Jarvis” on the glasses", systemImage: "waveform.badge.mic")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.jcGlass)
        }
    }

    private var listenerStatus: String {
        switch listener.state {
        case .off: return listenWake ? "Paused" : "Off — Hold to talk still works"
        case .listening: return "Listening on the phone mic (stands in for the glasses)"
        case .heard: return "Heard it — sending what you said to Jarvis"
        case .failed(let why): return why
        }
    }

    /// Listen only while this screen shows, the switch is on, and no turn or press is using the mic.
    private func updateListener() {
        let want = MetaSimWakeListener.shouldListen(
            onScreen: visible, appActive: scenePhase == .active, switchOn: listenWake,
            enrolled: sim.wakePhrase != nil, turnRunning: runner.isRunning, pressing: pressing,
            handingOff: handingOff, capturingQuestion: sim.capturingQuestion,
            assistantBusy: sim.assistantBusy, jarvisSpeaking: sim.hw.voiceActive,
            onCall: sim.hw.call.isActive || realCalls.busy)
        if want, !listener.isListening {
            let phrase = sim.wakePhrase ?? "Hey Jarvis"
            Task { await listener.start(phrase: phrase) }
        } else if !want, listener.state == .listening {
            listener.stop()
        }
    }

    private var failure: String? {
        if let micError { return micError }
        if case .failed(let why) = runner.phase { return why }
        return nil
    }

    private var holdToTalk: some View {
        HStack(spacing: 8) {
            Image(systemName: mic.recording ? "waveform" : "mic.fill")
            Text(holdToTalkTitle)
                .font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(JcAccent.onFill)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 14).fill(JcAccent.fill.opacity(micBlocked ? 0.5 : 1)))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in startMic() }
            .onEnded { _ in stopMic() })
        .allowsHitTesting(!micBlocked)
    }

    /// Jarvis is answering, or an answered call owns the glasses' mic.
    private var micBlocked: Bool { runner.isRunning || sim.hw.call.isActive }

    private var holdToTalkTitle: String {
        if mic.recording { return sim.hw.call.isRinging ? "Listening — say “answer” or “decline”" : "Listening — release to send" }
        if sim.hw.call.isActive { return "On a call — the mic is the call's" }
        if runner.isRunning { return "Jarvis is answering…" }
        if sim.hw.call.isRinging { return "Hold and say “answer” or “decline”" }
        return "Hold to talk to the glasses"
    }

    private func startMic() {
        guard !pressing, !runner.isRunning, !sim.hw.call.isActive else { return }
        pressing = true
        listener.stop()
        micError = nil
        MetaGlassesHaptics.micOpened()
        sim.earcon?.play(.listening)
        sim.setHoldToTalk(true)
        Task {
            do {
                try await mic.start()
                // Lifted while the recorder was still coming up: send what there is (likely too short).
                if !pressing, mic.recording { send(mic.stop()) }
            } catch {
                micError = error.localizedDescription
            }
        }
    }

    private func stopMic() {
        guard pressing else { return }
        handingOff = true                       // keep the listener off through the chime and the turn
        pressing = false
        MetaGlassesHaptics.micClosed()
        sim.setHoldToTalk(false)
        // His "done" chime while the mic is still held, then stop recording: releasing the session
        // first cut the chime off (2026-11-22).
        let holdMs = sim.earcon?.play(.thinking) ?? 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(holdMs))
            if let pcm = mic.finishPress() { send(pcm) } else { handingOff = false }
        }
    }

    private func send(_ pcm: Data) {
        handingOff = true
        Task {
            // While a call rings, the glasses' mics answer or decline it — nothing goes to Jarvis.
            if sim.hw.call.isRinging { await sim.hearDuringCall(pcm) } else { await runner.run(recorded: pcm) }
            handingOff = false
        }
    }

    private func runTyped() {
        guard !runner.isRunning, !runner.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        typing = false
        micError = nil
        if sim.hw.call.isRinging {
            sim.hearDuringCall(text: runner.prompt)
            return
        }
        Task { await runner.run() }
    }

    private func stop() { Task { await runner.stop() } }

    private func turnRow(_ row: MetaGlassesSimRunner.Row) -> some View {
        let time: String = MetaGlassesView.seconds(row.at)
        return JcRow(symbol: row.symbol, title: row.title, subtitle: row.detail, value: time)
    }
}

/// The right arm: the touchpad gestures and the capture button.
private struct MetaTouchpadCard: View {
    @ObservedObject var sim: SimulatedGlassesTransport
    private let gestures: [MetaTouchGesture] = [.tap, .doubleTap, .tripleTap, .hold, .swipeBackward, .swipeForward]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Touchpad & capture button")
            JcCard {
                VStack(spacing: 10) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(gestures, id: \.self) { gesture in
                            if gesture == .hold {
                                MetaHoldTile(title: MetaTouchBinding.label(gesture),
                                             detail: doesNow(gesture),
                                             symbol: nil) {
                                    Task { await sim.touch(.hold) }
                                }
                            } else {
                                Button {
                                    MetaGlassesHaptics.play(gesture)
                                    Task { await sim.touch(gesture) }
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(MetaTouchBinding.label(gesture)).font(.system(size: 13, weight: .semibold))
                                        Text(doesNow(gesture))
                                            .font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.jcGlass)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button {
                            MetaGlassesHaptics.shutter()
                            Task { await sim.pressCaptureButton(hold: false) }
                        } label: {
                            Label("Press · photo", systemImage: "camera").frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.jcGlass)
                        MetaHoldTile(title: sim.hw.recording == nil ? "Hold · video" : "Hold · stop",
                                     detail: nil, symbol: sim.hw.recording == nil ? "video" : "stop.circle") {
                            MetaGlassesHaptics.recording(started: sim.hw.recording == nil)
                            Task { await sim.pressCaptureButton(hold: true) }
                        }
                    }
                    Text("Press and hold the hold tiles like the real arm. The glasses do these themselves; a Jarvis action you bind below runs too.")
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// What the gesture does right now: a ringing or answered call takes over double-tap and hold.
    private func doesNow(_ gesture: MetaTouchGesture) -> String {
        MetaCallRules.label(gesture, during: sim.hw.call)
            ?? MetaTouchBinding.label(MetaTouchBinding.defaultAction(for: gesture))
    }
}

/// A phone call to the glasses: ring them as a caller, then answer or decline the way the real
/// glasses do — the buttons here perform the same gestures (double-tap, touch and hold).
private struct MetaCallCard: View {
    @ObservedObject var sim: SimulatedGlassesTransport
    @AppStorage("meta.sim.callerName") private var caller = "Mom"
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Incoming call")
            JcCard {
                VStack(alignment: .leading, spacing: 12) {
                    switch sim.hw.call {
                    case .none: idle
                    case .ringing(let from, let seconds): ringing(from, seconds)
                    case .active(let from, let seconds): onCall(from, seconds)
                    }
                }
            }
        }
    }

    @ViewBuilder private var idle: some View {
        HStack(spacing: 8) {
            TextField("Caller", text: $caller)
                .font(.system(size: 15))
                .focused($typing)
                .submitLabel(.go)
                .onSubmit(ring)
            Button(action: ring) {
                Label("Ring", systemImage: "phone.arrow.down.left").frame(minHeight: 40)
            }
            .buttonStyle(.jcGlass)
        }
        Text("The glasses say who's calling and chime softly until you answer (double-tap, or “answer”) or decline (touch and hold, or “decline”). Jarvis only learns that a call is on — never who, and it can't answer.")
            .font(.system(size: 12))
            .foregroundStyle(JcTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func ringing(_ from: String, _ seconds: Double) -> some View {
        HStack(spacing: 12) {
            JcIconSquare(symbol: "phone.arrow.down.left")
            VStack(alignment: .leading, spacing: 2) {
                Text(from).font(.system(size: 17, weight: .semibold)).foregroundStyle(JcTheme.text).lineLimit(1)
                Text("Calling · missed in \(max(0, Int((MetaGen2Profile.callRingSeconds - seconds).rounded(.up)))) s")
                    .font(.system(size: 12)).foregroundStyle(JcTheme.muted).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: 8) {
            Button {
                MetaGlassesHaptics.play(.doubleTap)
                Task { await sim.touch(.doubleTap) }
            } label: {
                Label("Answer", systemImage: "phone.fill").frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.jcGlass)
            Button {
                MetaGlassesHaptics.holdRegistered()
                Task { await sim.touch(.hold) }
            } label: {
                Label("Decline", systemImage: "phone.down.fill").frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.jcGlass)
        }
        Text("Answer = double-tap · Decline = touch and hold · or hold to talk and say it")
            .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
    }

    @ViewBuilder private func onCall(_ from: String, _ seconds: Double) -> some View {
        HStack(spacing: 12) {
            JcIconSquare(symbol: "phone.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(from).font(.system(size: 17, weight: .semibold)).foregroundStyle(JcTheme.text).lineLimit(1)
                Text("On the glasses · \(MetaCallRules.clock(seconds))")
                    .font(.system(size: 12)).foregroundStyle(JcTheme.muted).monospacedDigit()
            }
            Spacer(minLength: 0)
            Button {
                MetaGlassesHaptics.play(.doubleTap)
                Task { await sim.touch(.doubleTap) }
            } label: {
                Label("Hang up", systemImage: "phone.down.fill").frame(minHeight: 40)
            }
            .buttonStyle(.jcGlass)
        }
        Text("The mic and speakers carry the call — Jarvis's assistant is off until you hang up (double-tap).")
            .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ring() {
        typing = false
        MetaGlassesHaptics.taps(1)
        sim.ring(from: caller)
    }
}

/// A tile you must actually press and hold (0.5 s), like the glasses' arm: a faint tick on touch,
/// a firm thump when the hold registers, then the action.
private struct MetaHoldTile: View {
    let title: String
    let detail: String?
    let symbol: String?
    let onHold: () -> Void
    @State private var pressing = false

    var body: some View {
        VStack(spacing: 2) {
            if let symbol {
                Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold))
            } else {
                Text(title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
            }
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(JcTheme.muted) }
        }
        .foregroundStyle(JcTheme.text)
        .frame(maxWidth: .infinity, minHeight: symbol == nil ? 44 : 40)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(pressing ? JcButton.selectedFill : JcButton.fill))
        .scaleEffect(pressing ? 0.96 : 1)
        .animation(.easeOut(duration: 0.15), value: pressing)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 30, perform: {
            MetaGlassesHaptics.holdRegistered()
            onHold()
        }, onPressingChanged: { down in
            pressing = down
            if down { MetaGlassesHaptics.pressStarted() }
        })
    }
}

/// The physical state you'd change by hand: worn, folded, case, LED, range, music, sim speed.
private struct MetaGlassesStateCard: View {
    @ObservedObject var sim: SimulatedGlassesTransport
    @State private var battery: Double = 100
    @State private var heat: Double = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("The glasses")
            JcCard(padding: 0) {
                VStack(spacing: 0) {
                    toggle("eyeglasses", "Wearing them", sim.hw.worn) { await sim.setWorn($0) }
                    toggle("arrow.down.right.and.arrow.up.left", "Folded", sim.hw.folded) { await sim.setFolded($0) }
                    toggle("case", "In the charging case", sim.hw.inCase) { await sim.setInCase($0) }
                    toggle("light.beacon.max", "Capture LED covered", sim.hw.ledCovered) { await sim.setLEDCovered($0) }
                    toggle("antenna.radiowaves.left.and.right", "In range", sim.hw.inRange) { await sim.setInRange($0) }
                    toggle("music.note", sim.hw.musicPlaying ? "Music · track \(sim.track) playing" : "Music · track \(sim.track) paused", sim.hw.musicPlaying) { await sim.setMusicPlaying($0) }
                    JcRow(symbol: "speaker.wave.2", title: "Volume", value: "\(sim.hw.volume)%")
                    JcRow(symbol: "battery.50", title: "Case battery", value: "\(Int(sim.hw.caseBattery.rounded()))%", last: true)
                }
            }
            JcSectionLabel("Sim speed & overrides")
            JcCard {
                VStack(alignment: .leading, spacing: 12) {
                    JcSegmentedPicker([(value: 1.0, label: "1×"), (value: 10.0, label: "10×"), (value: 60.0, label: "60×")],
                                      selection: $sim.speed)
                    Text("Speeds up battery and heat only — clips still record in real time.")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    slider("Battery", value: $battery, range: 0 ... 100, text: "\(Int(battery))%") { await sim.overrideBattery(battery) }
                    slider("Heat", value: $heat, range: 0 ... 1, text: "\(Int(heat * 100))%") { await sim.overrideHeat(heat) }
                }
            }
            .onAppear { battery = sim.hw.battery; heat = sim.hw.heat }
        }
    }

    private func toggle(_ symbol: String, _ title: String, _ value: Bool, _ set: @escaping (Bool) async -> Void) -> some View {
        JcRow(symbol: symbol, title: title, trailing: {
            Toggle("", isOn: Binding(get: { value }, set: { apply(set, $0) })).labelsHidden()
        })
    }

    private func apply(_ set: @escaping (Bool) async -> Void, _ value: Bool) {
        Task { @MainActor in await set(value) }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String,
                        commit: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
                Text(text).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            }
            Slider(value: value, in: range, onEditingChanged: { editing in if !editing { Task { await commit() } } })
                .tint(JcAccent.color)
        }
    }
}

/// Every command the glasses received and what happened.
struct MetaFeedCard: View {
    @ObservedObject var feed: MetaCommandFeed
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Commands received") {
                if !feed.entries.isEmpty {
                    Button("Clear") { feed.clear() }.font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            }
            JcCard(padding: 0) {
                VStack(spacing: 0) {
                    if feed.entries.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 13))
                            .foregroundStyle(JcTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(JcUnified.cardPadding)
                    }
                    ForEach(Array(feed.entries.prefix(40))) { entry in
                        MetaFeedRow(entry: entry, last: entry.id == feed.entries.prefix(40).last?.id)
                    }
                }
            }
        }
    }
}

private struct MetaFeedRow: View {
    let entry: MetaCommandFeed.Entry
    let last: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if let data = entry.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    JcIconSquare(symbol: symbol)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.title).font(.system(size: 14, weight: .medium)).foregroundStyle(JcTheme.text).lineLimit(2)
                        Spacer(minLength: 6)
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                    }
                    Text(caption).font(.system(size: 12)).foregroundStyle(refused ? JcTheme.danger : JcTheme.muted).lineLimit(3)
                }
            }
            .padding(.horizontal, JcUnified.cardPadding)
            .padding(.vertical, 10)
            if !last { JcRowSeparator(inset: 64) }
        }
    }

    private var refused: Bool { if case .refused = entry.outcome { return true }; return false }

    private var caption: String {
        var parts = [entry.source.rawValue]
        if refused { parts.append("Refused") }
        if let detail = entry.detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch entry.source {
        case .jarvis: return "sparkle"
        case .touch: return "hand.tap"
        case .captureButton: return "camera"
        case .voice: return "waveform"
        case .sim: return "slider.horizontal.3"
        case .glasses: return "eyeglasses"
        }
    }
}

/// What the glasses' camera streams to the phone.
private struct MetaLiveCard: View {
    @ObservedObject var sim: SimulatedGlassesTransport
    @ObservedObject var hub: MetaGlassesHub
    @State private var watching = false
    @State private var callViewFirst = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Live view") {
                Text(sim.cameraName).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            }
            JcCard {
                VStack(spacing: 10) {
                    if let data = sim.latestLiveFrame, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity).frame(maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text(sim.hw.streaming ? "Waiting for frames…" : "Not streaming. Ask Jarvis to go live, or start it here.")
                            .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                guard let session = hub.device?.session else { return }
                                if sim.hw.streaming {
                                    try? await session.stopLive()
                                } else {
                                    try? await session.startLive()
                                    if sim.hw.streaming { watching = true }
                                }
                            }
                        } label: {
                            Label(sim.hw.streaming ? "Stop live" : "Start live", systemImage: sim.hw.streaming ? "stop.fill" : "dot.radiowaves.forward")
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.jcGlass)
                        if sim.hw.streaming {
                            Button { callViewFirst = false; watching = true } label: {
                                Label("Watch live", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .frame(maxWidth: .infinity, minHeight: 40)
                            }
                            .buttonStyle(.jcGlass)
                        }
                    }
                    // Straight to the clean view to share in a FaceTime call (starts live if needed).
                    Button {
                        Task {
                            guard let session = hub.device?.session else { return }
                            if !sim.hw.streaming { try? await session.startLive() }
                            if sim.hw.streaming { callViewFirst = true; watching = true }
                        }
                    } label: {
                        Label("FaceTime call view", systemImage: "video.badge.waveform")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.jcGlass)
                }
            }
        }
        .fullScreenCover(isPresented: $watching) {
            MetaLiveViewer(sim: sim, startInCallView: callViewFirst) {
                Task { try? await hub.device?.session.stopLive() }
            }
        }
    }
}

/// The glasses' storage (captures wait here) and what's been imported to the phone.
private struct MetaStorageCard: View {
    @ObservedObject var sim: SimulatedGlassesTransport
    @State private var open: MetaStoredMedia?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Storage")
            JcCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(sim.hw.photoCount) photos · \(sim.hw.videoCount) videos on the glasses")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: sim.hw.storageUsed, countStyle: .file) + " of 32 GB")
                            .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                    if let progress = sim.importProgress {
                        ProgressView(value: progress).tint(JcAccent.color)
                    }
                    Button { Task { await sim.importAll() } } label: {
                        Label("Import to phone", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.jcGlass)
                    .disabled(sim.storage.isEmpty || sim.importProgress != nil)
                    let items = sim.storage + sim.imported
                    if !items.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                            ForEach(items.prefix(24)) { item in
                                Button { open = item } label: { tile(item, onGlasses: sim.storage.contains(item)) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $open) { item in MetaMediaViewer(item: item) }
    }

    private func tile(_ item: MetaStoredMedia, onGlasses: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8).fill(JcButton.fill)
            if let data = item.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.kind == .video ? "video" : "photo").foregroundStyle(JcTheme.muted)
            }
            HStack(spacing: 3) {
                Image(systemName: onGlasses ? "eyeglasses" : item.savedToPhotos ? "photo.on.rectangle" : "iphone")
                if let seconds = item.seconds { Text("\(Int(seconds.rounded())) s") }
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(4)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(4)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MetaMediaViewer: View {
    let item: MetaStoredMedia

    var body: some View {
        NavigationStack {
            Group {
                if item.kind == .video, let url = item.fileURL {
                    VideoPlayer(player: AVPlayer(url: url))
                } else if let url = item.fileURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Text(item.kind == .video ? "A test-scene clip has no video file." : "No image")
                        .foregroundStyle(JcTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(item.kind == .video ? "Video" : "Photo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Camera source, video mode and clip length.
private struct MetaSimSettingsCard: View {
    @ObservedObject var sim: SimulatedGlassesTransport

    private func send(_ frame: GlassesFrame) {
        let sim = self.sim
        Task { @MainActor in try? await sim.send(frame) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Capture settings")
            JcCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Video mode").font(.system(size: 13, weight: .medium)).foregroundStyle(JcTheme.muted)
                    JcSegmentedPicker(MetaVideoMode.allCases.map { (value: $0, label: $0.label) },
                                      selection: Binding(get: { sim.hw.videoMode }, set: { send(.setVideoMode($0)) }))
                    Text("Clip length").font(.system(size: 13, weight: .medium)).foregroundStyle(JcTheme.muted)
                    JcSegmentedPicker(MetaGen2Profile.clipLengths.map { (value: $0, label: $0 == 180 ? "3 min" : "\($0) s") },
                                      selection: Binding(get: { sim.hw.clipLength }, set: { send(.setClipLength($0)) }))
                    if let camera = sim.camera as? MetaSimCamera {
                        Toggle("Use the iPhone camera (else test scenes)", isOn: Binding(get: { camera.preferPhone },
                                                                                         set: { camera.preferPhone = $0; sim.objectWillChange.send() }))
                            .font(.system(size: 14))
                    }
                }
            }
        }
    }
}

/// Jarvis actions bound to touch gestures, on top of the glasses' own defaults.
struct MetaTouchSettingsCard: View {
    @ObservedObject var hub: MetaGlassesHub
    @State private var editing: MetaTouchGesture?
    private let gestures: [MetaTouchGesture] = [.tap, .doubleTap, .tripleTap, .hold, .swipeForward, .swipeBackward, .capture]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Touch → Jarvis")
            JcCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(gestures, id: \.self) { gesture in
                        JcRow(symbol: "hand.tap", title: MetaTouchBinding.label(gesture),
                              subtitle: "Glasses: \(MetaTouchBinding.label(MetaTouchBinding.defaultAction(for: gesture))) · Jarvis: \(hub.binding(for: gesture).summary)",
                              last: gesture == gestures.last, action: { editing = gesture })
                    }
                }
            }
        }
        .sheet(item: $editing) { gesture in
            NavigationStack {
                RingActionPicker(title: MetaTouchBinding.label(gesture), current: hub.binding(for: gesture)) { action in
                    hub.setBinding(action, for: gesture)
                }
            }
        }
    }
}

extension MetaTouchGesture: Identifiable {
    var id: String { rawValue }
}

/// The Gen 2 limits the simulator enforces.
struct MetaLimitsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Hardware limits (Gen 2)")
            JcCard(padding: 0) {
                VStack(spacing: 0) {
                    JcRow(symbol: "camera", title: "Photo", value: "12 MP · 3024×4032")
                    JcRow(symbol: "video", title: "Video", value: "3K30 · 1080p30/60 · 720p120")
                    JcRow(symbol: "timer", title: "Clip length", value: "30 s · 60 s · 3 min max")
                    JcRow(symbol: "internaldrive", title: "Storage", value: "32 GB")
                    JcRow(symbol: "battery.75", title: "Battery", value: "8 h · case +48 h")
                    JcRow(symbol: "bolt", title: "Charging", value: "50% in 20 min")
                    JcRow(symbol: "dot.radiowaves.forward", title: "Live stream", value: "720×1280 @30")
                    JcRow(symbol: "wifi", title: "Import", value: "Wi-Fi ≈10 MB/s")
                    JcRow(symbol: "light.beacon.max", title: "Capture LED", value: "Always on · covered = no camera")
                    JcRow(symbol: "thermometer.medium", title: "Heat", value: "Camera off when too hot")
                    JcRow(symbol: "waveform.badge.mic", title: "Wake word", value: "US English", last: true)
                }
            }
        }
    }
}
