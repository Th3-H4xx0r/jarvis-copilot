import Combine
import SwiftUI

/// On-demand X5 readings, shared by the X5 page and the Health tab — the same card API as the
/// R12's `RingMeasureController`, so a screen shows either ring's Measure buttons the same way.
@MainActor
final class X5MeasureController: ObservableObject {
    @Published private(set) var host: RingMeasureController.Host?
    @Published private(set) var error: (type: RingMeasurementType, text: String)?
    /// Bumped when a reading finishes, so screens reload what they show.
    @Published private(set) var finished = 0

    private unowned let manager: X5Manager
    private var session: X5Session { manager.session }
    private var watching: Set<AnyCancellable> = []

    init(manager: X5Manager) {
        self.manager = manager
        manager.session.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &watching)
    }

    /// Heart rate, SpO₂ and skin temperature; the X5 has no spot HRV unless it proves a PPG.
    var types: [RingMeasurementType] { [.heartRate, .spo2, .temperature] }

    var isBusy: Bool { session.measurement?.isActive == true }

    func isMeasuring(_ type: RingMeasurementType) -> Bool {
        session.measurement?.type == type && isBusy
    }

    func start(_ type: RingMeasurementType, from host: RingMeasureController.Host) {
        error = nil
        self.host = host
        Task {
            guard await manager.ensureConnected(timeout: 12) else {
                self.error = (type, "Couldn't reach the ring")
                return
            }
            await manager.waitForSetup(timeout: 8)
            do {
                let value = try await session.measure(type)
                record(type, value: value)
            } catch {
                self.error = (type, "Couldn't take a reading")
            }
            self.finished += 1
            self.manager.releaseIfIdle()
        }
    }

    func stop() {
        Task { await session.stopMeasurement() }
    }

    func leave(_ screen: RingMeasureController.Host) {
        guard host == screen else { return }
        host = nil
    }

    /// A finished reading goes into the day, like the R12's spot checks.
    private func record(_ type: RingMeasurementType, value: Double?) {
        guard let store = manager.store else { return }
        let now = Date()
        let key = RingDates.dayKey(now)
        let minute = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        store.update(key) { day in
            day.measurements.append(RingMeasurementRecord(
                type: type.name, time: now, outcome: value == nil ? "failed" : "done",
                value: type == .temperature ? nil : value.map { Int($0) }, systolic: nil, diastolic: nil,
                celsius: type == .temperature ? value : nil))
            guard let value else { return }
            switch type {
            case .heartRate: day.manualHeartRate = RingDay.merged(day.manualHeartRate, [RingTimedValue(minute: minute, value: value)])
            case .spo2: day.manualSpO2 = RingDay.merged(day.manualSpO2, [RingTimedValue(minute: minute, value: value)])
            case .temperature: day.instantTemperature = RingDay.merged(day.instantTemperature, [RingTimedValue(minute: minute, value: value)])
            default: break
            }
        }
    }

    // MARK: What a screen shows

    func card(_ type: RingMeasurementType, from screen: RingMeasureController.Host) -> RingCardMeasure? {
        guard manager.deviceID != nil, types.contains(type), !manager.workoutRunning else { return nil }
        return RingCardMeasure(state: state(of: type), enabled: !isBusy || isMeasuring(type),
                               start: { [weak self] in self?.start(type, from: screen) },
                               stop: { [weak self] in self?.stop() })
    }

    func state(of type: RingMeasurementType) -> RingCardMeasure.State {
        if let error, error.type == type { return .failed(error.text) }
        guard let m = session.measurement, m.type == type else { return .idle }
        if m.isActive { return .measuring(m.latest.map { text(type, $0) }) }
        if let result = m.result { return .result(text(type, result)) }
        if m.failed != nil { return .failed(type == .temperature ? "Put the ring on first" : "No reading — keep still") }
        return .idle
    }

    private func text(_ type: RingMeasurementType, _ value: Double) -> String {
        type == .temperature ? RingMeasureController.format(.temperature, celsius: value)
                             : RingMeasureController.format(type, value: Int(value.rounded()))
    }

    /// The last reading of a metric from the X5's own history.
    func lastReading(_ type: RingMeasurementType) -> (text: String, time: Date)? {
        guard let store = manager.store else { return nil }
        for daysAgo in 0..<7 {
            let day = store.day(RingDates.dayKey(RingDates.midnight(daysAgo: daysAgo)))
            if let record = day.measurements.last(where: { $0.type == type.name && $0.outcome == "done" }) {
                return (RingMeasureController.format(type, value: record.value, celsius: record.celsius), record.time)
            }
        }
        return nil
    }
}
