import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Weight on the Health tab: the wire shape, what the phone sends, and the card.
@MainActor
final class WeightTests: XCTestCase {
    func testTodayCarriesTheLatestWeighIn() throws {
        let json = """
        {"start":"2026-09-17T04:30:00Z","end":"2026-09-17T20:00:00Z","minutes":930,"no_wake":false,"day":null,
         "battery":{"level":84.0,"band":"High","curve":[]},
         "weight":{"latest":{"id":"b","at":"2026-09-17T12:05:00Z","weight_kg":72.4,"bmi":22.3,"body_fat":18.1,"device":"scale-3c0f01eb"},
                   "recent":[{"id":"a","at":"2026-09-10T12:00:00Z","weight_kg":73.0},
                             {"id":"b","at":"2026-09-17T12:05:00Z","weight_kg":72.4,"body_fat":18.1}]}}
        """
        let now = try HealthClient.decodeForTests(HealthNow.self, json: json)
        XCTAssertEqual(now.weight?.latest?.weightKg, 72.4)
        XCTAssertEqual(now.weight?.latest?.bodyFat, 18.1)
        XCTAssertEqual(now.weight?.recent.count, 2)
    }

    func testANowWithoutWeightStillDecodes() throws {
        let json = #"{"start":"2026-09-17T04:30:00Z","end":"2026-09-17T20:00:00Z","minutes":1,"no_wake":true,"day":null,"battery":{"level":50,"band":"Medium","curve":[]}}"#
        XCTAssertNil(try HealthClient.decodeForTests(HealthNow.self, json: json).weight)
    }

    func testAWeighInIsSentInTheServersShape() {
        let reading = ScaleReading(date: Date(timeIntervalSince1970: 1_800_000_000), profileID: nil, model: "ESF551",
                                   deviceID: "3C0F", weightKg: 72.4, impedance: 510,
                                   metrics: [.weight: 72.4, .bmi: 22.3, .bodyFat: 18.1, .muscleMass: 55.2], scaleUnit: .kilograms)
        let body = ScaleUploader.payload(reading)
        XCTAssertEqual(body["id"] as? String, reading.id.uuidString.lowercased())
        XCTAssertEqual(body["at"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(body["weight_kg"] as? Double, 72.4)
        XCTAssertEqual(body["body_fat"] as? Double, 18.1)
        XCTAssertEqual(body["muscle_mass"] as? Double, 55.2)
        XCTAssertNil(body["impedance"], "raw impedance stays on the phone")
    }

    func testWeightFormatsInTheChosenUnit() {
        TrainingUnit.current = .lb
        defer { TrainingUnit.current = .kg }
        XCTAssertEqual(HealthFormat.string(72.4, kind: "kg"), "159.6 lb")
        XCTAssertEqual(HealthFormat.string(-0.5, kind: "kg_change"), "−1.1 lb")
        TrainingUnit.current = .kg
        XCTAssertEqual(HealthFormat.string(0.4, kind: "kg_change"), "+0.4 kg")
    }

    private func weight() -> HealthWeight {
        let now = Date()
        var recent: [HealthWeightReading] = []
        for day in stride(from: 34, through: 0, by: -1) where day % 2 == 0 || day < 3 {
            let kg = 74.0 - Double(34 - day) * 0.05 + (day % 3 == 0 ? 0.2 : 0)
            recent.append(HealthWeightReading(id: "\(day)", at: now.addingTimeInterval(-Double(day) * 86_400 - 3600),
                                              weightKg: kg, bmi: 22.4, bodyFat: 18.2))
        }
        return HealthWeight(latest: recent.last, recent: recent)
    }

    func testTheWeightCard() throws {
        TrainingUnit.current = .kg
        try RenderHarness.write(ScrollView { WeightCard(weight: weight(), showAll: {}).padding(.top, 20) },
                                size: CGSize(width: 402, height: 420), name: "weight-card")
        try RenderHarness.write(ScrollView { WeightCard(weight: nil).padding(.top, 20) },
                                size: CGSize(width: 402, height: 260), name: "weight-card-empty")
    }
}
