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
        try RenderHarness.write(NavigationStack { InmoGo3View() }, size: CGSize(width: 402, height: 1900),
                                name: "glasses-page")
    }
    func testOfficialTraceScreens() throws {
        try RenderHarness.write(NavigationStack { InmoTraceView() }, size: CGSize(width: 402, height: 874), name: "inmo-traces-empty")
        try RenderHarness.write(NavigationStack { InmoTraceGuideView() }, size: CGSize(width: 402, height: 1200), name: "inmo-traces-guide")
        let summary = InmoTraceSummary(format: "PCAP", packetCount: 1, previews: [InmoTracePreview(id: 1, byteCount: 3, hex: "aa 55 01")], notice: "Container records, not decoded INMO commands.")
        let attachment = InmoTraceAttachment(id: UUID(), originalName: "brightness.pcap", storedName: "fixture.pcap", source: .network, importedAt: Date(), byteCount: 43, sha256: String(repeating: "a", count: 64), summary: summary)
        try RenderHarness.write(NavigationStack { InmoTraceDetailView(attachment: attachment) }, size: CGSize(width: 402, height: 1000), name: "inmo-traces-detail")
    }

}
