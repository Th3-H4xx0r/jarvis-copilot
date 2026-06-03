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
                VoiceOrb(mode: .error, size: 86)
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
                    orbButton(.idle, size: 120)
                    Text("Tap to talk")
                        .font(.inter(14, .medium)).foregroundStyle(JcWatch.muted)
                    volumeButton
                }
            case .thinking:
                if connector.streamingText.isEmpty {
                    VStack(spacing: 16) {
                        VoiceOrb(mode: .thinking, size: 120)
                        Text("Thinking…")
                            .font(.inter(14, .medium)).foregroundStyle(JcWatch.muted)
                    }
                } else {
                    // Live answer building up as tokens stream from the phone.
                    ScrollView {
                        VStack(spacing: 8) {
                            VoiceOrb(mode: .thinking, size: 52)
                            Text(connector.streamingText)
                                .font(.inter(15)).foregroundStyle(JcWatch.text)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            case .answer(let text):
                ScrollView {
                    VStack(spacing: 10) {
                        orbButton(.speaking, size: 58)
                        // Speaking is finished here (the speaking screen owns the
                        // live highlight) → fully lit, centred.
                        KaraokeText(text: text, progress: 1.0)
                        if !voice.note.isEmpty {
                            Text(voice.note)
                                .font(.inter(11)).foregroundStyle(JcWatch.muted)
                        }
                        volumeButton.padding(.top, 4)
                    }
                }
            case .error(let msg):
                VStack(spacing: 12) {
                    orbButton(.error, size: 96)
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    Button { audio.stopSpeaking() } label: {
                        VStack(spacing: 4) {
                            VoiceOrb(mode: .speaking, size: 84)
                            Label("Stop", systemImage: "stop.fill").font(.inter(12, .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(JcWatch.text)
                    if !currentAnswerText.isEmpty {
                        // Karaoke: words light up white as the clip speaks them,
                        // and the view auto-scrolls to follow the spoken line.
                        KaraokeText(text: currentAnswerText,
                                    progress: audio.playbackProgress,
                                    scrollProxy: proxy)
                    }
                    volumeButton.padding(.top, 4)
                }
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

/// The assistant reply rendered word-by-word: words already voiced are white,
/// the rest grey, advanced by audio playback `progress` (0…1). Centred. Mirrors
/// the phone's karaoke highlight (char-weighted word schedule). No per-word
/// auto-scroll — watch replies are short and the ScrollView already lets the
/// Digital Crown scroll.
private struct KaraokeText: View {
    let text: String
    let progress: Double
    var scrollProxy: ScrollViewProxy? = nil

    var body: some View {
        let words = KaraokeText.tokenize(text)
        let spoken = KaraokeText.spokenCount(words, progress: progress)
        let chunks = KaraokeText.group(words)
        let starts = KaraokeText.starts(chunks)
        let current = KaraokeText.currentChunk(chunks, spoken: spoken)
        return VStack(spacing: 5) {
            ForEach(chunks.indices, id: \.self) { ci in
                chunkText(chunks[ci], start: starts[ci], spoken: spoken)
                    .font(.inter(16, .semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .id("kc\(ci)")
            }
        }
        .onChange(of: current) { _, newChunk in
            guard let proxy = scrollProxy else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                proxy.scrollTo("kc\(newChunk)", anchor: .center)
            }
        }
    }

    // One sentence "chunk" as a single coloured Text (white = spoken).
    private func chunkText(_ words: [String], start: Int, spoken: Int) -> Text {
        var out = Text(verbatim: "")
        for (j, w) in words.enumerated() {
            out = out + Text(verbatim: j == 0 ? w : " " + w)
                .foregroundStyle((start + j) < spoken ? JcWatch.text : JcWatch.muted)
        }
        return out
    }

    private static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    // Group words into sentence chunks (a chunk ends on . ! or ?) so each chunk
    // is a scroll anchor for auto-scroll.
    private static func group(_ words: [String]) -> [[String]] {
        var chunks: [[String]] = []; var cur: [String] = []
        for w in words {
            cur.append(w)
            if let last = w.last, ".!?".contains(last) { chunks.append(cur); cur = [] }
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks.isEmpty ? [words] : chunks
    }

    private static func starts(_ chunks: [[String]]) -> [Int] {
        var out = [Int](); var acc = 0
        for c in chunks { out.append(acc); acc += c.count }
        return out
    }

    // The chunk holding the word currently being voiced (the last spoken word).
    private static func currentChunk(_ chunks: [[String]], spoken: Int) -> Int {
        let target = max(0, spoken - 1); var acc = 0
        for (i, c) in chunks.enumerated() {
            if target < acc + c.count { return i }
            acc += c.count
        }
        return max(0, chunks.count - 1)
    }

    /// Leading words voiced by `progress`. Each word is weighted by an estimated
    /// SPOKEN duration — syllables (a far better proxy than character count: e.g.
    /// "through" is 7 chars but 1 syllable) plus a base and punctuation pauses —
    /// and the clip's small leading/trailing silence is trimmed so the highlight
    /// tracks the voice, not the raw file position.
    private static func spokenCount(_ words: [String], progress: Double) -> Int {
        if words.isEmpty { return 0 }
        // Trim ~2% lead-in and ~3% tail silence typical of TTS clips.
        let eff = min(1.0, max(0.0, (progress - 0.02) / 0.95))
        if eff <= 0 { return 0 }
        if eff >= 1 { return words.count }
        var weights = [Double](); weights.reserveCapacity(words.count)
        var total = 0.0
        for w in words {
            var wt = 1.0 + 1.3 * Double(syllables(w))   // base + per-syllable time
            if let last = w.last {
                if ".!?".contains(last) { wt += 5 }         // sentence pause
                else if ",;:".contains(last) { wt += 2.5 }  // clause pause
            }
            weights.append(wt); total += wt
        }
        let target = eff * total
        var cum = 0.0, count = 0
        for wt in weights {
            if cum <= target { count += 1; cum += wt } else { break }
        }
        return min(count, words.count)
    }

    /// Rough syllable estimate = number of vowel groups (min 1).
    private static func syllables(_ w: String) -> Int {
        let vowels = Set("aeiouyAEIOUY")
        var count = 0, prevVowel = false
        for c in w {
            let isV = vowels.contains(c)
            if isV && !prevVowel { count += 1 }
            prevVowel = isV
        }
        return max(1, count)
    }
}
