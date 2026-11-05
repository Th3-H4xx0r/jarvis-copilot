import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Draws the dashcam sync Live Activity (Lock Screen, Dynamic Island) for
/// downloading + uploading, uploading only and the last clip, so they're looked
/// at before they reach a phone. PNGs go to `RING_SNAPSHOT_DIR`.
@MainActor
final class DashcamSyncActivityRenderTests: XCTestCase {

    typealias CS = DashcamSyncAttributes.ContentState

    private let camera = "HUAXIN A4"

    private var samples: [CS] {
        let stamp = Date().addingTimeInterval(-1260).formatted(.verbatim(
            "\(year: .defaultDigits)_\(month: .twoDigits)_\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))_\(minute: .twoDigits)_\(second: .twoDigits)",
            timeZone: .current, calendar: .current))
        return [
            CS(downloadName: "\(stamp)_b.ts", downloadFraction: 0.26, toDownload: 77,
               uploading: true, uploadFraction: 0.65, toUpload: 155),
            CS(uploading: true, uploadFraction: 0.63, toUpload: 155),
            CS(downloadName: "\(stamp)_f.ts", downloadFraction: 0.01, toDownload: 12),
            CS(uploading: true, uploadFraction: 1, toUpload: 1),
        ]
    }

    func testRenderTheLockScreen() throws {
        let samples = self.samples
        let camera = self.camera
        let view = VStack(spacing: 10) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                DashcamLockScreenView(cameraName: camera, state: s)
                    .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.82)))
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.4), .black],
                                   startPoint: .top, endPoint: .bottom))
        try RenderHarness.write(view, size: CGSize(width: 390, height: 720), name: "dashcam-la-lockscreen")
    }

    func testRenderTheDynamicIsland() throws {
        let samples = self.samples
        let camera = self.camera
        let view = VStack(spacing: 14) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 18) {
                    HStack(spacing: 0) {
                        DashcamCompactLeading(state: s)
                        Spacer()
                        DashcamCompactTrailing(state: s)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 236, height: 37)
                    .background(Capsule().fill(.black))
                    DashcamCompactLeading(state: s)
                        .frame(width: 37, height: 37)
                        .background(Circle().fill(.black))
                }
            }
            ForEach([0, 1, 3], id: \.self) { i in
                let s = samples[i]
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        DashcamIslandLeading(cameraName: camera)
                        Spacer(minLength: 0)
                        Capsule().fill(Color(white: 0.12)).frame(width: 90, height: 30)   // the camera
                        Spacer(minLength: 0)
                        DashcamIslandTrailing(state: s)
                    }
                    DashcamIslandBottom(state: s)
                }
                .padding(14)
                .frame(width: 370)
                .background(RoundedRectangle(cornerRadius: 44).fill(.black))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.85))
        try RenderHarness.write(view, size: CGSize(width: 390, height: 900), name: "dashcam-la-island")
    }

    /// iOS cuts a Lock Screen activity off at 160 pt: every state must fit.
    func testEveryLockScreenStateFitsUnderTheCap() {
        for s in samples {
            let host = UIHostingController(rootView: DashcamLockScreenView(cameraName: camera, state: s))
            let size = host.sizeThatFits(in: CGSize(width: 350, height: 1000))
            XCTAssertLessThanOrEqual(size.height, 158, "\(s): \(size.height) pt")
        }
    }

    func testClipNamesReadAsTheSideAndTime() {
        let now = DateComponents(calendar: .current, year: 2025, month: 10, day: 25, hour: 23, minute: 40).date!
        let today = DashcamClipLabel.text("2025_10_25_23_19_20_b.ts", now: now)
        XCTAssertTrue(today.hasPrefix("Rear · ") && today.contains("19"), today)
        XCTAssertEqual(DashcamClipLabel.text("2025_10_20_08_02_11_f.ts", now: now), "Front · Oct 20")
        XCTAssertEqual(DashcamClipLabel.text("2025_10_20_08_02_11.ts", now: now), "Oct 20")
        XCTAssertEqual(DashcamClipLabel.text("MOVI0042.MP4", now: now), "MOVI0042")
    }

    func testClipsToGoCountsTheCameraAndTheQueue() {
        XCTAssertEqual(samples[0].clipsToGo, 232)
        XCTAssertEqual(samples[1].clipsToGo, 155)
        XCTAssertEqual(samples[3].clipsToGo, 1)
        XCTAssertEqual(DashcamLane.lanes(samples[0]).map(\.percent), ["26%", "65%"])
        XCTAssertEqual(DashcamLane.lanes(samples[3]).first?.detail, "")
    }
}
