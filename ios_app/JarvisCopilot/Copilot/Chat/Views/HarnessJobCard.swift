import SwiftUI

/// A harness Background job under the reply that started it: what it is doing,
/// a running clock and Stop, then one quiet line once it ends. Same words as
/// the web card (`webui/static/harness_jobs.js`).
struct HarnessJobCard: View {
    let job: HarnessJob
    var onStop: (() -> Void)?

    @State private var stopping = false

    var body: some View {
        if job.isRunning { running } else { ended }
    }

    private var running: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                PulsingJobDot()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(job.label).fontWeight(.semibold).foregroundStyle(JcTheme.text)
                        if !job.model.isEmpty {
                            Text(HarnessFormat.shortModel(job.model)).foregroundStyle(JcTheme.muted)
                        }
                    }
                    Text(HarnessJobFormat.detail(job)).foregroundStyle(JcTheme.muted)
                }
                .font(.footnote)
                .lineLimit(1)
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(HarnessJobFormat.clock(context.date.timeIntervalSince1970 - job.startedAt))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(JcTheme.muted)
                }
            }
            // The text reads as one element; Stop stays its own button.
            .accessibilityElement(children: .combine)
            if let onStop {
                Button(stopping || job.stopping ? "Stopping…" : "Stop") {
                    stopping = true
                    onStop()
                }
                .buttonStyle(.jcGlass(tint: JcTheme.text, compact: true))
                .disabled(stopping || job.stopping)
                .accessibilityLabel("Stop \(job.label)")
                // The server says "stopping" once it has the request; if that never
                // comes (the request failed) the button is usable again.
                .task(id: stopping) {
                    guard stopping else { return }
                    try? await Task.sleep(for: .seconds(6))
                    if !job.stopping { stopping = false }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(JcTheme.accent).frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }

    private var ended: some View {
        HStack(spacing: 7) {
            JcIcon(icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            Text(HarnessJobFormat.line(job))
                .font(.footnote)
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
        }
    }

    private var icon: String {
        switch job.status {
        case "done": return "checkmark"
        case "stopped": return "stop.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch job.status {
        case "done": return JcTheme.success
        case "stopped": return JcTheme.muted
        default: return JcTheme.danger
        }
    }
}

/// The accent dot that breathes while a job runs (still when Reduce Motion is on).
private struct PulsingJobDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle()
            .fill(JcTheme.accent)
            .frame(width: 8, height: 8)
            .opacity(reduceMotion ? 1 : (on ? 1 : 0.35))
            .scaleEffect(reduceMotion ? 1 : (on ? 1 : 0.85))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
            .accessibilityHidden(true)
    }
}
