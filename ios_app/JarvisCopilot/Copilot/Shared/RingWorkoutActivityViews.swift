import AppIntents
import SwiftUI

// The workout Live Activity's views: the Lock Screen and the Dynamic Island's
// regions, for every sport. Plain SwiftUI in Copilot/Shared so the widget draws
// them (`RingWorkoutActivity`) and the app's render tests can too.
//
// Black and white (his pick, 2026-11-03), laid out like Apple's own Fitness
// activity: the sport's figure in black on a white disc, the time large in
// rounded figures, small grey labels. The only colour is the red heart.
//
// Buttons (`WorkoutLiveActionIntent`): lifting — weight −/+, reps −/+ and ✓ to
// log the set; resting — −15s, +15s, Skip; every other sport — Pause / Resume.
// The one that goes ahead is white with black text, the rest grey.

/// Text roles on the Live Activity's dark glass.
enum WorkoutLA {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let well = Color.white.opacity(0.14)

    static func figures(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// A strength rest the widget counts down by itself.
struct RestWindow: Equatable {
    let range: ClosedRange<Date>

    init?(_ state: RingWorkoutAttributes.ContentState, isStale: Bool, now: Date = Date()) {
        guard !isStale, let ends = state.restEnds, ends > now else { return nil }
        range = min(state.restStarted ?? ends, ends)...ends
    }
}

/// Strength's "Bench Press · set 3 · 60 kg × 8", split into the exercise
/// ("Bench Press"), the set ("Set 3") and its values ("60 kg × 8").
struct WorkoutNextSet: Equatable {
    let exercise: String
    let number: String
    let values: String

    init?(_ detail: String?) {
        guard let detail, !detail.isEmpty else { return nil }
        let parts = detail.components(separatedBy: " · ")
        exercise = parts[0]
        let n = parts.count > 1 ? parts[1] : ""
        number = n.prefix(1).uppercased() + n.dropFirst()
        values = parts.dropFirst(2).joined(separator: " · ")
    }

    /// "Set 3 · 60 kg × 8".
    var set: String { [number, values].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// Counts up by itself while running; the frozen time while paused.
struct WorkoutTimerText: View {
    let state: RingWorkoutAttributes.ContentState
    let font: Font

    var body: some View {
        Group {
            if state.running {
                Text(timerInterval: state.reference...Date.distantFuture, countsDown: false)
            } else {
                Text(Duration.seconds(state.frozenElapsed).formatted(
                    .time(pattern: state.frozenElapsed >= 3600 ? .hourMinuteSecond : .minuteSecond)))
            }
        }
        .font(font)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .foregroundStyle(state.running ? WorkoutLA.primary : WorkoutLA.secondary)
    }
}

/// The sport's figure in black on a white disc.
struct WorkoutSportDisc: View {
    let symbol: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white))
    }
}

/// Five short bars, the zone the heart rate is in lit white.
struct WorkoutZoneBar: View {
    let zone: Int
    var segment = CGSize(width: 12, height: 4)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { z in
                Capsule()
                    .fill(z == zone ? WorkoutLA.primary : WorkoutLA.well)
                    .frame(width: segment.width, height: segment.height)
            }
        }
        .accessibilityLabel("Zone \(zone)")
    }
}

/// A value with its unit beside it: "148 bpm", "3.42 mi".
struct WorkoutMetric: View {
    let value: String
    let unit: String
    var symbol: String? = nil
    var size: CGFloat = 20

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .foregroundStyle(JcState.danger)
            }
            Text(value).font(WorkoutLA.figures(size)).foregroundStyle(WorkoutLA.primary)
            Text(unit).font(.system(size: size * 0.6, weight: .medium)).foregroundStyle(WorkoutLA.secondary)
        }
        .lineLimit(1)
    }
}

/// Heart rate, distance and the zone, in one row.
struct WorkoutMetricsRow: View {
    let state: RingWorkoutAttributes.ContentState
    var size: CGFloat = 20

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let hr = state.heartRate {
                WorkoutMetric(value: "\(hr)", unit: "bpm", symbol: "heart.fill", size: size)
            }
            if let km = state.distanceKm {
                let miles = state.miles == true
                WorkoutMetric(value: String(format: "%.2f", miles ? km / 1.609344 : km),
                              unit: miles ? "mi" : "km", size: size)
            }
            Spacer(minLength: 0)
            if let zone = state.zone, state.heartRate != nil {
                WorkoutZoneBar(zone: zone)
            }
        }
    }
}

/// The title and the line under it. Strength: the next exercise, then "Set 3 ·
/// Push day · ♥ 134" (or, resting, "Next: Set 3 · 60 kg × 8"). Other sports:
/// the sport, then "Zone 3" / "Paused".
struct WorkoutHeading: View {
    let sport: String
    let state: RingWorkoutAttributes.ContentState
    let resting: Bool
    var size: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(WorkoutLA.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            subtitle
                .font(.system(size: size - 4))
                .foregroundColor(WorkoutLA.secondary)
                .lineLimit(1)
        }
    }

    private var next: WorkoutNextSet? { WorkoutNextSet(state.detail) }

    private var title: String { next?.exercise ?? sport }

    private var subtitle: Text {
        if let next {
            if resting { return Text(next.set.isEmpty ? "Resting" : "Next: \(next.set)") }
            var line = Text([next.number, sport].filter { !$0.isEmpty }.joined(separator: " · "))
            if let hr = state.heartRate {
                line = line + Text("  ") + Text(Image(systemName: "heart.fill")).foregroundColor(JcState.danger)
                    + Text(" \(hr)")
            }
            return line
        }
        if !state.running { return Text("Paused") }
        if resting { return Text("Resting") }
        if let zone = state.zone, state.heartRate != nil { return Text("Zone \(zone)") }
        return Text("In progress")
    }
}

/// The big number on the right: a rest counting down, else the workout's time.
struct WorkoutClock: View {
    let state: RingWorkoutAttributes.ContentState
    let rest: RestWindow?
    var size: CGFloat = 34

    var body: some View {
        if let rest {
            Text(timerInterval: rest.range, countsDown: true)
                .font(WorkoutLA.figures(size))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(WorkoutLA.primary)
        } else {
            WorkoutTimerText(state: state, font: WorkoutLA.figures(size))
        }
    }
}

/// The rest draining, under everything (the system fills it by itself).
struct WorkoutRestBar: View {
    let rest: RestWindow
    var body: some View {
        ProgressView(timerInterval: rest.range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
            .progressViewStyle(.linear)
            .tint(WorkoutLA.primary)
    }
}

// MARK: - Buttons

/// A solid capsule: grey with white text, or white with black text for the one
/// that goes ahead (Log, Skip, Resume).
struct WorkoutButtonLabel: View {
    var text: String? = nil
    var symbol: String? = nil
    var filled = false
    var height: CGFloat = 36

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .semibold)) }
            if let text { Text(text).font(.system(size: 15, weight: .semibold)).lineLimit(1) }
        }
        .foregroundStyle(filled ? Color.black : Color.white)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(Capsule().fill(filled ? Color.white : WorkoutLA.well))
    }
}

/// "− 60 kg +": the value between two buttons on one grey capsule.
struct WorkoutStepper: View {
    let value: String
    let down: WorkoutLiveAction
    let up: WorkoutLiveAction
    var height: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            Button(intent: WorkoutLiveActionIntent(down)) {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Less")
            Text(value)
                .font(WorkoutLA.figures(15))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
            Button(intent: WorkoutLiveActionIntent(up)) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More")
        }
        .foregroundStyle(Color.white)
        .frame(height: height)
        .background(Capsule().fill(WorkoutLA.well))
    }
}

/// The row of buttons for what the workout is doing now.
struct WorkoutControls: View {
    let state: RingWorkoutAttributes.ContentState
    let rest: RestWindow?
    var height: CGFloat = 36

    var body: some View {
        if state.detail != nil {
            if rest != nil {
                HStack(spacing: 8) {
                    action(.restShorter, WorkoutButtonLabel(text: "−15s", height: height))
                    action(.restLonger, WorkoutButtonLabel(text: "+15s", height: height))
                    action(.skipRest, WorkoutButtonLabel(text: "Skip", filled: true, height: height))
                }
            } else if state.weight == nil && state.reps == nil {
                action(.logSet, WorkoutButtonLabel(text: "Log set", symbol: "checkmark", filled: true, height: height))
            } else {
                HStack(spacing: 8) {
                    if let weight = state.weight {
                        WorkoutStepper(value: "\(weight) \(state.weightUnit ?? "kg")",
                                       down: .weightDown, up: .weightUp, height: height)
                    }
                    if let reps = state.reps {
                        WorkoutStepper(value: reps > 0 ? "\(reps) reps" : "– reps",
                                       down: .repsDown, up: .repsUp, height: height)
                    }
                    Button(intent: WorkoutLiveActionIntent(.logSet)) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: height + 8, height: height)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log set")
                }
            }
        } else if state.running {
            action(.pause, WorkoutButtonLabel(text: "Pause", symbol: "pause.fill", height: height))
        } else {
            action(.resume, WorkoutButtonLabel(text: "Resume", symbol: "play.fill", filled: true, height: height))
        }
    }

    private func action(_ what: WorkoutLiveAction, _ label: WorkoutButtonLabel) -> some View {
        Button(intent: WorkoutLiveActionIntent(what)) { label }
            .buttonStyle(.plain)
    }
}

// MARK: - Lock Screen

struct WorkoutLockScreenView: View {
    let sport: String
    let symbol: String
    let state: RingWorkoutAttributes.ContentState
    var isStale = false

    var body: some View {
        let rest = RestWindow(state, isStale: isStale)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                WorkoutSportDisc(symbol: symbol, size: 40)
                WorkoutHeading(sport: sport, state: state, resting: rest != nil)
                Spacer(minLength: 8)
                WorkoutClock(state: state, rest: rest, size: 34)
                    .fixedSize()
            }
            if state.detail == nil && (state.heartRate != nil || state.distanceKm != nil) {
                WorkoutMetricsRow(state: state)
            }
            WorkoutControls(state: state, rest: rest)
            if let rest { WorkoutRestBar(rest: rest) }
        }
        .padding(16)
    }
}

// MARK: - Dynamic Island

/// Expanded, leading: the disc and the heading.
struct WorkoutIslandLeading: View {
    let sport: String
    let symbol: String
    let state: RingWorkoutAttributes.ContentState
    var isStale = false

    var body: some View {
        HStack(spacing: 10) {
            WorkoutSportDisc(symbol: symbol, size: 36)
            // Strength's exercise names are long: they go full width in the bottom row.
            if state.detail == nil {
                WorkoutHeading(sport: sport, state: state, resting: RestWindow(state, isStale: isStale) != nil, size: 15)
            }
        }
        .padding(.leading, 4)
    }
}

/// Expanded, trailing: the time (or the rest).
struct WorkoutIslandTrailing: View {
    let state: RingWorkoutAttributes.ContentState
    var isStale = false

    var body: some View {
        WorkoutClock(state: state, rest: RestWindow(state, isStale: isStale), size: 30)
            .frame(maxWidth: 120, alignment: .trailing)
            .padding(.trailing, 4)
    }
}

/// Expanded, bottom: strength's exercise and set, or the metrics; the buttons; a rest's bar.
struct WorkoutIslandBottom: View {
    var sport = ""
    let state: RingWorkoutAttributes.ContentState
    var isStale = false

    var body: some View {
        let rest = RestWindow(state, isStale: isStale)
        VStack(alignment: .leading, spacing: 8) {
            if state.detail != nil {
                WorkoutHeading(sport: sport, state: state, resting: rest != nil, size: 15)
            }
            if state.detail == nil && (state.heartRate != nil || state.distanceKm != nil) {
                WorkoutMetricsRow(state: state, size: 17)
            }
            WorkoutControls(state: state, rest: rest, height: 34)
            if let rest { WorkoutRestBar(rest: rest) }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

/// Collapsed, leading: the sport's figure.
struct WorkoutCompactLeading: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(WorkoutLA.primary)
    }
}

/// Collapsed, trailing: the time, or the rest counting down.
struct WorkoutCompactTrailing: View {
    let state: RingWorkoutAttributes.ContentState
    var isStale = false

    var body: some View {
        WorkoutClock(state: state, rest: RestWindow(state, isStale: isStale), size: 15)
            .frame(maxWidth: 60, alignment: .trailing)
    }
}
