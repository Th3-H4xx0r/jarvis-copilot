import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The band's ECG: its diagnosis decoded the way the Android SDK does, its findings, and the
/// report and live screens (written to /tmp/ringshots to be looked at).
@MainActor
final class BandEcgTests: XCTestCase {
    private static func bytes(_ hex: String) -> [UInt8] {
        let chars = Array(hex)
        return stride(from: 0, to: chars.count - 1, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! }
    }

    /// The real result the E910 sent: five type-5 parts, 14 bytes each from byte 6.
    static let realParts = ["930101050105000000000000000000490f309001", "9301010502050000000000000000000000000000",
                            "9301010503050000000000000000000000000000", "9301010504050000000000000000000000000000",
                            "9301010505050000000000000000000000000000"]

    func testTheRealDiagnosisDecodes() throws {
        let data = Self.realParts.flatMap { Array(Self.bytes($0)[6..<20]) }
        let d = try XCTUnwrap(BandEcgDiagnosis(data))
        XCTAssertEqual(d.heartRate, 73)
        XCTAssertEqual(d.respiratoryRate, 15)
        XCTAssertEqual(d.hrv, 48)
        XCTAssertEqual(d.qtcMs, 400, "QT is little-endian at bytes 12–13")
        XCTAssertTrue(d.findings.isEmpty)
        XCTAssertEqual(d.rhythm, "Sinus rhythm")
    }

    func testFindingsReadTheDiagnosisBytesTwoBitsAtATime() throws {
        var data = [UInt8](repeating: 0, count: 70)
        data[1] = 0b0010_0000      // byte 0, slot 1: id 12 at grade 2
        data[2] = 0b0000_0011      // byte 1, slot 3: id 24 — not a single-lead finding, ignored
        data[9] = 58
        let d = try XCTUnwrap(BandEcgDiagnosis(data))
        XCTAssertEqual(d.findings, [BandEcgFinding(id: 12, grade: 2)])
        XCTAssertEqual(d.rhythm, "Sinus bradycardia")
        XCTAssertEqual(d.allFindings.count, BandEcgFinding.names.count)
    }

    func testTheSdkWaveformFrameUnpacksFiveSignedSamples() {
        // 0x000100 = 256, 0xFFFF00 = -256 (top bits 7: negative).
        let frame = Self.bytes("88000100ffff00000000000000000000000000")
        let samples = BandEcgSignal.samples(frame + [0])
        XCTAssertEqual(Array(samples.prefix(2)), [256, -256])
        XCTAssertEqual(samples.count, 5)
    }

    // MARK: Renders

    /// A clean synthetic lead I: a P wave, the QRS, a T wave, at 75 bpm.
    private static func trace(seconds: Double, rate: Int) -> [Int] {
        (0..<Int(seconds * Double(rate))).map { i in
            let t = Double(i) / Double(rate)
            let beat = t.truncatingRemainder(dividingBy: 0.8)
            func bump(_ at: Double, _ width: Double, _ height: Double) -> Double {
                height * exp(-pow((beat - at) / width, 2))
            }
            let v = bump(0.16, 0.025, 120) + bump(0.30, 0.008, -150) + bump(0.32, 0.01, 1100)
                + bump(0.34, 0.009, -260) + bump(0.55, 0.05, 260) + 40 * sin(t * 0.7)
            return Int(v)
        }
    }

    private static var report: BandEcgReport {
        var data = [UInt8](repeating: 0, count: 70)
        data[1] = 0b0001_0000
        data[9] = 79; data[10] = 16; data[11] = 35
        data[12] = 0x5D; data[13] = 0x01                      // QTc 349
        data[14] = 2; data[15] = 18; data[16] = 15; data[17] = 1; data[18] = 3; data[19] = 3
        data[52] = 72; data[54] = 0x90; data[55] = 0x01        // QRS 72 ms, 0.4 mV
        data[58] = 20                                          // ST 0.02 mV
        data[60] = 131; data[64] = 220                         // SDNN, RMSSD
        return BandEcgReport(date: Date(timeIntervalSince1970: 1_791_200_933), diagnosis: BandEcgDiagnosis(data),
                             heartRates: [78, 79, 80, 83, 79, 78], samples: trace(seconds: 30, rate: 250), sampleRate: 250)
    }

    func testTheReportRenders() throws {
        try RenderHarness.write(NavigationStack { BandEcgReportView(report: Self.report) }.environment(AppRouter()),
                                size: CGSize(width: 402, height: 1500), name: "band-ecg-report", settle: 2)
    }

    func testTheAnalysisRenders() throws {
        let view = NavigationStack { BandEcgReportView(report: Self.report, initialTab: 1) }
        try RenderHarness.write(view.environment(AppRouter()), size: CGSize(width: 402, height: 2300),
                                name: "band-ecg-analysis", settle: 2)
    }

    func testTheLiveScreenRenders() throws {
        let session = BandSession()
        session.seedEcgForTests(samples: Self.trace(seconds: 6, rate: 250), heartRates: [78])
        try RenderHarness.write(BandEcgLiveView(session: session) {}, size: CGSize(width: 402, height: 874),
                                name: "band-ecg-live", settle: 1.5)
    }
}
