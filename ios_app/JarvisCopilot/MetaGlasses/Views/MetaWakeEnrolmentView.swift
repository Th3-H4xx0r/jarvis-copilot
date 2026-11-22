import SwiftUI

/// Set up "Hey Jarvis" the way the real glasses do it: say the phrase three times, then the glasses
/// build their own detector from the samples (US English only). Same flow for the simulator and the
/// real glasses — only where the samples go differs.
struct MetaWakeEnrolmentView: View {
    let phrase: String
    /// Sends the three samples to the selected glasses; throws the glasses' refusal.
    let enrol: ([Data]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mic = MetaSimMic()
    @State private var samples: [Data] = []
    @State private var pressing = false
    @State private var message: String?
    @State private var sending = false

    private let needed = MetaGen2Profile.wakeEnrolSamples

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Say “\(phrase)” \(needed) times. The glasses learn your voice from these samples and listen for it on their own — US English only.")
                    .font(.system(size: 15))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ForEach(0 ..< needed, id: \.self) { index in
                        VStack(spacing: 6) {
                            Image(systemName: index < samples.count ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 28))
                                .foregroundStyle(index < samples.count ? JcTheme.text : JcTheme.muted)
                            Text("Sample \(index + 1)").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
                if samples.count < needed {
                    recordButton
                } else {
                    GradientButton(sending ? "Sending to the glasses…" : "Send to the glasses", symbol: "eyeglasses",
                                   busy: sending, full: true, action: sending ? nil : send)
                    Button("Start over") { samples.removeAll(); message = nil }
                        .buttonStyle(.jcGlass)
                        .frame(maxWidth: .infinity)
                }
                if let message {
                    Label(message, systemImage: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                }
                Spacer()
            }
            .padding(20)
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Set up “\(phrase)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var recordButton: some View {
        HStack(spacing: 8) {
            Image(systemName: mic.recording ? "waveform" : "mic.fill")
            Text(mic.recording ? "Say “\(phrase)” — release when done" : "Hold and say “\(phrase)”")
                .font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(JcAccent.onFill)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 14).fill(JcAccent.fill))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in press() }
            .onEnded { _ in release() })
    }

    private func press() {
        guard !pressing else { return }
        pressing = true
        message = nil
        Task {
            do {
                try await mic.start()
                if !pressing, mic.recording { keep(mic.stop()) }
            } catch { message = error.localizedDescription }
        }
    }

    private func release() {
        guard pressing else { return }
        pressing = false
        if let pcm = mic.finishPress() { keep(pcm) }
    }

    /// 0.5–3 s of audio counts as a sample of the phrase.
    private func keep(_ pcm: Data) {
        let seconds = Double(pcm.count) / 32_000
        guard seconds >= 0.5 else { message = "Too short — hold while you say the whole phrase"; return }
        guard seconds <= 3.5 else { message = "Too long — just the phrase"; return }
        samples.append(pcm)
    }

    private func send() {
        sending = true
        Task {
            do {
                try await enrol(samples)
                dismiss()
            } catch {
                message = error.localizedDescription
                sending = false
            }
        }
    }
}
