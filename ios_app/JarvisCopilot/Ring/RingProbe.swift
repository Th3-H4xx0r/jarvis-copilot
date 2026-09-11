import Foundation

/// Something the ring either answers or doesn't, found by asking rather than by trusting its
/// feature flags: this firmware under-reports (an R12 advertises no temperature and no new
/// sleep protocol, yet answers both).
enum RingFeature: String, CaseIterable, Codable, Identifiable {
    case stepSlots = "step_slots"
    case sleep
    case heartRateSeries = "heart_rate_series"
    case manualHeartRate = "manual_heart_rate"
    case spo2
    case manualSpO2 = "manual_spo2"
    case hrv
    case stress
    case temperature
    case bloodPressure = "blood_pressure"
    case bloodSugar = "blood_sugar"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stepSlots: return "Step detail"
        case .sleep: return "Sleep stages"
        case .heartRateSeries: return "Heart-rate history"
        case .manualHeartRate: return "Manual heart-rate readings"
        case .spo2: return "Blood oxygen history"
        case .manualSpO2: return "Manual blood-oxygen readings"
        case .hrv: return "HRV history"
        case .stress: return "Stress history"
        case .temperature: return "Temperature history"
        case .bloodPressure: return "Blood pressure"
        case .bloodSugar: return "Blood sugar"
        }
    }

    /// The metric this feeds, so sync can ask "does this ring do it?".
    var metric: RingMetric? {
        switch self {
        case .stepSlots: return .activity
        case .sleep: return .sleep
        case .heartRateSeries, .manualHeartRate: return .heartRate
        case .spo2, .manualSpO2: return .spo2
        case .hrv: return .hrv
        case .stress: return .stress
        case .temperature: return .temperature
        case .bloodPressure: return .bloodPressure
        case .bloodSugar: return .bloodSugar
        }
    }

    /// What to send to find out.
    var request: RingRequest {
        switch self {
        case .stepSlots: return .stepDetail(dayOffset: 0)
        case .sleep: return .bigSleep(all: false)
        case .heartRateSeries: return .bigIntervalHeartRate(dayOffset: 0, packet: 0)
        case .manualHeartRate: return .bigManualHeartRate(all: false)
        case .spo2: return .bigSpO2
        case .manualSpO2: return .bigManualSpO2(all: false)
        case .hrv: return .hrvHistory(dayOffset: 0)
        case .stress: return .stressHistory(dayOffset: 0)
        case .temperature: return .bigIntervalTemperature(dayOffset: 0, packet: 0)
        case .bloodPressure: return .bloodPressureHistory
        case .bloodSugar: return .bigBloodSugar
        }
    }

    /// Large-data replies have no end marker; command replies are a single frame.
    var until: RingUntil {
        request.channel == .bigData ? .idle : .single
    }
}

/// What the ring answered when asked, kept with the rest of its cached state.
struct RingProbe: Codable, Equatable {
    private(set) var answered: [String: Bool] = [:]
    var firmware: String?
    var checkedAt: Date?

    var isEmpty: Bool { answered.isEmpty }

    /// True, false, or nil when it hasn't been asked.
    func works(_ feature: RingFeature) -> Bool? { answered[feature.rawValue] }

    /// A metric works when any of the features behind it answered.
    func supports(_ metric: RingMetric) -> Bool? {
        let results = RingFeature.allCases.filter { $0.metric == metric }.compactMap { answered[$0.rawValue] }
        return results.isEmpty ? nil : results.contains(true)
    }

    mutating func record(_ feature: RingFeature, works: Bool) {
        answered[feature.rawValue] = works
    }

    /// Worth running again when the firmware changed, or nothing has been asked yet.
    func isStale(firmware: String?) -> Bool {
        isEmpty || self.firmware != firmware
    }
}
