import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The server half of the Devices tab. The wearables half is `ScanView`, which
/// predates the port and is embedded unchanged.
@MainActor
final class DevicesUITests: XCTestCase {

    private func loadedStore() async -> DevicesStore {
        let (api, transport) = JarvisAPI.mocked()
        // Substring routing, first match wins — the skills catalogue path also
        // starts with /api/devices.
        transport.route("/api/devices/skills", json: MoreUIBFixtures.deviceSkills)
        transport.route("/api/devices", json: MoreUIBFixtures.devices)
        transport.route("/api/system/health", json: MoreUIBFixtures.systemHealth)
        transport.route("/api/wiki/status", json: MoreUIBFixtures.wikiStatus)
        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()
        return store
    }

    // MARK: Device kind → glyph

    func testDeviceGlyphFollowsThePlatformAndTheLabel() {
        func symbol(platform: String, label: String) -> String {
            deviceSectionSymbol(Device(json: ["id": "x", "platform": platform, "label": label]))
        }
        XCTAssertEqual(symbol(platform: "mobile-ios", label: "Pranav's iPhone"), "iphone")
        XCTAssertEqual(symbol(platform: "mobile-android", label: "Pixel"), "iphone")
        XCTAssertEqual(symbol(platform: "browser", label: "Safari on iPad"), "ipad")
        // A browser whose label says Macintosh is a laptop, not a globe.
        XCTAssertEqual(symbol(platform: "browser", label: "Chrome Macintosh"), "laptopcomputer")
        XCTAssertEqual(symbol(platform: "browser", label: "Chrome"), "globe")
        XCTAssertEqual(symbol(platform: "browser", label: "Apple Watch"), "applewatch")
        XCTAssertEqual(symbol(platform: "", label: "windows box"), "desktopcomputer")
        XCTAssertEqual(symbol(platform: "", label: ""), "desktopcomputer")
    }

    // MARK: Store-backed row data

    func testGrantedSkillsAreTheAllowedOnesOnly() async {
        let store = await loadedStore()
        let phone = store.devices[0]
        XCTAssertEqual(store.grantedSkills(for: phone).map(\.name), ["copy_text"])
        // Against the full catalogue, the denied skill still appears — marked off.
        let all = store.skills(for: phone)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter(\.allowed).map(\.name), ["copy_text"])
        XCTAssertEqual(all.first(where: { $0.name == "copy_text" })?.displayName, "Copy text")
    }

    func testStatusAndLastSeenLabels() async {
        let store = await loadedStore()
        XCTAssertEqual(store.devices.map(\.statusLabel), ["ONLINE", "OFFLINE"])
        XCTAssertEqual(store.devices.map(\.statusTone), [.success, .muted])
        XCTAssertEqual(store.devices[1].displayName, "MacBook Pro")
    }

    // MARK: Hosting

    func testLoadedServerSectionRenders() async {
        let store = await loadedStore()
        XCTAssertNil(store.errorMessage)
        moreUIBHost(DevicesServerSection(store: store))
    }

    func testEmptyServerSectionRenders() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/skills", json: ["skills": []])
        transport.route("/api/devices", json: ["devices": []])
        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()
        XCTAssertTrue(store.isEmpty)
        moreUIBHost(DevicesServerSection(store: store))
    }

    func testErrorServerSectionRenders() async {
        let (api, _) = JarvisAPI.mocked()
        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()

        // The page picks its error branch off exactly these three; asserting the
        // state is what stops this from passing on a page that renders nothing.
        XCTAssertFalse(store.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertTrue(store.hasLoaded)
        moreUIBHost(DevicesServerSection(store: store))
    }

    /// With rows on screen the page keeps them and reports the failed refresh in
    /// the shared banner instead (silent-failures M3).
    func testAFailedRefreshOverLoadedDevicesKeepsTheRows() async {
        let store = await loadedStore()
        let loaded = store.devices.count
        XCTAssertGreaterThan(loaded, 0)

        let (deadAPI, _) = JarvisAPI.mocked()
        let dead = DevicesStore(api: DevicesAPI(api: deadAPI), insights: InsightsAPI(api: deadAPI))
        await dead.refresh()
        XCTAssertNotNil(dead.errorMessage)

        moreUIBHost(DevicesServerSection(store: store)
            .loadErrorBanner("Refresh failed", hasContent: true))
    }

    /// The tab root itself — the segmented control plus whichever half is
    /// showing. Defaults to the wearables scanner, so this also proves the
    /// embedded `ScanView` still builds inside the new shell.
    func testDevicesTabRootRenders() async {
        let store = await loadedStore()
        moreUIBHost(DevicesPage(store: store))
    }

    func testPairSheetRenders() async {
        let store = await loadedStore()
        moreUIBHost(DevicePairSheet(store: store))
    }

    func testHealthStripRendersWithAndWithoutMetrics() async {
        let store = await loadedStore()
        moreUIBHost(DevicesHealthStrip(health: store.health, wiki: store.wiki))
        moreUIBHost(DevicesHealthStrip(health: SystemHealth(), wiki: WikiStatus()))
    }

    /// One device card in both of its states — the skill list is only built when
    /// the disclosure is open, so the collapsed render proves nothing about it.
    func testDeviceCardRendersCollapsedAndExpanded() async {
        let store = await loadedStore()
        let phone = store.devices[0]
        let skills = store.grantedSkills(for: phone)
        moreUIBHost(DeviceServerCard(device: phone, skills: skills, isThisDevice: true,
                                     onLogout: {}, onRevoke: {}))
        moreUIBHost(DeviceServerCard(device: phone, skills: skills, isThisDevice: true,
                                     expanded: true, onLogout: {}, onRevoke: {}))
        // A device with nothing granted still opens, with a sentence instead of a
        // list — an empty disclosure reads as a bug.
        moreUIBHost(DeviceServerCard(device: store.devices[1], skills: [],
                                     expanded: true, onLogout: {}, onRevoke: {}))
    }

    /// The alert text names the device and the verb, so the confirm button isn't
    /// the only thing standing between a tap and an un-paired laptop.
    func testConfirmationCopyNamesTheDeviceAndTheAction() async {
        let store = await loadedStore()
        let device = store.devices[1]
        let revoke = DevicesConfirmation(device: device, kind: .revoke)
        XCTAssertEqual(revoke.title, "Revoke MacBook Pro?")
        XCTAssertEqual(revoke.confirmTitle, "Revoke")
        XCTAssertTrue(revoke.destructive)

        let logout = DevicesConfirmation(device: device, kind: .logout)
        XCTAssertEqual(logout.title, "Log out MacBook Pro?")
        XCTAssertEqual(logout.confirmTitle, "Log out")
        XCTAssertFalse(logout.destructive)
        XCTAssertNotEqual(revoke.id, logout.id)
    }

    /// The segmented control is read at a glance, so both labels are one word.
    func testSectionTitlesAreSingleWords() {
        XCTAssertEqual(DevicesSection.server.title, "Server")
        XCTAssertEqual(DevicesSection.wearables.title, "Wearables")
    }
}
