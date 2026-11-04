import SwiftUI

// The workout Live Activity's views: the Lock Screen and the Dynamic Island's
// regions, for every sport. Plain SwiftUI in Copilot/Shared so the widget draws
// them (`RingWorkoutActivity`) and the app's render tests can too.
//
// The look follows Apple's own Fitness activity: the sport's figure on an accent
// disc, the time large in rounded figures, small grey labels. The accent marks
// the sport and a running rest; red is only the heart; the zone bar is the one
// place with several colours, each a heart-rate zone.

/// Text roles on the Live Activity's dark glass.
enum WorkoutLA {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let well = Color.white.opacity(0.14)

    /// Heart-rate zone colours, the same as the in-app workout screen.
    static func zoneTint(_ zone: Int) -> Color {
        switch zone {
        case 1: return JcAccent.soft
        case 2: return JcAccent.color
        case 3: return JcState.success
        case 4: return JcState.amber
        default: return JcState.danger
        }
    }

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

/// Strength's "Bench Press · set 3 · 60 kg × 8", split into the exercise and the set.
struct WorkoutNextSet: Equatable {
    let exercise: String
    let set: String

    init?(_ detail: String?) {
        guard let detail, !detail.isEmpty else { return nil }
        let parts = detail.components(separatedBy: " · ")
        exercise = parts[0]
        let rest = parts.dropFirst().joined(separator: " · ")
        set = rest.isEmpty ? "" : rest.prefix(1).uppercased() + rest.dropFirst()
    }
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

/// The sport's figure in black on the accent disc.
struct WorkoutSportDisc: View {
    let symbol: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(JcAccent.color))
    }
}

/// Five short bars, the zone the heart rate is in lit in its colour.
struct WorkoutZoneBar: View {
    let zone: Int
    var segment = CGSize(width: 12, height: 4)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { z in
                Capsule()
                    .fill(z == zone ? WorkoutLA.zoneTint(z) : WorkoutLA.well)
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

/// The sport and what it's doing now: "Paused", "Resting", "Zone 3".
struct WorkoutTitle: View {
    let sport: String
    let state: RingWorkoutAttributes.ContentState
    let resting: Bool
    var size: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(sport)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(WorkoutLA.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(status)
                .font(.system(size: size - 4, weight: .regular))
                .foregroundStyle(state.running ? WorkoutLA.secondary : JcState.amber)
                .lineLimit(1)
        }
    }

    private var status: String {
        if !state.running { return "Paused" }
        if resting { return "Resting" }
        if state.detail != nil { return "Lifting" }
        if let zone = state.zone, state.heartRate != nil { return "Zone \(zone)" }
        return "In progress"
    }
}

/// The next set, for strength: "Next · Set 3 · 60 kg × 8" over the exercise,
/// which gets the whole line to itself.
struct WorkoutNextSetView: View {
    let next: WorkoutNextSet
    var size: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(next.set.isEmpty ? "Next" : "Next · \(next.set)")
                .font(WorkoutLA.figures(size - 4, .regular))
                .foregroundStyle(WorkoutLA.secondary)
                .lineLimit(1)
            Text(next.exercise)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(WorkoutLA.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// The big number on the right: a rest counting down in the accent, else the workout's time.
struct WorkoutClock: View {
    let state: RingWorkoutAttributes.ContentState
    let rest: RestWindow?
    var size: CGFloat = 34

    var body: some View {
        if let rest {
            Text(timerInterval: rest.range, countsDown: true)
                .font(WorkoutLA.figures(size))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(JcAccent.color)
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
            .tint(JcAccent.color)
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
        let next = WorkoutNextSet(state.detail)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                WorkoutSportDisc(symbol: symbol, size: 40)
                WorkoutTitle(sport: sport, state: state, resting: rest != nil)
                Spacer(minLength: 8)
                WorkoutClock(state: state, rest: rest, size: 34)
                    .fixedSize()
            }
            if let next {
                HStack(alignment: .bottom, spacing: 12) {
                    WorkoutNextSetView(next: next)
                    Spacer(minLength: 8)
                    if let hr = state.heartRate {
                        WorkoutMetric(value: "\(hr)", unit: "bpm", symbol: "heart.fill", size: 17)
                    }
                }
            } else if state.heartRate != nil || state.distanceKm != nil {
                WorkoutMetricsRow(state: state)
            }
            if let rest { WorkoutRestBar(rest: rest) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }
}

// MARK: - Dynamic Island

/// Expanded, leading: the disc and the sport.
struct WorkoutIslandLeading: View {
    let sport: String
    let symbol: String
    let state: RingWorkoutAttributes.ContentState
    var isStale = false

    var body: some View {
        HStack(spacing: 10) {
            WorkoutSportDisc(symbol: symbol, size: 36)
            WorkoutTitle(sport: sport, state: state, resting: RestWindow(state, isStale: isStale) != nil, size: 15)
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

/// Expanded, bottom: the next set or the metrics, and a rest's bar.
struct WorkoutIslandBottom: View {
    let state: RingWorkoutAttributes.ContentState
    var isStale = false

    var body: some View {
        let rest = RestWindow(state, isStale: isStale)
        VStack(alignment: .leading, spacing: 10) {
            if let next = WorkoutNextSet(state.detail) {
                HStack(alignment: .bottom, spacing: 12) {
                    WorkoutNextSetView(next: next, size: 15)
                    Spacer(minLength: 8)
                    if let hr = state.heartRate {
                        WorkoutMetric(value: "\(hr)", unit: "bpm", symbol: "heart.fill", size: 15)
                    }
                }
            } else {
                WorkoutMetricsRow(state: state, size: 18)
            }
            if let rest { WorkoutRestBar(rest: rest) }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

/// Collapsed, leading: the sport's figure.
struct WorkoutCompactLeading: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(JcAccent.color)
    }
}

/// Collapsed, trailing: the time, or the rest counting down in the accent.
struct WorkoutCompactTrailing: View {
    let state: RingWorkoutAttributes.ContentState
    var isStale = false

    var body: some View {
        WorkoutClock(state: state, rest: RestWindow(state, isStale: isStale), size: 15)
            .frame(maxWidth: 60, alignment: .trailing)
    }
}
