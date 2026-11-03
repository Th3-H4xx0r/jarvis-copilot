import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The Devices tab and the wearable pages on the app's one set of page pieces (large
/// title, one action pill, section labels over cards), drawn so they can be compared
/// with the Health and Settings screens before they reach a phone.
@MainActor
final class DevicesUnifiedRenderTests: XCTestCase {
    private let phone = CGSize(width: 402, height: 874)

    func testTheWearablesTab() throws {
        try RenderHarness.write(DevicesPage(section: .wearables), size: phone, name: "devices-wearables")
    }

    func testTheGlassesSettingsPages() throws {
        try RenderHarness.write(NavigationStack { LiveCaptionsSettingsView() }, size: CGSize(width: 402, height: 1100),
                                name: "glasses-live-captions")
        try RenderHarness.write(NavigationStack { GlassesTranslateView() }, size: CGSize(width: 402, height: 1100),
                                name: "glasses-translate")
    }

    func testTheRunsOnPage() throws {
        try RenderHarness.write(NavigationStack { AgentChoicePage(title: "Runs on", pick: .sameAsDefault) { _ in } },
                                size: phone, name: "ring-runs-on")
    }

    func testTheDoorEditorSheet() throws {
        let door = DoorContact(json: ["id": "d1", "name": "Front door", "instant": true, "active_home": true,
                                      "notify_disarmed": false, "on_open_prompt": "Turn on the hall light"])
        try RenderHarness.write(DoorContactEditor(store: DoorAlarmStore(), contact: door), size: phone,
                                name: "door-contact-editor")
    }

    func testTheBandSyncCard() throws {
        try RenderHarness.write(BandSyncCard(progress: 0.42, stage: "Reading sleep").padding(16),
                                size: CGSize(width: 402, height: 160), name: "band-sync-card")
    }
}
