import ActivityKit
import SwiftUI
import WidgetKit

/// A Jarvis button's countdown outside the app, laid out like Apple's Timer: a small header
/// (icon · name, the state on the right), the big time left that the system ticks itself, a red
/// Stop on the right and a progress bar under it. When it finishes it shows the result with a
/// checkmark for a few seconds. The island: icon + state word left, time right; expanded adds
/// Stop and the bar. Started and fed by `ButtonActivityController` and the server's pushes.
struct ButtonActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ButtonActivityAttributes.self) { context in
            ButtonActivityCard(look: ButtonActivityLook(context))
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let look = ButtonActivityLook(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: look.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(look.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(look.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            if !look.word.isEmpty {
                                Text(look.word)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(look.wordColor)
                            }
                        }
                        .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if look.finished {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(JcAccent.color)
                        } else if let range = look.countdown {
                            ButtonCountdownText(range: range, tint: look.tint,
                                                font: .system(size: 30, weight: .semibold, design: .rounded))
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let range = look.progress {
                            ButtonProgressBar(range: range, tint: look.tint)
                        }
                        if look.finished {
                            Text(look.result)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        } else if look.showsStop {
                            ButtonStopButton(look: look, height: 40, wide: true)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: look.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(look.tint)
                    if let word = look.shortWord {
                        Text(word)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(look.wordColor)
                            .lineLimit(1)
                    }
                }
            } compactTrailing: {
                if look.finished {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(JcAccent.color)
                } else if let range = look.countdown {
                    ButtonCountdownText(range: range, tint: look.tint,
                                        font: .system(size: 14, weight: .semibold, design: .rounded))
                        .frame(maxWidth: 56)
                } else {
                    Image(systemName: look.state.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(look.tint)
                }
            } minimal: {
                Image(systemName: look.finished ? "checkmark" : look.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(look.finished ? JcAccent.color : look.tint)
            }
            .keylineTint(look.tint)
        }
    }
}

/// Lock Screen card, layout A.
private struct ButtonActivityCard: View {
    let look: ButtonActivityLook

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: look.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(look.tint)
                Text(look.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(look.word)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(look.wordColor)
                    .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 12) {
                main
                    .frame(maxWidth: .infinity, alignment: .leading)
                if look.showsStop {
                    ButtonStopButton(look: look, height: 44, wide: false)
                        .layoutPriority(1)
                }
            }
            if let range = look.progress {
                ButtonProgressBar(range: range, tint: look.tint)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var main: some View {
        if look.finished {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(JcAccent.color)
                Text(look.result)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } else if let range = look.countdown {
            ButtonCountdownText(range: range, tint: look.tint,
                                font: .system(size: 44, weight: .semibold, design: .rounded),
                                alignment: .leading)
        } else {
            Text(look.state.caption ?? look.state.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(look.state.alert ? JcState.danger : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// What the card and the island draw, worked out once from the activity.
private struct ButtonActivityLook {
    let attributes: ButtonActivityAttributes
    let state: ButtonLiveState
    let finished: Bool
    let result: String
    /// The time left, while there is some and the card isn't stale.
    let countdown: ClosedRange<Date>?
    /// The bar, when it is known when the thing started.
    let progress: ClosedRange<Date>?
    let stale: Bool

    init(_ context: ActivityViewContext<ButtonActivityAttributes>) {
        attributes = context.attributes
        state = context.state.state
        finished = context.state.finished
        result = context.state.result ?? context.state.state.caption ?? "Done"
        stale = context.isStale
        if !finished, !stale, let ends = state.endsAt, ends > Date() {
            let start = min(state.startedAt ?? ends, ends)
            // The countdown runs from now: a card with no start time would otherwise read 0:00.
            countdown = min(Date(), ends)...ends
            progress = start < ends ? start...ends : nil
        } else {
            countdown = nil
            progress = nil
        }
    }

    var name: String { attributes.name }
    var symbol: String { attributes.symbol }

    /// Red while going off, else the button's own colour or the accent.
    var tint: Color {
        if state.alert { return JcState.danger }
        guard let hex = state.tint, let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
        else { return JcAccent.color }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// The header's state word: "Away in", "Done".
    var word: String { finished ? "Done" : (state.caption ?? "") }
    var wordColor: Color { state.alert && !finished ? JcState.danger : .white.opacity(0.6) }
    /// The word beside the icon in the small island, when it fits.
    var shortWord: String? {
        guard !finished, let caption = state.caption, !caption.isEmpty, caption.count <= 8 else { return nil }
        return caption
    }

    /// Stop stays off a finished card, and off a stale one (its state has moved on).
    var showsStop: Bool { !finished && !stale }
}

/// The time left, ticked by the system.
private struct ButtonCountdownText: View {
    let range: ClosedRange<Date>
    let tint: Color
    let font: Font
    var alignment: TextAlignment = .trailing

    var body: some View {
        Text(timerInterval: range, countsDown: true)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(alignment)
    }
}

private struct ButtonProgressBar: View {
    let range: ClosedRange<Date>
    let tint: Color

    var body: some View {
        ProgressView(timerInterval: range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
            .tint(tint)
    }
}

/// Stop (or whatever the state's press does): the app's liquid-glass button redrawn for a Live
/// Activity (`AgentGlassButtonLabel`), red. Presses the button for the state the card shows.
private struct ButtonStopButton: View {
    let look: ButtonActivityLook
    let height: CGFloat
    let wide: Bool

    var body: some View {
        // Disarm / Silence: iOS unlocks the iPhone first, then the press runs with that as approval.
        if StopButtonActivityIntent.needsUnlock(look.state.id) {
            Button(intent: UnlockedButtonActivityIntent(buttonID: look.attributes.buttonID, stateID: look.state.id)) { label }
                .buttonStyle(.plain)
        } else {
            Button(intent: StopButtonActivityIntent(buttonID: look.attributes.buttonID, stateID: look.state.id)) { label }
                .buttonStyle(.plain)
        }
    }

    private var label: some View {
            HStack(spacing: 6) {
                Image(systemName: look.state.symbol)
                    .font(.system(size: 13, weight: .bold))
                Text(look.state.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(JcState.danger)
            .padding(.horizontal, 16)
            .frame(maxWidth: wide ? .infinity : nil, minHeight: height)
            .background(Capsule().fill(Color.white.opacity(0.11)))
            .background(Capsule().fill(JcState.danger.opacity(0.2)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
    }
}
