import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The builder's rows-of-blocks model, what it compiles to, and the starter templates.
@MainActor
final class WidgetBuilderTests: XCTestCase {

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func node(_ block: WidgetBlock) -> [String: Any] { block.compile() }

    func testAStatBindsItsValueAndShowsItsLabel() {
        let n = node(WidgetBlock(kind: .stat, source: "health.steps", label: "Steps"))
        XCTAssertEqual(n["type"] as? String, "vstack")
        let children = n["children"] as? [[String: Any]] ?? []
        XCTAssertEqual(children.first?["type"] as? String, "text")
        XCTAssertEqual(children.first?["value"] as? String, "Steps")
        XCTAssertEqual(children.last?["type"] as? String, "stat")
        XCTAssertEqual((children.last?["value"] as? [String: Any])?["src"] as? String, "health.steps")
    }

    func testAFormatTravelsWithTheBinding() {
        let n = node(WidgetBlock(kind: .text, source: "x5ring.battery", format: "{}%"))
        let value = n["value"] as? [String: Any]
        XCTAssertEqual(value?["src"] as? String, "x5ring.battery")
        XCTAssertEqual(value?["fmt"] as? String, "{}%")
    }

    func testEveryKindCompilesToATypeTheRendererKnows() {
        let known: Set<String> = ["vstack", "hstack", "text", "stat", "symbol", "gauge", "progress", "chart",
                                  "sparkline", "model", "button", "toggle", "spacer", "divider"]
        for kind in WidgetBlock.Kind.allCases {
            let type = node(WidgetBlock(kind: kind, source: "health.steps", label: "x"))["type"] as? String
            XCTAssertTrue(known.contains(type ?? ""), "\(kind) → \(type ?? "nil")")
        }
    }

    func testAChartKeepsItsStyle() throws {
        let n = node(WidgetBlock(kind: .chart, source: "health.steps_week", chartStyle: "bar"))
        let chart = (n["type"] as? String) == "chart" ? n : (n["children"] as? [[String: Any]])?.last
        XCTAssertEqual(chart?["style"] as? String, "bar")
        let decoded = try JSONDecoder().decode(JCNode.self, from: JSONSerialization.data(withJSONObject: chart ?? [:]))
        XCTAssertEqual(decoded.string("style"), "bar", "the renderer reads a chart's style string")
    }

    func testRowsBecomeAVerticalStackOfHorizontalStacks() {
        let layout = WidgetLayout(rows: [WidgetRow(blocks: [WidgetBlock(kind: .symbol, symbol: "heart.fill"),
                                                            WidgetBlock(kind: .stat, source: "health.hr_avg")]),
                                         WidgetRow(blocks: [WidgetBlock(kind: .chart, source: "health.hr_week")])])
        let n = layout.compile()
        XCTAssertEqual(n["type"] as? String, "vstack")
        let rows = n["children"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.map { $0["type"] as? String }, ["hstack", "hstack"])
        XCTAssertEqual((rows.first?["children"] as? [Any])?.count, 2)
    }

    func testADraftCompilesToADesignTheWidgetCanDrawAndReopensInTheBuilder() throws {
        var draft = WidgetDesignDraft.blank(name: "My steps")
        draft.layouts[WidgetSize.small.rawValue] = WidgetLayout(rows: [WidgetRow(blocks: [
            WidgetBlock(kind: .stat, source: "health.steps", label: "Steps")])])
        let json = draft.compile()
        let design = try JSONDecoder().decode(JCDesign.self, from: json)
        XCTAssertEqual(design.name, "My steps")
        XCTAssertNotNil(design.node(for: .small))
        XCTAssertNotNil(design.node(for: .large), "larger sizes fall back to the small layout")
        XCTAssertEqual(WidgetDesignDraft(json: json), draft)
        XCTAssertTrue(WidgetDesignCache.isValidID(draft.id))
        XCTAssertEqual(try object(json)["schema"] as? Int, 1)
    }

    func testADesignWithoutABuilderLayoutDoesNotReopenAsADraft() {
        let json = Data(#"{"schema":1,"id":"hand","name":"By hand","presentations":{"small":{"type":"text","value":"x"}}}"#.utf8)
        XCTAssertNil(WidgetDesignDraft(json: json))
    }

    func testEveryTemplateCompilesAndDrawsAtEverySizeItDesigns() throws {
        XCTAssertGreaterThanOrEqual(WidgetTemplates.all.count, 15)
        let data: [String: JCJSON] = ["health.steps": .number(7312), "health.score": .number(72),
                                      "health.steps_week": .array([.number(1), .number(2)]),
                                      "x5ring.battery": .number(80), "chat.last_reply": .string("Done.")]
        for template in WidgetTemplates.all {
            let draft = template.make([ControlButtonInfo(id: "b1", name: "Lights", symbol: "lightbulb.fill")])
            let design = try JSONDecoder().decode(JCDesign.self, from: draft.compile())
            XCTAssertFalse(draft.layouts.isEmpty, template.id)
            for key in draft.layouts.keys {
                let size = try XCTUnwrap(WidgetSize(rawValue: key), "\(template.id): \(key)")
                let view = JCDesignRenderer(tint: .white).render(design.node(for: size), JCBindingContext(data: data))
                    .frame(width: 330, height: 330)
                XCTAssertNotNil(ImageRenderer(content: view).uiImage, "\(template.id) at \(key)")
            }
        }
    }

    func testTemplatesOnlyBindToValuesTheHubPublishes() {
        for template in WidgetTemplates.all {
            for source in template.make([]).sources {
                XCTAssertNotNil(WidgetDataCatalog.entry(source), "\(template.id) binds \(source)")
            }
        }
    }
}
