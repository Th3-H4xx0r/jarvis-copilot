import XCTest
@testable import JarvisCopilot

/// The call/text card on the car's screen: who, what, and Send (Call) / Cancel — then how it went.
@MainActor
final class CarPlayConfirmTests: XCTestCase {

    private func card(kind: SendConfirmations.Item.Kind = .text, text: String = "hello",
                      name: String? = "Shabd Patel") -> SendConfirmations.Card {
        SendConfirmations.Card(id: "c1", items: [.init(kind: kind, to: "+12096277732", text: text, subject: "", via: "Mac")],
                               deadline: .distantFuture, name: name, photo: nil)
    }

    func testATextShowsWhoAndTheMessageWithSendAndCancel() {
        let screen = CarPlayConfirmText.make(card(), outcome: nil, answering: false)
        XCTAssertEqual(screen.title, "Shabd Patel")
        XCTAssertEqual(screen.subtitle, "Text · +12096277732")
        XCTAssertEqual(screen.rows, ["hello"])
        XCTAssertEqual(screen.buttons.map(\.title), ["Send", "Cancel"])
        XCTAssertEqual(screen.buttons.map(\.yes), [true, false])
        XCTAssertTrue(screen.enabled)
    }

    func testACallShowsTheNumberAndCall() {
        let screen = CarPlayConfirmText.make(card(kind: .call, text: ""), outcome: nil, answering: false)
        XCTAssertEqual(screen.rows, ["+12096277732"])
        XCTAssertEqual(screen.buttons.first?.title, "Call")
        XCTAssertEqual(screen.buttons.first?.symbol, "phone.fill")
    }

    func testTheButtonsWaitWhileHisAnswerIsOnItsWay() {
        XCTAssertFalse(CarPlayConfirmText.make(card(), outcome: nil, answering: true).enabled)
    }

    func testHowItWentReplacesTheButtons() {
        let sent = CarPlayConfirmText.make(card(), outcome: .sent, answering: true)
        XCTAssertEqual(sent.subtitle, "Sent")
        XCTAssertTrue(sent.buttons.isEmpty)
        XCTAssertEqual(CarPlayConfirmText.make(card(kind: .call, text: ""), outcome: .sent, answering: false).subtitle,
                       "Calling…")
        XCTAssertEqual(CarPlayConfirmText.make(card(), outcome: .failed, answering: false).subtitle,
                       "Didn't go through")
    }

    func testTheAvatarIsDrawnWithOrWithoutAPhoto() {
        if #available(iOS 26.4, *) {
            XCTAssertEqual(CarPlayConfirmScreen.avatar(card()).size.width, 120)
            XCTAssertEqual(CarPlayConfirmScreen.avatar(card(name: nil)).size.width, 120)
        }
    }
}
