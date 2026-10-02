import CoreLocation
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Renders the dashcam screens to /tmp/ringshots to look at before installing.
@MainActor
final class DashcamRenderTests: XCTestCase {
    private func clip(_ id: String, kind: String, lens: String = "front", minutesAgo: Double, extra: [String: Any]) -> DashcamServerClip {
        var json: [String: Any] = ["id": id, "path": "/mnt/card/x/\(id).mp4", "kind": kind, "lens": lens,
                                   "start": Date().addingTimeInterval(-minutesAgo * 60).dashcamISO, "duration_s": 60,
                                   "size": 150_000_000, "on_camera": true]
        extra.forEach { json[$0.key] = $0.value }
        return DashcamServerClip(json: json)!
    }

    func testRenderCards() throws {
        let setup = DashcamSetup(ssid: "Affver_A4_9F2C", family: .viidure, cameraID: "X", model: "A4", brand: "Affver")
        let view = VStack(spacing: 14) {
            DashcamCard(setup: nil, onCamera: false, phase: .notSetUp, lastSync: nil, pendingUploads: 0)
            DashcamCard(setup: setup, onCamera: true, phase: .syncing("Reading GPS"), lastSync: Date(), pendingUploads: 3)
            DashcamCard(setup: setup, onCamera: false, phase: .away, lastSync: Date().addingTimeInterval(-5400), pendingUploads: 0)
        }
        .padding(16)
        try RenderHarness.write(view, size: CGSize(width: 393, height: 640), name: "dashcam_cards")
    }

    func testRenderLibraryRows() throws {
        let clips = [
            clip("a", kind: "event", minutesAgo: 5, extra: ["phone": ["state": "local"], "upload": ["state": "staged"],
                                                             "destinations": ["d": ["state": "uploading"]]]),
            clip("b", kind: "normal", minutesAgo: 9, extra: ["destinations": ["d": ["state": "done"]], "uploaded": true]),
            clip("c", kind: "photo", minutesAgo: 12, extra: ["phone": ["state": "local"]]),
            clip("d", kind: "parking", lens: "rear", minutesAgo: 70, extra: ["destinations": ["d": ["state": "failed", "error": "permission denied"]]]),
            clip("e", kind: "normal", lens: "rear", minutesAgo: 80, extra: [:]),
        ]
        let view = ScrollView {
            CardGroup("Today") {
                ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { RowDivider() }
                    Row(minHeight: 64) { DashcamClipRow(clip: c, uploadingID: nil) }
                }
            }
            .padding(.vertical, 16)
        }
        try RenderHarness.write(view, size: CGSize(width: 393, height: 560), name: "dashcam_library")
    }

    func testRenderSetup() throws {
        try RenderHarness.write(NavigationStack { DashcamSetupView() }, size: CGSize(width: 393, height: 760), name: "dashcam_setup")
    }

    func testRenderSpeedColouredDrive() throws {
        // A loop through the Loop with speeds from a crawl to highway speed.
        let n = 240
        let points = (0..<n).map { i -> RoutePoint in
            let a = Double(i) / Double(n) * 2 * .pi
            let mps = 2 + 30 * (0.5 + 0.5 * sin(a * 3))
            return RoutePoint(t: Double(i), lat: 41.8781 + 0.02 * sin(a), lon: -87.6298 + 0.03 * cos(a), speed: mps)
        }
        let view = VStack(spacing: 12) {
            RouteMapView(segments: [points], revision: 1, style: .standard,
                         colors: [points.map { DashcamSpeed.color($0.speed) }],
                         scrub: CLLocationCoordinate2D(latitude: points[60].lat, longitude: points[60].lon))
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            HStack(spacing: 4) {
                ForEach([0.0, 10, 20, 30, 40], id: \.self) { mps in
                    RoundedRectangle(cornerRadius: 4).fill(Color(DashcamSpeed.color(mps))).frame(height: 14)
                        .overlay(Text("\(DashcamSpeed.text(mps))").font(.caption2).foregroundStyle(.black))
                }
            }
        }
        .padding(16)
        try RenderHarness.write(view, size: CGSize(width: 393, height: 380), name: "dashcam_drive_map", settle: 5)
    }
}
