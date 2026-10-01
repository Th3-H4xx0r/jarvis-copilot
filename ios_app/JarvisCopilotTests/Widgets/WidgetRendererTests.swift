import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The design renderer shared by the Dynamic Island and the Home Screen widgets.
@MainActor
final class WidgetRendererTests: XCTestCase {

    private func design(_ json: String) throws -> JCDesign {
        try JSONDecoder().decode(JCDesign.self, from: Data(json.utf8))
    }

    func testAWidgetSizeDecodesAndLargerSizesFallBackToIt() throws {
        let d = try design(#"{"presentations":{"small":{"type":"text","text":"hi"}}}"#)
        XCTAssertEqual(d.node(for: .small)?.type, "text")
        XCTAssertEqual(d.node(for: .medium)?.type, "text")
        XCTAssertEqual(d.node(for: .large)?.type, "text")
        XCTAssertEqual(d.node(for: .extraLarge)?.type, "text")
        XCTAssertNil(d.node(for: .circular), "a home-screen layout never lands on the lock screen")
        XCTAssertNil(d.node(for: .inline))
    }

    func testEachSizeUsesItsOwnLayoutWhenThereIsOne() throws {
        let d = try design(#"""
            {"presentations":{"small":{"type":"text","text":"s"},"medium":{"type":"stat","label":"m"},
             "rectangular":{"type":"text","text":"r"},"circular":{"type":"gauge"}}}
            """#)
        XCTAssertEqual(d.node(for: .medium)?.type, "stat")
        XCTAssertEqual(d.node(for: .large)?.type, "stat")
        XCTAssertEqual(d.node(for: .circular)?.type, "gauge")
        XCTAssertEqual(d.node(for: .rectangular)?.type, "text")
    }

    func testTheRectangleFallsBackToTheInlineLayout() throws {
        let d = try design(#"{"presentations":{"inline":{"type":"text","text":"i"}}}"#)
        XCTAssertEqual(d.node(for: .rectangular)?.type, "text")
    }

    func testIslandDesignsStillDecode() throws {
        let d = try design(#"{"presentations":{"expanded":{"type":"text","text":"x"}}}"#)
        XCTAssertEqual(d.presentations.expanded?.type, "text")
        XCTAssertNil(d.node(for: .small))
    }

    func testTheRendererDrawsADesignBoundToSnapshotData() throws {
        let d = try design(#"{"presentations":{"small":{"type":"stat","label":"Steps","value":{"src":"health.steps"}}}}"#)
        let ctx = JCBindingContext(data: ["health.steps": .number(7312)])
        let view = JCDesignRenderer(tint: .white).render(d.node(for: .small), ctx).frame(width: 170, height: 170)
        XCTAssertNotNil(ImageRenderer(content: view).uiImage)
    }

    // MARK: chart, model, button, toggle

    private func image(_ json: String, data: [String: JCJSON] = [:]) throws -> UIImage? {
        let node = try JSONDecoder().decode(JCNode.self, from: Data(json.utf8))
        let view = JCDesignRenderer(tint: .white).render(node, JCBindingContext(data: data))
            .frame(width: 170, height: 170)
        return ImageRenderer(content: view).uiImage
    }

    func testAChartDrawsASeriesOfNumbersOrPoints() throws {
        XCTAssertNotNil(try image(#"{"type":"chart","series":{"src":"health.steps_week"},"style":"bar"}"#,
                                  data: ["health.steps_week": .array([.number(1), .number(3), .number(2)])]))
        let points: JCJSON = .array([.object(["x": .string("Mon"), "y": .number(4)]),
                                     .object(["x": .string("Tue"), "y": .number(6)])])
        XCTAssertNotNil(try image(#"{"type":"chart","series":{"src":"s"},"style":"line"}"#, data: ["s": points]))
    }

    func testAChartWithNoDataStillDraws() throws {
        XCTAssertNotNil(try image(#"{"type":"chart","series":{"src":"missing"}}"#))
    }

    func testAModelWithoutItsPictureFallsBackToASymbol() throws {
        XCTAssertNil(WidgetImages.model("no-such-device"))
        XCTAssertNotNil(try image(#"{"type":"model","device":"no-such-device"}"#))
    }

    func testButtonsAndTogglesDrawEvenForAMissingButton() throws {
        XCTAssertNotNil(try image(#"{"type":"button","button":"gone","label":"Lights"}"#))
        XCTAssertNotNil(try image(#"{"type":"toggle","button":"gone","label":"X5 link"}"#))
    }

    func testChartValuesComeFromNumbersOrXYObjects() {
        XCTAssertEqual(JCChartPoint.points(from: [.number(1), .number(2)]).map(\.value), [1, 2])
        XCTAssertEqual(JCChartPoint.points(from: [.object(["x": .string("a"), "y": .number(5)])]).map(\.label), ["a"])
        XCTAssertEqual(JCChartPoint.points(from: [.string("bad")]), [])
    }
}
