import SwiftUI

/// The Apple Watch companion's settings, replacing the Flutter client's
/// `watch_companion_page.dart`. Shows whether the watch is actually reachable
/// (the single most common reason a dictated turn fails), and the one setting
/// the watch reads.
struct WatchPage: View {
    @ObservedObject private var watch = WatchBridge.shared
    @AppStorage(WatchBridge.preferLocalVoiceKey) private var preferLocalVoice = false
    @State private var didStartNewSession = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassQuietLabel("Status")
                        row("Watch app installed", watch.isPaired ? "Yes" : "No",
                            ok: watch.isPaired)
                        row("Reachable now", watch.isReachable ? "Yes" : "Not right now",
                            ok: watch.isReachable)
                        Text(watch.isPaired
                             ? "Raise your wrist and tap the orb to dictate. The reply is spoken "
                               + "in the JARVIS voice, and appears in Chats under \"Watch\"."
                             : "Install JARVIS on your Apple Watch from the Watch app on this "
                               + "iPhone, then come back.")
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassQuietLabel("Voice")
                        Toggle("Use the watch's own voice", isOn: $preferLocalVoice)
                        Text("On, the watch speaks replies itself — instant, and nothing is "
                             + "transferred. Off, the phone synthesizes the JARVIS voice and "
                             + "sends the audio across, which sounds better but takes a moment.")
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassQuietLabel("Conversation")
                        Text("Watch turns go into their own chat, so dictating on your wrist "
                             + "never interrupts what you have open here.")
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                        Button {
                            WatchBridge.shared.startNewSession()
                            didStartNewSession = true
                        } label: {
                            Text(didStartNewSession ? "Started a new one" : "Start a new Watch chat")
                        }
                        .disabled(didStartNewSession)
                    }
                }

                if let error = watch.lastError, !error.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 6) {
                            GlassQuietLabel("Last error")
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(JcTheme.muted)
                        }
                    }
                }
            }
            .padding(16)
        }
        .jcScreen("Apple Watch")
        .task { WatchBridge.shared.activate() }
    }

    private func row(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.text)
            Spacer()
            StatusPill(value, color: ok ? JcTheme.cyan : JcTheme.muted, dense: true)
        }
    }
}
