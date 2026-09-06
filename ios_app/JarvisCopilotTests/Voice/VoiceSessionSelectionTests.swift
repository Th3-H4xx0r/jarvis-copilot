import XCTest
@testable import JarvisCopilot

@MainActor
final class VoiceSessionSelectionTests: XCTestCase {
    private func fresh() -> (VoiceSessionSelection, UserDefaults) {
        let suite = "voice-session-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (VoiceSessionSelection(defaults: defaults), defaults)
    }

    func testDefaultsToTheVoiceSession() {
        let (sel, _) = fresh()
        XCTAssertEqual(sel.target, .defaultVoice)
        XCTAssertEqual(sel.chipLabel, "Voice")
        XCTAssertNil(sel.target.sessionID)
    }

    func testSelectionPersistsAcrossInstances() {
        let (sel, defaults) = fresh()
        sel.select(.session(id: "abc123", title: "Trip planning"))
        let again = VoiceSessionSelection(defaults: defaults)
        XCTAssertEqual(again.target, .session(id: "abc123", title: "Trip planning"))
        XCTAssertEqual(again.chipLabel, "Trip planning")
    }

    func testReconcileDropsAMissingSessionAndRefreshesTitles() {
        let (sel, _) = fresh()
        sel.select(.session(id: "gone", title: "Old"))
        sel.reconcile(with: [ChatSessionSummary(id: "other", title: "Other")])
        XCTAssertEqual(sel.target, .defaultVoice, "a deleted session falls back to Voice")

        sel.select(.session(id: "new1", title: ""))
        XCTAssertEqual(sel.chipLabel, "New session")
        sel.reconcile(with: [ChatSessionSummary(id: "new1", title: "Weather chat")])
        XCTAssertEqual(sel.chipLabel, "Weather chat")
    }
}
