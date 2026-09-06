import AVFoundation
import MoshiLib
import SwiftUI

/// Kyutai's Moshi running fully on the phone (MLX, no server): download the
/// weights once, then hold a live full-duplex conversation. Deliberately not
/// wired to Jarvis yet — this is the bench for testing on-device speech.
@MainActor
@Observable
final class MoshiController {
    enum Phase: Equatable { case idle, loading, ready, running, failed(String) }

    var phase: Phase = .idle
    var stage = ""
    var fraction: Double?
    var transcript = ""
    var micLevel: Float = 0
    var buffered: Double = 0
    var elapsed: Double = 0
    var stepMs: Double = 0
    var playedSeconds: Double = 0
    var textTokens = 0
    var echoCancellation = true
    var downloaded = MoshiRuntime.isDownloaded()

    private let runtime = MoshiRuntime()
    private var audio: MoshiAudioIO?
    private var worker: Thread?
    private var stopFlag = false
    private var uiTimer: Timer?

    func load() {
        guard phase == .idle || { if case .failed = phase { return true }; return false }() else { return }
        phase = .loading
        Task.detached { [runtime] in
            do {
                try await runtime.load { stage, fraction in
                    Task { @MainActor [weak self] in self?.stage = stage; self?.fraction = fraction }
                }
                await MainActor.run { [weak self] in
                    self?.phase = .ready; self?.downloaded = true; self?.fraction = nil
                }
            } catch {
                await MainActor.run { [weak self] in self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func start() {
        guard phase == .ready else { return }
        transcript = ""
        elapsed = 0
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let audio = MoshiAudioIO(sampleRate: MoshiRuntime.sampleRate, frameSize: MoshiRuntime.frameSize)
            try audio.start(echoCancellation: echoCancellation)
            self.audio = audio
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .running
        stopFlag = false
        runtime.reset()
        let started = Date()
        playedSeconds = 0
        textTokens = 0
        let thread = Thread { [runtime, audio] in
            guard let audio else { return }
            var smoothed = 0.0
            while let frame = audio.frames.pop() {
                let t0 = CFAbsoluteTimeGetCurrent()
                let out = runtime.step(pcm: frame)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                smoothed = smoothed == 0 ? ms : smoothed * 0.8 + ms * 0.2
                if !out.audio.isEmpty { audio.play(out.audio) }
                if !out.text.isEmpty {
                    let text = out.text.joined()
                    let n = out.text.count
                    Task { @MainActor [weak self] in self?.transcript += text; self?.textTokens += n }
                }
                let shown = smoothed
                Task { @MainActor [weak self] in self?.stepMs = shown }
            }
        }
        thread.name = "moshi-step"
        thread.qualityOfService = .userInteractive
        thread.start()
        worker = thread
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let audio = self.audio else { return }
                self.micLevel = audio.level
                self.buffered = audio.bufferedSeconds + Double(audio.frames.depth) * 0.08
                self.playedSeconds = audio.playedSeconds
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    func stop() {
        guard phase == .running else { return }
        uiTimer?.invalidate(); uiTimer = nil
        audio?.stop()        // closes the queue, which ends the worker loop
        audio = nil; worker = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .ready
    }

    func deleteWeights() {
        stop()
        runtime.unload()
        try? MoshiRuntime.deleteDownloads()
        downloaded = false
        phase = .idle
        transcript = ""
    }
}

struct MoshiPage: View {
    @State private var model = MoshiController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switch model.phase {
                case .idle: idle
                case .loading: loading
                case .failed(let message): failed(message)
                case .ready, .running: session
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Moshi")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.downloaded {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Echo cancellation", isOn: $model.echoCancellation)
                            .disabled(model.phase == .running)
                        Button(role: .destructive) { model.deleteWeights() } label: {
                            Label("Delete weights", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .onDisappear { model.stop() }
        .jcScreen("Moshi")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On-device speech, no server.")
                .font(.headline)
            Text("Kyutai's Moshi 1B and the Mimi codec run on the phone's GPU through MLX. Not connected to Jarvis yet — this is a test bench for full-duplex voice.")
                .font(.footnote)
                .foregroundStyle(JcTheme.muted)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.downloaded ? "Weights on device" : "About 1.3 GB to download once",
                  systemImage: model.downloaded ? "checkmark.circle" : "arrow.down.circle")
                .font(.subheadline)
                .foregroundStyle(JcTheme.muted)
            Text("Needs an iPhone 15 Pro or newer (8 GB RAM). Loading takes a while the first time.")
                .font(.footnote)
                .foregroundStyle(JcTheme.muted)
            Button { model.load() } label: {
                Label(model.downloaded ? "Load model" : "Download & load", systemImage: "cpu")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(JcTheme.primaryBlue)
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text(model.stage.isEmpty ? "Starting…" : model.stage)
                    .font(.subheadline)
            }
            if let f = model.fraction {
                ProgressView(value: f).tint(JcTheme.cyan)
                Text("\(Int(f * 100))%").font(.caption).foregroundStyle(JcTheme.muted)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(JcTheme.danger)
            Text(message).font(.footnote).foregroundStyle(JcTheme.muted)
            Button("Try again") { model.load() }.buttonStyle(.bordered)
        }
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.phase == .running {
                HStack(spacing: 14) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(JcTheme.cyan)
                        .symbolEffect(.pulse, isActive: true)
                    ProgressView(value: Double(min(model.micLevel * 3, 1)))
                        .tint(JcTheme.cyan)
                    Text("\(Int(model.elapsed))s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(JcTheme.muted)
                }
                HStack(spacing: 16) {
                    stat("step", "\(Int(model.stepMs)) ms", warn: model.stepMs > 80)
                    stat("buffer", "\(Int(model.buffered * 1000)) ms", warn: model.buffered > 0.5)
                    stat("out", String(format: "%.1fs", model.playedSeconds), warn: false)
                    stat("words", "\(model.textTokens)", warn: false)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.transcript.isEmpty
                         ? (model.phase == .running ? "Say hello — Moshi talks back and its words show here." : "Ready. Start a conversation.")
                         : model.transcript)
                        .font(.body)
                        .foregroundStyle(model.transcript.isEmpty ? JcTheme.muted : JcTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 260)
                .background(JcTheme.surfaceAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onChange(of: model.transcript) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }

            Button {
                if model.phase == .running { model.stop() } else { model.start() }
            } label: {
                Label(model.phase == .running ? "Stop" : "Start talking",
                      systemImage: model.phase == .running ? "stop.circle.fill" : "waveform.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.phase == .running ? JcTheme.danger : JcTheme.primaryBlue)
            Text("A step over 80 ms means the phone can't keep up in real time; the buffer will grow.")
                .font(.caption)
                .foregroundStyle(JcTheme.muted)
        }
    }

    private func stat(_ label: String, _ value: String, warn: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(JcTheme.muted)
            Text(value).monospacedDigit().foregroundStyle(warn ? JcTheme.danger : JcTheme.text)
        }
        .font(.caption)
    }
}
