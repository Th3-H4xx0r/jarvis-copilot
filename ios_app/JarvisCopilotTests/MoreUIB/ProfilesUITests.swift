import SwiftUI
import XCTest
@testable import JarvisCopilot

@MainActor
final class ProfilesUITests: XCTestCase {

    private func loadedStore() async -> ProfilesStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/profiles", json: MoreUIBFixtures.profiles)
        transport.route("/api/personality/active", json: MoreUIBFixtures.personality)
        let store = ProfilesStore(api: ProfilesAPI(api: api))
        await store.refresh()
        return store
    }

    func testActiveAndDeletableProfilesAreDistinguished() async {
        let store = await loadedStore()
        XCTAssertEqual(store.profiles.map(\.name), ["default", "work"])
        XCTAssertTrue(store.isActive(store.profiles[0]))
        // The active (and default) profile can't be deleted; the other can.
        XCTAssertFalse(store.canDelete(store.profiles[0]))
        XCTAssertTrue(store.canDelete(store.profiles[1]))
        XCTAssertEqual(store.cloneCandidates, ["default", "work"])
    }

    func testProfileFallsBackToTheAlternateModelKeys() async {
        let store = await loadedStore()
        XCTAssertEqual(store.profiles[1].model, "gpt-5")
        XCTAssertEqual(store.profiles[1].provider, "openai")
    }

    func testLoadedPageRenders() async {
        let store = await loadedStore()
        XCTAssertNil(store.errorMessage)
        moreUIBHost(NavigationStack { ProfilesPage(store: store) })
    }

    func testErrorPageRenders() async {
        let (api, _) = JarvisAPI.mocked()
        let store = ProfilesStore(api: ProfilesAPI(api: api))
        await store.refresh()

        XCTAssertFalse(store.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(store.hasLoaded)
        moreUIBHost(NavigationStack { ProfilesPage(store: store) })
    }

    func testDetailAndCreateSheetsRender() async {
        let store = await loadedStore()
        moreUIBHost(ProfileDetailSheet(store: store, profile: store.profiles[1]))
        moreUIBHost(ProfileCreateSheet(store: store))
    }

    func testPersonalityCardRenders() async {
        let store = await loadedStore()
        let prompt = await store.activePersonality()
        XCTAssertEqual(prompt, "You are JARVIS. Be brief.")
        moreUIBHost(ProfilePersonalityCard(prompt: prompt))
    }
}
