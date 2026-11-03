import SwiftUI
import XCTest
@testable import JarvisCopilot

@MainActor
final class IntegrationUITests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func ref(_ object: [String: JCJSON]) -> JCValueRef { JCValueRef(.object(object)) }

    func testDottedBindingsReadNestedStateAndRows() {
        let state = IntegrationUIDecode.state(json(#"{"totals":{"spent":42.5},"items":[{"name":"Milk"}]}"#))!
        let ctx = JCBindingContext(data: state)
        XCTAssertEqual(ref(["$": .string("totals.spent")]).string(ctx), "42.5")
        XCTAssertEqual(ref(["$": .string("items.0.name")]).string(ctx), "Milk")
        XCTAssertEqual(ref(["$": .string("totals.nope"), "default": .string("—")]).string(ctx), "—")
        let row = ctx.withRow(["meta": .object(["qty": .number(3)])])
        XCTAssertEqual(ref(["$row": .string("meta.qty")]).string(row), "3")
    }

    func testFlatWidgetKeysStillWin() {
        let ctx = JCBindingContext(data: ["health.steps": .number(1200),
                                          "health": .object(["steps": .number(1)])])
        XCTAssertEqual(ref(["$": .string("health.steps")]).string(ctx), "1200")
    }

    func testFoundationRoundTripKeepsBoolsAndNumbers() {
        let value = JCJSON(foundation: json(#"{"on":true,"n":1,"s":"x","a":[false,2]}"#))
        guard case .object(let o) = value else { return XCTFail("not an object") }
        XCTAssertEqual(o["on"], .bool(true))
        XCTAssertEqual(o["n"], .number(1))
        XCTAssertEqual(o["a"], .array([.bool(false), .number(2)]))
        let back = value.foundation as? [String: Any]
        XCTAssertEqual(back?["on"] as? Bool, true)
    }

    func testConfirmsFromCardsAndScripts() {
        XCTAssertEqual(IntegrationUIDecode.confirms(json(#"{"clear":"Clear all?"}"#)), ["clear": "Clear all?"])
        XCTAssertEqual(IntegrationUIDecode.confirms(json(#"{"clear":{"confirm":"Sure?"},"add":{}}"#)),
                       ["clear": "Sure?"])
        let card = IntegrationUICard(json: json(#"{"id":"shop","name":"Shop","version":3,"card":{"type":"text","value":"hi"},"state":{"n":1},"confirms":{"x":"Go?"},"error":""}"#))
        XCTAssertEqual(card.id, "shop")
        XCTAssertEqual(card.version, 3)
        XCTAssertEqual(card.confirms, ["x": "Go?"])
        XCTAssertNil(card.error, "a blank error is no error")
        XCTAssertEqual(card.state?["n"], .number(1))
    }

    func testTextFieldIDsFindsNestedFields() throws {
        let root = try XCTUnwrap(IntegrationUIDecode.node(json(Self.pageJSON)))
        XCTAssertEqual(IntegrationUIRenderer.textFieldIDs(in: root), ["new_item"])
    }

    func testActionBusyKeyPrefersControlThenRow() {
        XCTAssertEqual(IntegrationUIAction(name: "add", control: "new_item").busyKey, "new_item")
        XCTAssertEqual(IntegrationUIAction(name: "toggle", row: ["id": .string("7")]).busyKey, "toggle#7")
        XCTAssertEqual(IntegrationUIAction(name: "refresh").busyKey, "refresh")
    }

    func testDatesRoundTrip() throws {
        let d = try XCTUnwrap(IntegrationUIDates.parse("2026-11-03"))
        XCTAssertEqual(IntegrationUIDates.format(d, mode: "date"), "2026-11-03")
        let t = try XCTUnwrap(IntegrationUIDates.parse("07:45"))
        XCTAssertEqual(IntegrationUIDates.format(t, mode: "time"), "07:45")
        XCTAssertNotNil(IntegrationUIDates.parse("2026-11-03T12:00:00Z"))
    }

    /// Renders the sample page + card to /tmp/ringshots for a look before shipping.
    func testRenderSamplePageAndCard() throws {
        let state = #"{"count":3,"done":1,"spent":"$48","items":[{"id":"1","name":"Milk","qty":"2 L","done":false},{"id":"2","name":"Eggs","qty":"12","done":true},{"id":"3","name":"Bread","qty":"1","done":false}],"week":[3,5,2,6,4,7,5],"filter":"all"}"#
        let page = IntegrationUIStore(card: IntegrationUICard(json: json(
            #"{"id":"render-test-page","name":"Shopping","version":1,"card":\#(Self.pageJSON),"state":\#(state)}"#)))
        XCTAssertNotNil(page.root)
        try RenderHarness.write(ScrollView { IntegrationUIPageSection(store: page).padding(16) },
                                size: CGSize(width: 393, height: 1350), name: "integration-ui-page")
        let card = IntegrationUIStore(card: IntegrationUICard(json: json(
            #"{"id":"render-test-card","name":"Shopping","version":1,"card":\#(Self.cardJSON),"state":\#(state)}"#)))
        XCTAssertNotNil(card.root)
        try RenderHarness.write(
            VStack { IntegrationUICardView(store: card, name: "Shopping List", icon: "cart", integration: nil) }
                .padding(16).frame(maxHeight: .infinity, alignment: .top),
            size: CGSize(width: 393, height: 320), name: "integration-ui-card")
    }

    static let cardJSON = #"""
    {"type":"vstack","spacing":10,"children":[
      {"type":"grid","columns":3,"children":[
        {"type":"stat","value":{"$":"count"},"caption":"to buy"},
        {"type":"stat","value":{"$":"done"},"caption":"done"},
        {"type":"stat","value":{"$":"spent"},"caption":"est."}]},
      {"type":"button","label":"Add milk","symbol":"plus","action":"add_milk"}]}
    """#

    static let pageJSON = #"""
    {"type":"vstack","spacing":4,"children":[
      {"type":"grid","columns":2,"children":[
        {"type":"section","title":"To buy","children":[{"type":"stat","value":{"$":"count"},"unit":"items"}]},
        {"type":"section","title":"Spent","children":[{"type":"stat","value":{"$":"spent"}}]},
        {"type":"section","title":"This week","span":2,"children":[
          {"type":"chart","style":"bar","series":{"$":"week"}}]}]},
      {"type":"section","title":"Add","children":[
        {"type":"hstack","spacing":8,"children":[
          {"type":"textField","id":"new_item","placeholder":"Milk, eggs…","submit":"add"},
          {"type":"button","label":"Add","symbol":"plus","action":"add"}]}]},
      {"type":"section","title":"List","children":[
        {"type":"picker","id":"filter","value":{"$":"filter"},"action":"filter",
         "options":[{"label":"All","value":"all"},{"label":"To buy","value":"open"}]},
        {"type":"list","data":{"$":"items"},"row":
          {"type":"row","title":{"$row":"name"},"subtitle":{"$row":"qty"},"check":{"$row":"done"},
           "action":"toggle","swipe":[{"label":"Delete","action":"delete","role":"destructive"}]}}]},
      {"type":"section","title":"Details","children":[
        {"type":"hstack","spacing":16,"children":[
          {"type":"gauge","value":0.62,"label":"62%","caption":"of budget"},
          {"type":"vstack","spacing":8,"children":[
            {"type":"titleSubtitle","title":"Trader Joe's","subtitle":"Usual store · 12 min away"},
            {"type":"badge","text":"Open now"},
            {"type":"progress","value":0.62}]}]},
        {"type":"divider"},
        {"type":"keyValue","pairs":[{"label":"Last trip","value":"Sat 4:10 PM"},{"label":"Average","value":"$52"},{"label":"Trips this month","value":"3"}]}]},
      {"type":"section","title":"Settings","children":[
        {"type":"toggle","id":"weekly","label":"Weekly reminder","value":true,"action":"weekly"},
        {"type":"stepper","id":"budget","label":"Budget","value":60,"step":5,"action":"budget"},
        {"type":"slider","id":"servings","min":1,"max":8,"step":1,"value":4,"action":"servings"},
        {"type":"date","id":"next","label":"Next shop","value":"2026-11-07","action":"next"}]},
      {"type":"button","label":"Clear checked","role":"destructive","full":true,"action":"clear"}]}
    """#
}
