import WidgetKit
import SwiftUI
import ActivityKit
#if canImport(AlarmKit)
import AlarmKit

/// The Live Activity AlarmKit shows for JARVIS alarms and timers: a countdown
/// in the Dynamic Island / Lock Screen while a timer runs, "Paused" while it
/// is paused, and "Ringing" while the system alert is up. AlarmKit owns the
/// buttons (Pause / Resume / Stop / Snooze); this only draws.
@available(iOS 26.0, *)
struct JarvisAlarmActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<JarvisAlarmMetadata>.self) { context in
            JarvisAlarmLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let tint = context.attributes.tintColor
            let label = JarvisAlarmText.label(context.attributes)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    JarvisAlarmIcon(kind: context.attributes.metadata?.kind ?? "alarm", tint: tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    JarvisAlarmTime(state: context.state, tint: tint, font: .system(size: 30, weight: .semibold, design: .rounded))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Text(JarvisAlarmText.status(context.state))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                JarvisAlarmIcon(kind: context.attributes.metadata?.kind ?? "alarm", tint: tint, size: 16)
            } compactTrailing: {
                JarvisAlarmTime(state: context.state, tint: tint, font: .system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: 64)
            } minimal: {
                JarvisAlarmIcon(kind: context.attributes.metadata?.kind ?? "alarm", tint: tint, size: 14)
            }
            .keylineTint(tint)
        }
    }
}

@available(iOS 26.0, *)
private struct JarvisAlarmLockScreen: View {
    let attributes: AlarmAttributes<JarvisAlarmMetadata>
    let state: AlarmPresentationState

    var body: some View {
        HStack(spacing: 14) {
            JarvisAlarmIcon(kind: attributes.metadata?.kind ?? "alarm", tint: attributes.tintColor, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(JarvisAlarmText.label(attributes))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(JarvisAlarmText.status(state))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            JarvisAlarmTime(state: state, tint: attributes.tintColor,
                            font: .system(size: 34, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// The remaining time for a countdown (live, no timer needed — the system
/// re-renders `Text(timerInterval:)` itself), the frozen remainder while
/// paused, and the alarm's clock time while ringing.
@available(iOS 26.0, *)
private struct JarvisAlarmTime: View {
    let state: AlarmPresentationState
    let tint: Color
    let font: Font

    var body: some View {
        Group {
            switch state.mode {
            case .countdown(let c):
                Text(timerInterval: Date.now...max(Date.now, c.fireDate), countsDown: true)
                    .monospacedDigit()
            case .paused(let p):
                Text(JarvisAlarmText.clock(max(0, p.totalCountdownDuration - p.previouslyElapsedDuration)))
                    .monospacedDigit()
            case .alert(let a):
                Text(String(format: "%02d:%02d", a.time.hour, a.time.minute))
                    .monospacedDigit()
            @unknown default:
                Text("--:--")
            }
        }
        .font(font)
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.trailing)
    }
}

private struct JarvisAlarmIcon: View {
    let kind: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: kind == "timer" ? "timer" : "alarm.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
    }
}

@available(iOS 26.0, *)
enum JarvisAlarmText {
    static func label(_ attributes: AlarmAttributes<JarvisAlarmMetadata>) -> String {
        let meta = attributes.metadata
        if let l = meta?.label, !l.isEmpty { return l }
        return meta?.kind == "timer" ? "Timer" : "Alarm"
    }

    static func status(_ state: AlarmPresentationState) -> String {
        switch state.mode {
        case .countdown: return "JARVIS · counting down"
        case .paused: return "JARVIS · paused"
        case .alert: return "JARVIS · ringing"
        @unknown default: return "JARVIS"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
#endif
