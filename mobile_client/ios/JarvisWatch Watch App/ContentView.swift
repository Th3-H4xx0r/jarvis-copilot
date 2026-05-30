import AVFoundation
import SwiftUI

/// The single watch screen, built around the animated VoiceOrb. Tap the orb to
/// talk; it reflects idle / thinking / speaking / error states. A Volume drawer
/// hosts the watchOS volume control (which can't be set programmatically).
struct ContentView: View {
    @ObservedObject var connector: WatchConnector
    @StateObject private var vm: WatchViewModel
    @ObservedObject private var voice = VoiceStatus.shared
    @State private var dictated = ""
    @State private var activeSheet: ActiveSheet?
    @State private var vol: Float = 0   // live system volume shown in the drawer

    enum ActiveSheet: Int, Identifiable { case dictation, volume; var id: Int { rawValue } }

    init(connector: WatchConnector) {
        self.connector = connector
        _vm = StateObject(wrappedValue: WatchViewModel(
            asker: { await connector.ask(text: $0) },
            speak: { result in
                if result.expectsClip {
                    // JARVIS clip is arriving via transferFile → plays on receipt
                    // (WatchConnector.didReceive). Don't also speak built-in.
                } else if !result.audioBase64.isEmpty {
                    AudioPlayer.shared.play(base64: result.audioBase64)
                } else {
                    Speaker.shared.speak(result.replyText)  // synth failed → built-in fallback
                }
            }))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content.padding(.horizontal, 6)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .dictation: dictationSheet
            case .volume: volumeSheet
            }
        }
        // Launched from the watch-face complication (jarviswatch://listen) →
        // go straight into dictation.
        .onOpenURL { url in
            if url.host == "listen" || url.path.contains("listen") {
                activeSheet = .dictation
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !connector.loggedIn {
            VStack(spacing: 12) {
                VoiceOrb(mode: .error, size: 78)
                Text("Open JarvisCopilot on your iPhone to set up.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        } else {
            switch vm.state {
            case .idle, .listening:
                VStack(spacing: 12) {
                    orbButton(.idle, size: 100)
                    Text("Tap to talk").font(.footnote).foregroundStyle(.secondary)
                    volumeButton
                }
            case .thinking:
                if connector.streamingText.isEmpty {
                    VStack(spacing: 14) {
                        VoiceOrb(mode: .thinking, size: 100)
                        Text("Thinking…").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    // Live answer building up as tokens stream from the phone.
                    ScrollView {
                        VStack(spacing: 8) {
                            VoiceOrb(mode: .thinking, size: 40)
                            Text(connector.streamingText).font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            case .answer(let text):
                ScrollView {
                    VStack(spacing: 8) {
                        orbButton(.speaking, size: 46)
                        Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                        if !voice.note.isEmpty {
                            Text(voice.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        volumeButton.padding(.top, 4)
                    }
                }
            case .error(let msg):
                VStack(spacing: 12) {
                    orbButton(.error, size: 88)
                    Text(msg).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func orbButton(_ mode: VoiceOrb.Mode, size: CGFloat) -> some View {
        Button { activeSheet = .dictation } label: { VoiceOrb(mode: mode, size: size) }
            .buttonStyle(.plain)
    }

    private var volumeButton: some View {
        Button { activeSheet = .volume } label: {
            Label("Volume", systemImage: "speaker.wave.2.fill").font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // Tapping the field brings up the watchOS dictation/scribble input.
    private var dictationSheet: some View {
        VStack(spacing: 10) {
            Text("Speak to JARVIS").font(.headline)
            TextField("Tap, then dictate…", text: $dictated)
                .onSubmit { submit() }
            Button("Ask") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(dictated.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    // Drawer: the last clip loops quietly while open so the Digital Crown adjusts
    // the MEDIA volume (the slider mirrors it). Done (or swipe down) dismisses.
    private var volumeSheet: some View {
        VStack(spacing: 6) {
            VolumeSlider().frame(width: 86, height: 86)
            Text("Volume \(Int(vol * 100))%").font(.caption).foregroundStyle(.orange)
            Text("Turn the Digital Crown").font(.caption2)
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Done") { activeSheet = nil }.buttonStyle(.bordered)
        }
        .padding()
        .onAppear { AudioPlayer.shared.beginVolumeCalibration() }
        .onDisappear { AudioPlayer.shared.endVolumeCalibration() }
        // Live-poll the system volume so the crown's effect is visible even if
        // the clip is too quiet to hear yet.
        .task {
            while !Task.isCancelled {
                vol = AVAudioSession.sharedInstance().outputVolume
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func submit() {
        let text = dictated
        dictated = ""
        activeSheet = nil
        Task { await vm.submit(text: text) }
    }
}
