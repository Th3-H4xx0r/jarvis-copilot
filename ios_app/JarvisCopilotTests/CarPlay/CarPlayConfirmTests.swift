import XCTest
@testable import JarvisCopilot

/// The call/text card on the car is a state of the voice card itself (2026-10-18 11:38: a screen
/// pushed over it hid the voice card and stopped the mic mid-question): who and what as its
/// title, the person's photo, Send (Call) / Cancel as its buttons.
@MainActor
final class CarPlayConfirmTests: XCTestCase {

    private func card(_ kind: SendConfirmations.Item.Kind = .text, text: String = "hello",
                      name: String? = "Shabd Veyyakula", id: String = "c1", more: Int = 0) -> SendConfirmations.Card {
        let item = SendConfirmations.Item(kind: kind, to: "+12096277732", text: text, subject: "", via: "Mac")
        return SendConfirmations.Card(id: id, items: Array(repeating: item, count: 1 + more),
                                      deadline: .distantFuture, name: name, photo: nil)
    }

    func testATextSaysWhoAndWhatLongestFirst() {
        XCTAssertEqual(CarPlayConfirmText.titles(card()), [
            "Text Shabd Veyyakula: “hello”", "Text Shabd: “hello”", "Text Shabd Veyyakula?", "Text Shabd?",
        ])
    }

    func testACallAsksToCall() {
        XCTAssertEqual(CarPlayConfirmText.titles(card(.call, text: "")), ["Call Shabd Veyyakula?", "Call Shabd?"])
        XCTAssertEqual(CarPlayConfirmText.buttons(card(.call, text: "")).first?.title, "Call")
    }

    func testSomeoneNotInContactsIsTheirNumber() {
        XCTAssertEqual(CarPlayConfirmText.titles(card(name: nil)).first, "Text +12096277732: “hello”")
    }

    func testSendAndCancelAreYesAndNo() {
        let buttons = CarPlayConfirmText.buttons(card())
        XCTAssertEqual(buttons.map(\.title), ["Send", "Cancel"])
        XCTAssertEqual(buttons.map(\.yes), [true, false])
        XCTAssertEqual(buttons.map(\.symbol), ["paperplane.fill", "xmark"])
    }

    func testEachCardIsItsOwnState() {
        XCTAssertNotEqual(CarPlayConfirmText.stateID(card(id: "a")), CarPlayConfirmText.stateID(card(id: "b")))
    }

    func testSeveralAtOnceSayHowManyMore() {
        XCTAssertEqual(CarPlayConfirmText.titles(card(more: 1)).first, "Text Shabd Veyyakula: “hello” +1")
    }

    func testTheAvatarIsDrawnWithOrWithoutAPhoto() {
        XCTAssertEqual(CarPlayConfirmText.avatar(card()).size.width, 120)
        XCTAssertEqual(CarPlayConfirmText.avatar(card(name: nil)).size.width, 120)
    }
}
