import Combine
import SwiftUI

/// On-demand readings from the ring, for whichever screen asked: the Health
/// tab's cards and the ring screen's Measure list share this one.
///
/// It starts and stops a reading, puts up "put the ring on" when the ring is
/// off a finger and takes it down the moment it goes on, and leaves a finished
/// reading on screen for a few seconds before letting it go.
@MainActor
final class RingMeasureController: ObservableObject {
    /// The screen that asked — the one that shows the wear sheet.
    enum Host { case ring, health }

    @Published private(set) var host: Host?
    @Published var wearPrompt: RingMeasurementType?
    /// Why the last reading could not start, and for which metric.
    @Published private(set) var error: (type: RingMeasurementType, text: String)?
    /// Bumped when a reading lands, so a screen can show it in its own data.
    @Published private(set) var finished = 0

    private unowned let manager: RingManager
    private var session: RingSession { manager.session }
    private var retry: Task<Void, Never>?
    private var fade: Task<Void, Never>?
    private var watching: Set<AnyCancellable> = []

    /// Longer than the ring has ever taken to say "not worn" (3–7 s).
    static let wornAfter: TimeInterval = 8
    /// How long a finished reading stays up.
    static let resultStays: Duration = .seconds(8)

    init(manager: RingManager) {
        self.manager = manager
        manager.session.$measurement
            .removeDuplicates { $0?.phase == $1?.phase && $0?.type == $1?.type && $0?.startedAt == $1?.startedAt }
            .sink { [weak self] state in self?.phaseChanged(state) }
            .store(in: &watching)
        // While a reading is on screen its live numbers are what matter: pass
        // the session's changes on then, and only then.
        manager.session.objectWillChange
            .sink { [weak self] in
                guard let self, self.session.measurement != nil else { return }
                self.objectWillChange.send()
            }
            .store(in: &watching)
    }

    // MARK: What can be measured

    /// What this ring measures on demand; a ring not yet asked gets the two every ring has.
    var types: [RingMeasurementType] {
        session.capabilities.isKnown ? session.capabilities.supportedMeasurements : [.heartRate, .spo2]
    }

    var isBusy: Bool { session.measurement?.isActive == true }

    func isMeasuring(_ type: RingMeasurementType) -> Bool {
        session.measurement?.type == type && isBusy
    }

    // MARK: Actions

    func start(_ type: RingMeasurementType, from host: Host) {
        error = nil
        self.host = host
        fade?.cancel()
        // The "put the ring on" hand, loaded off the main thread now so the
        // sheet never waits on it.
        Task.detached(priority: .utility) { _ = RingHandModel.bundled }
        Task {
            do {
                // The link drops whenever the ring is idle or on its charger;
                // bring it up on the way rather than leaving the button dead.
                if manager.state != .ready { _ = await manager.ensureConnected(timeout: 12) }
                try await session.startMeasurement(type)
            } catch {
                JcLog.devices.notice("ring: measure \(type.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.error = (type, "Couldn't reach the ring")
            }
        }
    }

    func stop() {
        closePrompt()
        session.cancelMeasurement()
    }

    /// A screen going away takes its sheet with it.
    func leave(_ screen: Host) {
        guard host == screen else { return }
        dismissPrompt()
        session.clearFinishedMeasurement()
    }

    // MARK: The wear sheet

    /// The sheet's binding for one screen: shown only where the reading was
    /// asked for (or on the ring screen, for a reading nobody on screen asked for).
    func prompt(on screen: Host) -> Binding<RingMeasurementType?> {
        Binding(
            get: { [weak self] in
                guard let self else { return nil }
                return self.shows(on: screen) ? self.wearPrompt : nil
            },
            set: { [weak self] value in
                // Swiped or tapped away rather than taken down by the ring going on.
                guard let self, value == nil, self.wearPrompt != nil, self.shows(on: screen) else { return }
                self.dismissPrompt()
            })
    }

    private func shows(on screen: Host) -> Bool {
        host == screen || (host == nil && screen == .ring)
    }

    /// "Not now", a swipe or a tap outside: the person has given up on this
    /// reading, so the attempt waiting behind the sheet stops too.
    func dismissPrompt() {
        let wasShowing = wearPrompt != nil
        closePrompt()
        if wasShowing, isBusy { session.cancelMeasurement() }
    }

    /// The ring is on: the sheet goes and the reading keeps running.
    private func closePrompt() {
        retry?.cancel()
        retry = nil
        wearPrompt = nil
    }

    private func phaseChanged(_ state: RingMeasurementState?) {
        guard let state else { return }
        switch state.phase {
        case .measuring:
            fade?.cancel()
        case .notWorn where wearPrompt == nil:
            // Only where a screen will show the sheet: a reading Jarvis took
            // with no screen open must not keep re-asking the ring unseen.
            guard host != nil || manager.screenIsOpen else { return fadeSoon() }
            showPrompt(for: state.type)
        case .done:
            closePrompt()
            finished += 1
            fadeSoon()
        case .failed, .cancelled, .timedOut, .notWorn:
            fadeSoon()
        }
    }

    /// Keep asking until the ring is on a finger, then take the sheet away and
    /// let the reading carry on underneath it.
    ///
    /// Off a finger the ring accepts a reading and then says "not worn" 3–7 s
    /// in. So an attempt that has run `wornAfter` without that is on a finger —
    /// the sheet goes then, rather than waiting ~17 s for the sensor to warm up
    /// and report skin (`skinContactAt`). Closing it never cancels the reading.
    private func showPrompt(for type: RingMeasurementType) {
        wearPrompt = type
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.wearPrompt != nil {
                if !self.isBusy {
                    // The ring is usually on its charger when this appears, so
                    // the link is down; bring it up before asking again.
                    if self.manager.state != .ready { _ = await self.manager.ensureConnected(timeout: 10) }
                    guard !Task.isCancelled, self.wearPrompt != nil else { return }
                    try? await self.session.startMeasurement(type)
                }

                let liveBefore = self.session.liveHeartRate?.date
                // Long enough for the ring to actually get there.
                for _ in 0..<150 {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, self.wearPrompt != nil else { return }

                    let state = self.session.measurement
                    let unrefused = state.map { $0.isActive && Date().timeIntervalSince($0.startedAt) >= Self.wornAfter } ?? false
                    let onFinger = unrefused || state?.skinContactAt != nil || (state?.value ?? 0) > 0
                        || state?.phase == .done
                    if onFinger || self.session.liveHeartRate?.date != liveBefore {
                        self.closePrompt()
                        return
                    }
                    // Charging, refused, or timed out: fall out and ask again.
                    if let phase = state?.phase, phase != .measuring { break }
                    if state == nil { break }
                    // The ring only reports skin contact in a reading's first
                    // 25 s; one that has gone past that without it will never
                    // see a finger that arrives now. Start a fresh one.
                    if let m = state, m.skinContactAt == nil, Date().timeIntervalSince(m.startedAt) > 30 {
                        self.session.cancelMeasurement()
                        break
                    }
                }
                // Straight back in: every second here is a second the sheet
                // stays up after the ring has gone on.
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Leave the result up long enough to read, then let it go.
    private func fadeSoon() {
        fade?.cancel()
        fade = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.resultStays)
            guard !Task.isCancelled, let self else { return }
            self.session.clearFinishedMeasurement()
            guard self.wearPrompt == nil else { return }
            self.host = nil
            // A link brought up just for this reading goes when it is done
            // (a no-op with Keep Alive on or the ring screen open).
            self.manager.releaseIfIdle()
        }
    }

    // MARK: What a screen shows

    /// A card's Measure control for this metric, or nil when the ring can't take it.
    func card(_ type: RingMeasurementType, from screen: Host) -> RingCardMeasure? {
        // A workout has the sensor; readings wait until it ends.
        guard manager.deviceID != nil, types.contains(type), !manager.workout.isActive else { return nil }
        return RingCardMeasure(state: state(of: type), enabled: !isBusy || isMeasuring(type),
                               start: { [weak self] in self?.start(type, from: screen) },
                               stop: { [weak self] in self?.stop() })
    }

    func state(of type: RingMeasurementType) -> RingCardMeasure.State {
        if let error, error.type == type { return .failed(error.text) }
        guard let m = session.measurement, m.type == type else { return .idle }
        switch m.phase {
        case .measuring: return .measuring(live(m))
        case .done: return live(m).map(RingCardMeasure.State.result) ?? .idle
        // Short enough for one line beside a button.
        case .notWorn: return .failed("Put the ring on first")
        case .timedOut: return .failed("No reading — keep still")
        case .failed: return .failed("Couldn't take a reading")
        case .cancelled: return .idle
        }
    }

    /// The newest number for a reading: the ring's own pushes while it works
    /// (only those that arrived since it started), and the result once it has one.
    func live(_ m: RingMeasurementState) -> String? {
        if m.type == .temperature, let celsius = m.celsius { return Self.format(.temperature, celsius: celsius) }
        if m.type == .bloodPressure, let sys = m.systolic, let dia = m.diastolic { return "\(sys)/\(dia)" }
        if let value = m.value, value > 0 { return Self.format(m.type, value: value) }
        guard m.isActive else { return nil }
        let fresh = { (reading: RingLiveReading?) in reading.flatMap { $0.date >= m.startedAt ? $0.value : nil } }
        switch m.type {
        case .heartRate: return fresh(session.liveHeartRate).map { Self.format(.heartRate, value: Int($0)) }
        case .spo2: return fresh(session.liveSpO2).map { Self.format(.spo2, value: Int($0)) }
        case .temperature: return fresh(session.liveTemperature).map { Self.format(.temperature, celsius: $0) }
        default: return nil
        }
    }

    /// A reading as its card writes it.
    static func format(_ type: RingMeasurementType, value: Int? = nil, celsius: Double? = nil,
                       systolic: Int? = nil, diastolic: Int? = nil) -> String {
        switch type {
        case .heartRate: return "\(value ?? 0) bpm"
        case .spo2: return "\(value ?? 0)%"
        case .hrv: return "\(value ?? 0) ms"
        case .stress: return "\(value ?? 0) · \(StressBand.of(Double(value ?? 0)).label)"
        case .temperature: return celsius.map(TemperatureUnit.current.format) ?? "—"
        case .bloodPressure: return "\(systolic ?? 0)/\(diastolic ?? 0) mmHg"
        case .healthCheck, .bloodSugar: return "\(value ?? 0)"
        }
    }

    /// The last reading this ring took of a metric, from its own history.
    func lastReading(_ type: RingMeasurementType) -> (text: String, time: Date)? {
        guard let store = manager.store else { return nil }
        for daysAgo in 0..<7 {
            let day = store.day(RingDates.dayKey(RingDates.midnight(daysAgo: daysAgo)))
            if let record = day.measurements.last(where: { $0.type == type.name && $0.outcome == "done" }) {
                return (Self.format(type, value: record.value, celsius: record.celsius,
                                    systolic: record.systolic, diastolic: record.diastolic), record.time)
            }
        }
        return nil
    }
}

extension View {
    /// "Put the ring on", as a bottom sheet on the screen that asked for the
    /// reading: swipe it away, tap outside it or use the button — and it
    /// leaves by itself the moment the ring is on a finger.
    func ringWearSheet(_ measure: RingMeasureController, on screen: RingMeasureController.Host) -> some View {
        sheet(item: measure.prompt(on: screen)) { type in
            RingWearPrompt(metric: type.label) { measure.dismissPrompt() }
                .presentationDetents([.height(430)])
                .presentationDragIndicator(.hidden)
                .presentationBackground(RingWearPrompt.sheetBackground)
                .presentationCornerRadius(34)
        }
    }
}

/// A card's on-demand reading: its Measure button, and — while it runs and for
/// a moment after — the number the ring is sending.
struct RingCardMeasure {
    enum State: Equatable {
        case idle
        /// Running; the newest number, nil until the sensor has one.
        case measuring(String?)
        /// Just finished with this.
        case result(String)
        case failed(String)
    }

    var state: State
    var enabled = true
    let start: () -> Void
    let stop: () -> Void
}
