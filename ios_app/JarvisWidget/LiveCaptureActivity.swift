import ActivityKit
import SwiftUI
import WidgetKit

/// Live Jarvis recording the room, outside the app.
///
/// The one thing this has to answer, from a locked screen, is "is my phone
/// listening to this room". So it follows the same rule as the recording light
/// on the Live screen (`LiveCaptureDot`) and never carries that by colour
/// alone: a SOLID disc (every other state in this app is a hollow ring), the
/// word "Recording" or "Paused" spelled out, and `JcState.danger` last.
///
/// The clock counts itself. `startedAt` is in the attributes and therefore
/// fixed, so `Text(timerInterval:)` lets the system render the seconds with no
/// updates from the app — see `LiveCaptureAttributes` on why that is not an
/// optimisation but the only workable design.
struct LiveCaptureActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveCaptureAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        CaptureDisc(paused: context.state.paused)
                        Text(context.state.paused ? "Paused" : "Recording")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tint(context.state.paused))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CaptureClock(context: context,
                                 font: .system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                        footer(context)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                CaptureDisc(paused: context.state.paused)
            } compactTrailing: {
                CaptureClock(context: context,
                             font: .system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint(context.state.paused))
                    .frame(maxWidth: 56)
            } minimal: {
                CaptureDisc(paused: context.state.paused)
            }
            .keylineTint(tint(context.state.paused))
        }
    }

    // MARK: - Lock Screen

    private func lockScreen(_ context: ActivityViewContext<LiveCaptureAttributes>) -> some View {
        HStack(spacing: 14) {
            CaptureDisc(paused: context.state.paused, size: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.paused
                     ? "\(context.attributes.title) — paused"
                     : "\(context.attributes.title) is recording")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                footer(context)
            }
            Spacer(minLength: 6)
            CaptureClock(context: context,
                         font: .system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(tint(context.state.paused))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// The retained figure and the qualifier: two different facts, two slots,
    /// exactly as the Live screen's own footer splits them.
    @ViewBuilder
    private func footer(_ context: ActivityViewContext<LiveCaptureAttributes>) -> some View {
        let kept = context.state.kept
        let detail = context.state.detail
        if !kept.isEmpty || !detail.isEmpty {
            HStack(spacing: 8) {
                if !kept.isEmpty {
                    Text(kept).foregroundStyle(.white.opacity(0.7))
                }
                if !detail.isEmpty {
                    Text(detail)
                        .foregroundStyle(JcState.amber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
        }
    }

    private func tint(_ paused: Bool) -> Color { paused ? JcState.amber : JcState.danger }
}

/// The recording light. Solid while recording — a hollow ring while paused —
/// so the state survives greyscale and every form of colour blindness.
struct CaptureDisc: View {
    let paused: Bool
    var size: CGFloat = 11

    var body: some View {
        Group {
            if paused {
                Circle().strokeBorder(JcState.amber, lineWidth: max(1.5, size * 0.18))
            } else {
                Circle().fill(JcState.danger)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Counts up from the attributes' fixed start, so the SYSTEM ticks it. Frozen
/// at the moment of the pause while another app holds the microphone.
struct CaptureClock: View {
    let context: ActivityViewContext<LiveCaptureAttributes>
    let font: Font

    var body: some View {
        Group {
            if context.state.paused {
                Text(Duration.seconds(context.state.pausedElapsed)
                    .formatted(.time(pattern: context.state.pausedElapsed >= 3600
                                     ? .hourMinuteSecond : .minuteSecond)))
            } else {
                Text(timerInterval: context.attributes.startedAt...Date.distantFuture,
                     countsDown: false)
            }
        }
        .font(font)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}
