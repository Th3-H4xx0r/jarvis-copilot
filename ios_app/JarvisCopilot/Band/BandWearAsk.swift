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
            && (r.heartRate != nil || r.spo2 != nil || r.systolic != nil || r.temperatureC != nil || r.stress != nil)
    }

    /// Takes the reading, asking for the band for as long as it says it isn't worn. Throws what
    /// the band said when it refused for any other reason.
    func measure(_ type: BandMeasure) async throws {
        attempt?.cancel()
        let task = Task { try await self.askUntilWorn(type) }
        attempt = task
        try await task.value
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
                throw error
            }
            closer?.cancel()
            guard !Task.isCancelled else { return }
            guard reading.notWorn else { prompt = nil; return }
            prompt = type
            try? await Task.sleep(for: .seconds(retryAfter))
            guard !Task.isCancelled, prompt == type else { return }
        }
    }
}

extension BandMeasure: Identifiable {
    var id: String { rawValue }

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
