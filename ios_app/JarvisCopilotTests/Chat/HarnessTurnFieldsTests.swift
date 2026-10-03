import XCTest
@testable import JarvisCopilot

final class HarnessTurnFieldsTests: XCTestCase {
    func testChatStartBodyCarriesHarnessID() {
        let body = ChatAPI.startBody(sessionID: "s1", text: "hi", model: "m", provider: nil,
                                     attachments: nil, harnessID: "router")
        XCTAssertEqual(body["harness_id"] as? String, "router")
        XCTAssertEqual(body["model"] as? String, "m")
    }

    func testChatStartBodyWithoutHarnessOmitsIt() {
        let body = ChatAPI.startBody(sessionID: "s1", text: "hi", model: "m", provider: nil,
                                     attachments: nil, harnessID: nil)
        XCTAssertNil(body["harness_id"])
    }

    func testChatStartBodyEmptyHarnessMeansFollowTheDefault() {
        let body = ChatAPI.startBody(sessionID: "s1", text: "hi", model: "m", provider: nil,
                                     attachments: nil, harnessID: "")
        XCTAssertEqual(body["harness_id"] as? String, "")
    }

    func testBeginTurnCarriesHarnessIDAndDropsModel() {
        let payload = VoiceClientMessage.beginTurn(sampleRate: 16000, sessionID: "v1",
                                                   model: "m", provider: "p", harnessID: "fast-claude").payload
        XCTAssertEqual(payload["harness_id"] as? String, "fast-claude")
        XCTAssertNil(payload["model"])
        XCTAssertNil(payload["model_provider"])
    }

    func testBeginTurnSingleKeepsTheVoiceModel() {
        let payload = VoiceClientMessage.beginTurn(sampleRate: 16000, sessionID: "v1",
                                                   model: "m", provider: "p", harnessID: "single").payload
        XCTAssertEqual(payload["harness_id"] as? String, "single")
        XCTAssertEqual(payload["model"] as? String, "m")
    }

    func testVoiceHarnessIDReadsTheStoredChoice() {
        let defaults = UserDefaults(suiteName: "HarnessTurnFieldsTests")!
        defaults.removePersistentDomain(forName: "HarnessTurnFieldsTests")
        XCTAssertNil(voiceTurnHarnessID(defaults))
        defaults.setValue("router", forKey: voiceHarnessDefaultsKey)
        XCTAssertEqual(voiceTurnHarnessID(defaults), "router")
    }

    func testSessionDetailReadsHarnessID() {
        let detail = SessionsAPI.detail(from: ["session": ["session_id": "s1", "harness_id": "router", "messages": []]])
        XCTAssertEqual(detail.harnessID, "router")
    }
}
