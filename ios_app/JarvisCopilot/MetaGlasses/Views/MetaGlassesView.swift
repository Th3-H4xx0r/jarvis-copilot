import SwiftUI

/// Ray-Ban Meta (Gen 2) on Devices → Wearables. Always shown, like the INMO card, and marked
/// Simulated until the real Bluetooth link exists — its page runs a simulated glasses turn
/// through the real Jarvis voice engine.
struct MetaGlassesCard: View {
    var body: some View {
        DeviceCard(name: "Meta glasses", subtitle: MetaGlassesDevice.model) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(JcTheme.muted)
                .frame(width: 124, height: 124)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
        } pills: {
            MetricPill(icon: "testtube.2", label: "Status", value: "Simulated", tint: JcTheme.muted)
        }
    }
}

/// The Meta glasses page: try a simulated turn, see what the glasses received, and what's
/// still waiting for the real glasses.
struct MetaGlassesView: View {
    @StateObject private var runner = MetaGlassesSimRunner()
    @FocusState private var promptFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your glasses aren't connected yet. Run a simulated turn: software glasses say “Hey Jarvis” and your prompt, and Jarvis answers out loud through the same path the real glasses will use.")
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                JcSectionLabel("Try it")
                JcCard {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("What should the glasses hear?", text: $runner.prompt, axis: .vertical)
                            .font(.system(size: 16))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1 ... 3)
                            .focused($promptFocused)
                            .submitLabel(.go)
                            .disabled(runner.isRunning)
                            .onSubmit(run)
                        if runner.isRunning {
                            Button(action: stop) {
                                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.jcGlass)
                        } else {
                            GradientButton("Run simulated glasses", symbol: "play.fill", full: true, action: canRun ? run : nil)
                        }
                        if case .failed(let why) = runner.phase {
                            Label(why, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13))
                                .foregroundStyle(JcTheme.muted)
                        }
                    }
                }

                if !runner.rows.isEmpty || runner.isRunning {
                    JcSectionLabel("What the glasses get")
                    JcCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(runner.rows) { row in
                                logRow(row)
                            }
                            if runner.isRunning {
                                HStack(spacing: 10) {
                                    JcLoader(size: 16)
                                    Text("Listening through the simulated glasses…")
                                        .font(.system(size: 13))
                                        .foregroundStyle(JcTheme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, JcUnified.cardPadding)
                                .padding(.vertical, 14)
                            } else if let latency = runner.wakeToAnswer {
                                JcRow(symbol: "timer", title: "Wake → Jarvis speaking", value: Self.seconds(latency), last: true)
                            }
                        }
                    }
                }

                JcSectionLabel("Status")
                JcCard(padding: 0) {
                    VStack(spacing: 0) {
                        JcRow(symbol: "dot.radiowaves.left.and.right", title: "Bluetooth link",
                              subtitle: "Not built yet — needs your glasses", value: "Waiting")
                        JcRow(symbol: "waveform.badge.mic", title: "“Hey Jarvis” on the glasses",
                              subtitle: "Set up once the glasses are here", value: "Waiting", last: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(JcTheme.bg.ignoresSafeArea())
        .jcPageChrome("Meta glasses")
        .onDisappear { Task { await runner.stop() } }
    }

    private func logRow(_ row: MetaGlassesSimRunner.Row) -> some View {
        let isLast: Bool = row.id == runner.rows.count - 1 && !runner.isRunning && runner.wakeToAnswer == nil
        let time: String = Self.seconds(row.at)
        return JcRow(symbol: row.symbol, title: row.title, subtitle: row.detail, value: time, last: isLast)
    }

    private var canRun: Bool {
        !runner.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func run() {
        guard canRun, !runner.isRunning else { return }
        promptFocused = false
        Task { await runner.run() }
    }

    private func stop() {
        Task { await runner.stop() }
    }

    static func seconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f s", ms / 1000)
    }
}
