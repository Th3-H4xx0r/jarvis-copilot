import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The glasses' card and page, drawn before they reach a phone (written to /tmp/ringshots).
@MainActor
final class GlassesScreenRenderTests: XCTestCase {

    private let go3 = GlassesAudioPort(name: "INMO GO3", uid: "AA:BB:CC:DD:EE:FF-tacl", isBluetooth: true)

    /// Connected with the reply on the glasses, never paired, and paired but out of range.
    func testTheCards() throws {
        let cards = VStack(spacing: 14) {
            GlassesCard(route: GlassesRouteState(glasses: go3, speakers: true, microphone: true),
                        lastSeen: Date())
            GlassesCard(route: .none, lastSeen: nil)
            GlassesCard(route: .none, lastSeen: Date().addingTimeInterval(-3 * 3600))
        }
        .padding(16)
        try RenderHarness.write(cards, size: CGSize(width: 402, height: 640), name: "glasses-cards")
    }

    /// The page as it first opens tomorrow: nothing on the route yet.
    func testThePage() throws {
        try RenderHarness.write(NavigationStack { InmoGo3View() }, size: CGSize(width: 402, height: 2300),
                                name: "glasses-page")
    }
    /// Every page behind the main page's rows.
    func testTheSubpages() throws {
        let pages: [(String, AnyView, CGFloat)] = [
            ("glasses-display", AnyView(GlassesDisplaySoundPage()), 900),
            ("glasses-controls", AnyView(GlassesControlsPage()), 1000),
            ("glasses-talking", AnyView(GlassesTalkingPage()), 700),
            ("glasses-notifications", AnyView(GlassesNotificationsPage()), 600),
            ("glasses-teleprompter", AnyView(GlassesTeleprompterPage()), 1100),
            ("glasses-about", AnyView(GlassesAboutPage()), 1300),
            ("glasses-advanced", AnyView(GlassesAdvancedPage()), 1500),
            ("glasses-owner", AnyView(GlassesOwnerSetupPage()), 600),
            ("glasses-setup", AnyView(GlassesSetupPage()), 600),
        ]
        for (name, page, height) in pages {
            try RenderHarness.write(NavigationStack { page }, size: CGSize(width: 402, height: height), name: name, settle: 1.2)
        }
    }

    func testOneConnectedRuleForCardAndPage() {
        XCTAssertEqual(GlassesConnectionStatus.of(control: .ready, audio: false), .connected)
        XCTAssertEqual(GlassesConnectionStatus.of(control: .ready, audio: true), .connected)
        for state in [InmoConnectionState.discovering, .connecting, .discoveringServices, .subscribing, .authenticating] {
            XCTAssertEqual(GlassesConnectionStatus.of(control: state, audio: true), .connecting)
        }
        XCTAssertEqual(GlassesConnectionStatus.of(control: .setupRequired, audio: true), .setupNeeded)
        for state in [InmoConnectionState.idle, .unavailable, .failed, .disconnected] {
            XCTAssertEqual(GlassesConnectionStatus.of(control: state, audio: true), .audioOnly)
            XCTAssertEqual(GlassesConnectionStatus.of(control: state, audio: false), .offline)
        }
        XCTAssertTrue(GlassesConnectionStatus.connected.lit)
        XCTAssertFalse(GlassesConnectionStatus.audioOnly.lit)
        XCTAssertFalse(GlassesConnectionStatus.setupNeeded.title.lowercased().contains("identity"))
    }

    func testOfficialTraceScreens() throws {
        try RenderHarness.write(NavigationStack { InmoTraceView() }, size: CGSize(width: 402, height: 874), name: "inmo-traces-empty")
        try RenderHarness.write(NavigationStack { InmoTraceGuideView() }, size: CGSize(width: 402, height: 1200), name: "inmo-traces-guide")
        let summary = InmoTraceSummary(format: "PCAP", packetCount: 1, previews: [InmoTracePreview(id: 1, byteCount: 3, hex: "aa 55 01")], notice: "Container records, not decoded INMO commands.")
        let attachment = InmoTraceAttachment(id: UUID(), originalName: "brightness.pcap", storedName: "fixture.pcap", source: .network, importedAt: Date(), byteCount: 43, sha256: String(repeating: "a", count: 64), summary: summary)
        try RenderHarness.write(NavigationStack { InmoTraceDetailView(attachment: attachment) }, size: CGSize(width: 402, height: 1000), name: "inmo-traces-detail")
    }

}
