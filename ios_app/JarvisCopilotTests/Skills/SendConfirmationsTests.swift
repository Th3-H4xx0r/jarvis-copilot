import XCTest
@testable import JarvisCopilot

/// The call/text card (2026-10-18): the server shows it when Jarvis asks before calling or sending
/// on a voice turn (agent/send_confirm.py) and closes it when he has answered. Send is his "Yes.",
/// ✕ his "No.", said into the conversation.
@MainActor
final class SendConfirmationsTests: XCTestCase {

    private struct Lookup: ContactCardLooking {
        var known: [String: ContactCardInfo] = [:]
        func lookup(_ handle: String) async -> ContactCardInfo? { known[handle] }
    }

    private let photo = Data([0x89, 0x50, 0x4E, 0x47])
    private var answers: [Bool] = []

    private func makeStore(_ known: [String: ContactCardInfo] = [:]) -> SendConfirmations {
        let store = SendConfirmations(contacts: Lookup(known: known), voice: nil)
        store.outcomeHold = .milliseconds(20)
        store.answer = { [weak self] yes in self?.answers.append(yes) }
        return store
    }

    private func show(_ store: SendConfirmations, id: String = "c1", kind: String = "text",
                      to: String = "+12096277732", text: String = "hello", expiresIn: Double = 120) async {
        _ = await store.handle(["action": "show", "id": id, "expires_in": expiresIn,
                                "items": [["kind": kind, "to": to, "text": text, "subject": "", "via": "Mac"]]])
    }

    func testTheCardShowsTheContactsFullNameAndPhoto() async throws {
        let store = makeStore(["+12096277732": ContactCardInfo(name: "Shabd Patel", photo: photo)])
        await show(store)
        let card = try XCTUnwrap(store.card)
        XCTAssertEqual(card.title, "Shabd Patel")
        XCTAssertEqual(card.photo, photo)
        XCTAssertEqual(card.first.text, "hello")
        XCTAssertEqual(card.actionTitle, "Send")
        XCTAssertEqual(card.subtitle, "Text · +12096277732")
    }

    func testSomeoneNotInContactsShowsTheNumberAndInitials() async throws {
        let store = makeStore()
        await show(store, kind: "call", to: "(209) 627-7732", text: "")
        let card = try XCTUnwrap(store.card)
        XCTAssertEqual(card.title, "(209) 627-7732")
        XCTAssertNil(card.photo)
        XCTAssertEqual(card.actionTitle, "Call")
        XCTAssertEqual(SendConfirmations.Card.initials(of: "Shabd Patel"), "SP")
        XCTAssertEqual(SendConfirmations.Card.initials(of: "(209) 627-7732"), "")
    }

    func testSendIsHisYesAndXIsHisNo() async {
        let store = makeStore()
        await show(store)
        await store.tap(yes: true)
        await store.tap(yes: true)   // a second tap while the first is on its way
        XCTAssertEqual(answers, [true])
        XCTAssertTrue(store.answering)

        await show(store, id: "c2")
        await store.tap(yes: false)
        XCTAssertEqual(answers, [true, false])
    }

    func testTheServersCloseTakesItDown() async throws {
        let store = makeStore()
        await show(store)
        _ = await store.handle(["action": "close", "id": "c1", "outcome": "cancelled"])
        XCTAssertNil(store.card)
    }

    func testSentShowsBrieflyThenGoes() async throws {
        let store = makeStore()
        await show(store)
        _ = await store.handle(["action": "close", "id": "c1", "outcome": "sent"])
        XCTAssertEqual(store.outcome, .sent)
        XCTAssertNotNil(store.card)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(store.card)
        XCTAssertNil(store.outcome)
    }

    func testAnOldCardsCloseLeavesTheNewOne() async throws {
        let store = makeStore()
        await show(store, id: "c1")
        await show(store, id: "c2", text: "running late")
        _ = await store.handle(["action": "close", "id": "c1", "outcome": "cancelled"])
        XCTAssertEqual(store.card?.id, "c2")
        XCTAssertEqual(store.card?.first.text, "running late")
    }

    func testTheCardGoesWhenItsTwoMinutesAreUp() async throws {
        let store = makeStore()
        await show(store, expiresIn: 0.05)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.card)
    }

    func testABadShowIsRefused() async {
        let store = makeStore()
        let result = await store.handle(["action": "show", "id": "c1", "items": []])
        XCTAssertNotNil(result["error"])
        XCTAssertNil(store.card)
    }

    func testTheSkillIsAdvertisedForTheServerToUse() {
        let (boundaries, _) = PhoneSkills.Boundaries.mocked()
        let skill = PhoneSkills.all(boundaries).first { $0.name == SendConfirmations.skillName }
        XCTAssertNotNil(skill)
        XCTAssertFalse(skill?.requiresForeground ?? true, "it shows on the car with the phone locked")
    }
}
