import CoreMotion
import Foundation

/// Steps (and floors, and a stride-based distance) from the phone in a
/// pocket, for indoor workouts the ring can't count: hands on a stair
/// climber's or treadmill's rails leave the ring still.
@MainActor
protocol WorkoutStepCounting: AnyObject {
    func start(from date: Date)
    func stop()
    var steps: Int? { get }
    /// Steps a minute right now.
    var cadence: Int? { get }
    var floors: Int? { get }
    /// Metres, from the phone's own stride estimate.
    var distance: Double? { get }
}

@MainActor
final class PhonePedometer: WorkoutStepCounting {
    private let pedometer = CMPedometer()
    private(set) var steps: Int?
    private(set) var cadence: Int?
    private(set) var floors: Int?
    private(set) var distance: Double?

    func start(from date: Date) {
        steps = nil
        cadence = nil
        floors = nil
        distance = nil
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: date) { [weak self] data, _ in
            guard let data else { return }
            let steps = data.numberOfSteps.intValue
            let cadence = data.currentCadence.map { Int(($0.doubleValue * 60).rounded()) }
            let floors = data.floorsAscended?.intValue
            let distance = data.distance?.doubleValue
            Task { @MainActor in
                self?.steps = steps
                self?.cadence = cadence
                self?.floors = floors
                self?.distance = distance
            }
        }
    }

    func stop() {
        pedometer.stopUpdates()
    }
}

/// The ring's day totals turned into a workout's: every reading adds what
/// the day count rose by since the last one (after midnight the count starts
/// again from zero, and all of it is new).
struct RingDayCounter {
    private(set) var steps = 0
    private(set) var meters = 0
    private(set) var hasReadings = false
    private var last: (steps: Int, meters: Int)?
    private var marks: [(at: Date, steps: Int)] = []

    mutating func read(steps day: Int, meters dayMeters: Int, at time: Date) {
        if let last {
            steps += day >= last.steps ? day - last.steps : day
            meters += dayMeters >= last.meters ? dayMeters - last.meters : dayMeters
        }
        last = (day, dayMeters)
        hasReadings = true
        marks.append((time, steps))
        marks.removeAll { time.timeIntervalSince($0.at) > 75 }
    }

    /// Steps a minute over the last minute or so of readings.
    var cadence: Int? {
        guard let first = marks.first, let end = marks.last else { return nil }
        let seconds = end.at.timeIntervalSince(first.at)
        guard seconds >= 20 else { return nil }
        return Int((Double(end.steps - first.steps) / seconds * 60).rounded())
    }
}
