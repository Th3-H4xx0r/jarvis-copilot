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
}
