import Combine
import SwiftUI

/// "Put the band on", for readings from the band's page. A reading the band answers "not worn"
/// puts up the sheet, and is tried again until the band is on a wrist — then the sheet goes and
/// that reading carries on underneath. A reading Jarvis takes with no screen open just reports
/// `not_worn`.
@MainActor
final class BandWearAsk: ObservableObject {
    /// The reading waiting for the band, while the sheet is up.
    @Published var prompt: BandMeasure?
    /// The reading that just ended, shown for a few seconds as the ring's rows do.
    @Published private(set) var recent: BandReading?
    private var fade: Task<Void, Never>?

    private let session: BandSession
    private var attempt: Task<Void, Error>?
    private var watching: AnyCancellable?

    /// A try that runs this long without "not worn" has found a wrist: the band answers within
    /// a few seconds when it is off.
    var wornAfter: TimeInterval = 8
    /// Between tries while the band is off.
    var retryAfter: TimeInterval = 1.5

    init(session: BandSession) {
        self.session = session
        // A number from the sensor means the band is on: the sheet goes, the reading runs on.
        watching = session.$lastReading.sink { [weak self] reading in
            guard let self, let reading, reading.measure == self.prompt, Self.sensed(reading) else { return }
            self.prompt = nil
        }
    }

    /// A reading with a number in it, not a refusal.
    static func sensed(_ r: BandReading) -> Bool {
        !r.notWorn && !r.busy
            && (r.heartRate != nil || r.spo2 != nil || r.systolic != nil || r.temperatureC != nil || r.stress != nil
                || r.bloodGlucose != nil || r.bloodComponent != nil || r.bodyComposition != nil || r.hrv != nil)
    }

    /// Takes the reading, asking for the band for as long as it says it isn't worn. Throws what
    /// the band said when it refused for any other reason.
    func measure(_ type: BandMeasure) async throws {
        attempt?.cancel()
        let task = Task { try await self.askUntilWorn(type) }
        attempt = task
        try await task.value
    }

    private func show(_ reading: BandReading) {
        recent = reading
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.recent = nil
        }
    }

    /// One measure-list row's state: the live value while it runs, the result for a moment
    /// after, else idle.
    func state(of type: BandMeasure) -> RingCardMeasure.State {
        if session.measuring == type {
            guard let now = session.lastReading, now.measure == type else { return .measuring(nil) }
            if let text = now.valueText { return .measuring(text) }
            return .measuring(now.progress.flatMap { $0 > 0 ? "\($0)%" : nil })
        }
        if let recent, recent.measure == type {
            if recent.finished, let text = recent.valueText { return .result(text) }
            return .failed(recent.failure ?? (recent.notWorn ? BandReading.Reason.notWorn : BandReading.Reason.noReading))
        }
        return .idle
    }

    /// "Not now", a swipe or a tap outside: stop asking, and stop the try in flight.
    func dismiss() {
        prompt = nil
        attempt?.cancel()
        attempt = nil
    }

    /// The sheet's binding: going away by hand is "Not now".
    var sheet: Binding<BandMeasure?> {
        Binding(get: { [weak self] in self?.prompt },
                set: { [weak self] value in if value == nil, self?.prompt != nil { self?.dismiss() } })
    }

    private func askUntilWorn(_ type: BandMeasure) async throws {
        while !Task.isCancelled {
            // While the sheet is up, a try that runs long enough without "not worn" is on a wrist.
            let wornAfter = self.wornAfter
            let closer: Task<Void, Never>? = prompt == nil ? nil : Task { [weak self] in
                try? await Task.sleep(for: .seconds(wornAfter))
                guard !Task.isCancelled, let self, self.session.measuring == type else { return }
                self.prompt = nil
            }
            let reading: BandReading
            do {
                reading = try await session.measure(type)
            } catch {
                closer?.cancel()
                if Task.isCancelled { return }
                prompt = nil
                if let ended = session.lastReading, ended.measure == type, ended.ended { show(ended) }
                throw error
            }
            closer?.cancel()
            guard !Task.isCancelled else { return }
            guard reading.notWorn else { prompt = nil; show(reading); return }
            prompt = type
            try? await Task.sleep(for: .seconds(retryAfter))
            guard !Task.isCancelled, prompt == type else { return }
        }
    }
}

extension BandMeasure: Identifiable {
    var id: String { rawValue }

    /// The ring's symbols and colours where they share a reading.
    var icon: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .bloodPressure: return "drop.fill"
        case .bloodOxygen: return "lungs.fill"
        case .temperature: return "thermometer.medium"
        case .stress: return "brain.head.profile"
        case .bloodGlucose: return "drop.triangle.fill"
        case .bloodComponent: return "testtube.2"
        case .bodyComposition: return "figure.arms.open"
        case .ecg: return "waveform.path.ecg"
        }
    }

    var tint: Color {
        switch self {
        case .heartRate: return Color(red: 1, green: 0.35, blue: 0.4)
        case .bloodPressure: return .pink
        case .bloodOxygen: return JcTheme.accent
        case .temperature: return .orange
        case .stress: return JcTheme.amber
        case .bloodGlucose: return .teal
        case .bloodComponent: return .purple
        case .bodyComposition: return .mint
        case .ecg: return JcTheme.blue
        }
    }

    /// The name people see.
    var label: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .bloodPressure: return "Blood pressure"
        case .bloodOxygen: return "Blood oxygen"
        case .temperature: return "Temperature"
        case .stress: return "Stress"
        case .bloodGlucose: return "Blood glucose"
        case .bloodComponent: return "Blood components"
        case .bodyComposition: return "Body composition"
        case .ecg: return "ECG"
        }
    }
}

extension View {
    /// "Put the band on", as a bottom sheet on the band's page — the ring's sheet, with the band.
    func bandWearSheet(_ ask: BandWearAsk) -> some View {
        sheet(item: ask.sheet) { type in
            RingWearPrompt(metric: type.label, kind: .band) { ask.dismiss() }
                .presentationDetents([.height(430)])
                .presentationDragIndicator(.hidden)
                .presentationBackground(RingWearPrompt.sheetBackground)
                .presentationCornerRadius(34)
        }
    }
}

extension BandReading {
    /// The value, in the user's units: "72 bpm", "118/76 mmHg", "5.6 mmol/L"… nil without one.
    var valueText: String? {
        if let s = systolic, let d = diastolic { return "\(s)/\(d) mmHg" }
        if let g = bloodGlucose { return GlucoseUnit.current.format(g) }
        if let c = bloodComponent { return "Uric acid " + UricAcidUnit.current.format(c.uricAcid) }
        if let b = bodyComposition { return String(format: "BMI %.1f · %.0f%% fat", b.bmi, b.bodyFatPercent) }
        if let t = temperatureC { return TemperatureUnit.current.format(t) }
        if let o = spo2 { return "\(o)%" }
        if let v = stress { return "\(v)" }
        if let hr = heartRate { return "\(hr) bpm" }
        return nil
    }
}

extension RingMeasurementRecord {
    /// A kept band reading's value, in the user's units (as `BandReading.valueText`).
    var bandText: String? {
        guard outcome == "done" else { return nil }
        if let s = systolic, let d = diastolic { return "\(s)/\(d) mmHg" }
        if let g = extra?["blood_glucose_mmol_l"] { return GlucoseUnit.current.format(g) }
        if let u = extra?["uric_acid_umol_l"] { return "Uric acid " + UricAcidUnit.current.format(u) }
        if let bmi = extra?["bmi"] {
            return String(format: "BMI %.1f · %.0f%% fat", bmi, extra?["body_fat_percent"] ?? 0)
        }
        if let c = celsius { return TemperatureUnit.current.format(c) }
        guard let value else { return nil }
        switch type {
        case BandMeasure.bloodOxygen.name: return "\(value)%"
        case BandMeasure.stress.name: return "\(value)"
        default: return "\(value) bpm"
        }
    }
}

extension RingHistoryStore {
    /// The newest kept band reading of `type`, from the last week.
    func lastBandReading(_ type: BandMeasure) -> (text: String, time: Date)? {
        for daysAgo in 0..<7 {
            let day = self.day(RingDates.dayKey(RingDates.midnight(daysAgo: daysAgo)))
            if let r = day.measurements.last(where: { $0.type == type.name && $0.outcome == "done" }), let text = r.bandText {
                return (text, r.time)
            }
        }
        return nil
    }
}
