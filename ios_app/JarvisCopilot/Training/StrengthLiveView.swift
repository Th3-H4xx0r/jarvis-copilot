import SwiftUI

/// A strength workout under way: the clock, heart rate, and each exercise's
/// sets to fill in and tick, with the rest timer on top and the keypad below.
struct StrengthLiveView: View {
    @ObservedObject var workout: RingWorkoutController
    @ObservedObject var session: StrengthSession
    @State private var confirmingFinish = false
    @State private var confirmingCancel = false
    @State private var showingRest = false

    private var undone: Int { session.log.exercises.flatMap(\.sets).filter { !$0.isDone }.count }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        StrengthExerciseList(session: session)
                        Button("Cancel Workout", role: .destructive) { confirmingCancel = true }
                            .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.focus) { _, focus in
                    if let focus { withAnimation { proxy.scrollTo(focus.set, anchor: .center) } }
                }
            }
            SetKeypad(session: session)
        }
        .animation(.snappy, value: session.focus != nil)
        .animation(.snappy, value: session.rest != nil)
        .confirmationDialog(undone > 0 ? "\(undone) sets aren't done" : "Finish workout?",
                            isPresented: $confirmingFinish, titleVisibility: .visible) {
            Button(undone > 0 ? "Finish Anyway" : "Finish") { workout.end() }
            Button("Keep Going", role: .cancel) {}
        } message: {
            if undone > 0 { Text("Unticked sets are left out of the workout.") }
        }
        .confirmationDialog("Cancel this workout?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancel Workout", role: .destructive) { workout.cancelStrength() }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("Nothing from it is saved.")
        }
        .sheet(isPresented: $showingRest) {
            RestTimerView(session: session)
                .presentationDetents([.large])
                .presentationBackground(JcTheme.bg)
        }
        .onChange(of: session.rest == nil) { _, ended in if ended { showingRest = false } }
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(WorkoutLiveView.clock(workout.elapsed(at: context.date)))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                restControl
                Spacer()
                Button("Finish") { confirmingFinish = true }
                    .buttonStyle(.jcGlass(tint: JcTheme.success, compact: true))
                    .disabled(session.log.exercises.flatMap(\.sets).allSatisfy { !$0.isDone })
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var restControl: some View {
        if let rest = session.rest {
            Button { showingRest = true } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = rest.remaining(at: context.date)
                    HStack(spacing: 6) {
                        Image(systemName: "timer").font(.system(size: 13, weight: .bold))
                        Text(SetRow.clock(left))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .foregroundStyle(left <= 10 ? Color.black : JcTheme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(left <= 10 ? JcTheme.amber : JcTheme.accent.opacity(0.16), in: Capsule())
                    .animation(.snappy, value: left)
                }
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Rest timer")
        } else {
            Menu {
                ForEach([60, 90, 120, 180, 300], id: \.self) { seconds in
                    Button(SetRow.clock(seconds)) { session.startRest(seconds: seconds, after: UUID()) }
                }
            } label: {
                Image(systemName: "timer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
                    .frame(width: 38, height: 32)
                    .background(JcTheme.accent.opacity(0.14), in: Capsule())
            }
            .accessibilityLabel("Start a rest timer")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Workout name", text: $session.log.name)
                .font(.title2.weight(.bold))
                .submitLabel(.done)
            Text(session.log.started.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            vitals
            TextField("Add a note", text: $session.log.note, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }

    private var vitals: some View {
        let totals = TrainingMath.totals(session.log)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    RingMetricSymbol(name: "heart.fill", tint: RingMeasurementType.heartRate.tint,
                                     pulsing: workout.tick?.heartRate != nil, size: 15)
                    Text(workout.tick?.heartRate.map(String.init) ?? "--")
                        .font(.system(.headline, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let zone = workout.zone {
                        Text("Zone \(zone)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WorkoutLiveView.zoneTint(zone))
                    }
                }
                stat("scalemass", "\(Int(session.unit.show(totals.volumeKg).rounded()).formatted()) \(session.unit.symbol)")
                stat("checkmark.circle", totals.sets == 1 ? "1 set" : "\(totals.sets) sets")
            }
            if let note = workout.vitalsNote {
                Label(note, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(JcTheme.amber)
            }
        }
        .animation(.snappy, value: workout.tick?.heartRate)
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// The rest, full screen: a ring running down, ±15 s and Skip.
struct RestTimerView: View {
    @ObservedObject var session: StrengthSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 40, height: 5).padding(.top, 10)
            Spacer()
            Text("Rest").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            if let rest = session.rest {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let left = max(0, rest.ends.timeIntervalSince(context.date))
                    let share = rest.total > 0 ? left / Double(rest.total) : 0
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.08), lineWidth: 16)
                        Circle()
                            .trim(from: 0, to: min(1, share))
                            .stroke(left <= 10 ? JcTheme.amber : JcTheme.accent,
                                    style: StrokeStyle(lineWidth: 16, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 4) {
                            Text(SetRow.clock(Int(left.rounded(.up))))
                                .font(.system(size: 64, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("of \(SetRow.clock(rest.total))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 270, height: 270)
                }
            }
            if let detail = session.detail {
                Text("Next: \(detail)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            HStack(spacing: 14) {
                Button("−15 s") { session.adjustRest(by: -15) }
                    .buttonStyle(.jcGlass(tint: .secondary, full: true))
                Button("+15 s") { session.adjustRest(by: 15) }
                    .buttonStyle(.jcGlass(tint: .secondary, full: true))
                Button("Skip") {
                    session.skipRest()
                    dismiss()
                }
                .buttonStyle(.jcGlass(full: true))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .preferredColorScheme(.dark)
    }
}
