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

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassQuietLabel("Link")
                        // A watch turn that quietly did nothing looks exactly
                        // like one that never left the wrist; these separate
                        // the two.
                        row("Turns run", "\(watch.turnsRun)", ok: true)
                        row("Turns failed", "\(watch.turnsFailed)", ok: watch.turnsFailed == 0)
                        row("Messages in", "\(watch.messagesIn)", ok: true)
                        row("Messages out", "\(watch.messagesOut)", ok: true)
                        row("Reply segments", "\(watch.segmentsSent)", ok: true)
                        row("Audio clips", "\(watch.clipsSent)", ok: true)
                        row("Audio sent", byteCount(watch.clipBytesSent), ok: true)
                        if let seconds = watch.lastTurnSeconds {
                            row("Last turn", String(format: "%.1f s", seconds), ok: true)
                        }
                        if let ms = watch.lastRoundTripMs {
                            row("Last clip handoff", "\(ms) ms", ok: true)
                        }
                        if let rate = watch.lastClipKBPerSecond {
                            row("Link speed", String(format: "%.0f KB/s", rate), ok: true)
                        }
                        row("Queued transfers", "\(watch.queuedTransfers)",
                            ok: watch.queuedTransfers == 0)
                        if let at = watch.lastTurnAt {
                            row("Last turn at", at.formatted(date: .omitted, time: .shortened), ok: true)
                        }
                        Button("Reset counters") { WatchBridge.shared.resetStatistics() }
                            .font(.system(size: 12))
                            .padding(.top, 2)
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

    private func byteCount(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
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
