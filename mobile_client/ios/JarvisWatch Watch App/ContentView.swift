import AVFoundation
import SwiftUI

/// The single watch screen, built around the animated VoiceOrb. Tap the orb to
/// talk; it reflects idle / thinking / speaking / error states. A Volume drawer
/// hosts the watchOS volume control (which can't be set programmatically).
///
/// Styling mirrors the mobile voice screen: ambient near-black backdrop, the
/// glass-ribbon orb, and the Inter typeface throughout.
struct ContentView: View {
    @ObservedObject var connector: WatchConnector
    @StateObject private var vm: WatchViewModel
    @ObservedObject private var voice = VoiceStatus.shared
    @ObservedObject private var audio = AudioPlayer.shared
    @State private var activeSheet: ActiveSheet?
    @State private var vol: Float = 0   // live system volume shown in the drawer

    enum ActiveSheet: Int, Identifiable { case volume; var id: Int { rawValue } }

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
            JcWatch.background
            content.padding(.horizontal, 6)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .volume: volumeSheet
            }
        }
        // The orb is a TextFieldLink, so dictation can't be opened
        // programmatically; the complication (jarviswatch://listen) just brings
        // the app forward to the orb — one tap to talk.
    }

    @ViewBuilder private var content: some View {
        if !connector.loggedIn {
            VStack(spacing: 12) {
                VoiceOrb(mode: .error, size: 78)
                Text("Open JarvisCopilot on your iPhone to set up.")
                    .font(.inter(13)).multilineTextAlignment(.center)
                    .foregroundStyle(JcWatch.muted)
            }
        } else if audio.isSpeaking {
            // Audio is playing (chunked clips) → show the speaking screen with a
            // STOP control + volume, even before the final reply text returns.
            // When playback finishes, isSpeaking flips false and we fall through
            // to the normal screen (the orb becomes tap-to-talk again).
            speakingScreen
        } else {
            switch vm.state {
            case .idle, .listening:
                VStack(spacing: 14) {
                    orbButton(.idle, size: 104)
                    Text("Tap to talk")
                        .font(.inter(14, .medium)).foregroundStyle(JcWatch.muted)
                    volumeButton
                }
            case .thinking:
                if connector.streamingText.isEmpty {
                    VStack(spacing: 16) {
                        VoiceOrb(mode: .thinking, size: 104)
                        Text("Thinking…")
                            .font(.inter(14, .medium)).foregroundStyle(JcWatch.muted)
                    }
                } else {
                    // Live answer building up as tokens stream from the phone.
                    ScrollView {
                        VStack(spacing: 8) {
                            VoiceOrb(mode: .thinking, size: 44)
                            Text(connector.streamingText)
                                .font(.inter(15)).foregroundStyle(JcWatch.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            case .answer(let text):
                ScrollView {
                    VStack(spacing: 10) {
                        orbButton(.speaking, size: 50)
                        Text(text)
                            .font(.inter(16, .semibold)).foregroundStyle(JcWatch.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !voice.note.isEmpty {
                            Text(voice.note)
                                .font(.inter(11)).foregroundStyle(JcWatch.muted)
                        }
                        volumeButton.padding(.top, 4)
                    }
                }
            case .error(let msg):
                VStack(spacing: 12) {
                    orbButton(.error, size: 88)
                    Text(msg).font(.inter(13)).multilineTextAlignment(.center)
                        .foregroundStyle(JcWatch.muted)
                }
            }
        }
    }

    // Best available reply text to show while speaking: the final answer once
    // it's back, otherwise the live streaming preview.
    private var currentAnswerText: String {
        if case .answer(let t) = vm.state { return t }
        return connector.streamingText
    }

    // Shown while audio is playing: a STOP button (tap to interrupt speech) +
    // the reply text + the volume control. Tapping Stop ends playback and the
    // screen reverts to the tap-to-talk orb.
    private var speakingScreen: some View {
        ScrollView {
            VStack(spacing: 10) {
                Button { audio.stopSpeaking() } label: {
                    VStack(spacing: 4) {
                        VoiceOrb(mode: .speaking, size: 70)
                        Label("Stop", systemImage: "stop.fill").font(.inter(12, .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(JcWatch.text)
                if !currentAnswerText.isEmpty {
                    Text(currentAnswerText)
                        .font(.inter(16, .semibold)).foregroundStyle(JcWatch.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                volumeButton.padding(.top, 4)
            }
        }
    }

    // The orb IS the dictation trigger: TextFieldLink (watchOS 9+) presents the
    // system dictation UI directly on press — no separate text field to tap, no
    // sheet. Native, on-device dictation auto-ends on silence and returns the
    // text via onSubmit, which we send straight to the agent. (One tap → talk.)
    private func orbButton(_ mode: VoiceOrb.Mode, size: CGFloat) -> some View {
        TextFieldLink(prompt: Text("Speak to JARVIS")) {
            VoiceOrb(mode: mode, size: size)
        } onSubmit: { text in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            Task { await vm.submit(text: t) }
        }
        .buttonStyle(.plain)
    }

    private var volumeButton: some View {
        Button { activeSheet = .volume } label: {
            Label("Volume", systemImage: "speaker.wave.2.fill").font(.inter(12, .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(JcWatch.muted)
    }

    // Drawer: the last clip loops quietly while open so the Digital Crown adjusts
    // the MEDIA volume (the slider mirrors it). Done (or swipe down) dismisses.
    private var volumeSheet: some View {
        VStack(spacing: 6) {
            VolumeSlider().frame(width: 86, height: 86)
            Text("Volume \(Int(vol * 100))%")
                .font(.inter(13, .medium)).foregroundStyle(JcWatch.text)
            Text("Turn the Digital Crown").font(.inter(11))
                .multilineTextAlignment(.center).foregroundStyle(JcWatch.muted)
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

}
