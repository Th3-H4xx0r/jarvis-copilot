import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The band's measure sheet in its states — measuring, a Private result, a phone-calibrated
/// result, a failure — written to /tmp/ringshots to be looked at before it reaches a phone.
@MainActor
final class BandMeasureSheetRenderTests: XCTestCase {
    private let size = CGSize(width: 402, height: BandMeasureSheet.height)

    private func render(_ name: String, _ type: BandMeasure, mode: BandMeasureMode,
                        running: Bool = false, result: BandReading? = nil, failure: String? = nil) throws {
        let flow = BandMeasureFlow(session: BandSession(), ask: BandWearAsk(session: BandSession()))
        flow.pin(type: type, mode: mode, running: running, result: result, failure: failure)
        try RenderHarness.write(BandMeasureSheet(type: type, flow: flow, session: flow.session) {},
                                size: size, name: name)
    }

    func testTheSheetsStates() throws {
        try render("band-measure-running", .bloodPressure, mode: .private, running: true)
        var bp = BandReading(measure: .bloodPressure, date: Date(), status: .done)
        bp.systolic = 118
        bp.diastolic = 77
        try render("band-measure-bp-result", .bloodPressure, mode: .private, result: bp)
        var hr = BandReading(measure: .heartRate, date: Date(), status: .done)
        hr.heartRate = 68
        try render("band-measure-hr-result", .heartRate, mode: .general, result: hr)
        try render("band-measure-failed", .bloodOxygen, mode: .general, failure: BandReading.Reason.noReading)
    }
}
