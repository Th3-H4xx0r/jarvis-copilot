import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Search, grouping and the schema-driven "Test skill" form — the pure parts of
/// the Skills tab — plus a hosting smoke test over a registry we control (the
/// process-wide `SkillRegistry.shared` is empty in the test bundle).
@MainActor
final class SkillsUITests: XCTestCase {

    private func item(_ name: String, _ detail: String = "", enabled: Bool = true,
                      category: String? = nil) -> SkillListItem {
        SkillListItem(name: name, detail: detail, enabled: enabled, category: category)
    }

    // MARK: Search

    func testSearchMatchesNameOrDescriptionCaseInsensitively() {
        let items = [item("copy_text", "Put text on the clipboard"),
                     item("set_torch", "Turn the flashlight on")]
        XCTAssertEqual(SkillsGrouping.filter(items, query: "COPY").map(\.name), ["copy_text"])
        XCTAssertEqual(SkillsGrouping.filter(items, query: "clipboard").map(\.name), ["copy_text"])
        XCTAssertEqual(SkillsGrouping.filter(items, query: "flash").map(\.name), ["set_torch"])
        XCTAssertEqual(SkillsGrouping.filter(items, query: "nope").count, 0)
    }

    func testBlankSearchKeepsEverything() {
        let items = [item("a"), item("b")]
        XCTAssertEqual(SkillsGrouping.filter(items, query: "   ").count, 2)
        XCTAssertEqual(SkillsGrouping.filter(items, query: "").count, 2)
    }

    // MARK: Grouping

    func testAlphabeticalSectionsWhenSkillsCarryNoCategory() {
        let sections = SkillsGrouping.sections([item("set_torch"), item("copy_text"),
                                                item("call"), item("_internal")])
        XCTAssertEqual(sections.map(\.title), ["#", "C", "S"])
        XCTAssertEqual(sections[1].items.map(\.name), ["call", "copy_text"])
    }

    func testCategorySectionsWhenEverySkillCarriesOne() {
        let sections = SkillsGrouping.sections([item("b", category: "Media"),
                                                item("a", category: "Media"),
                                                item("c", category: "System")])
        XCTAssertEqual(sections.map(\.title), ["Media", "System"])
        XCTAssertEqual(sections[0].items.map(\.name), ["a", "b"])
    }

    func testMixedCategoriesFallBackToAlphabetical() {
        // One row without a category is enough — a half-categorised list would
        // otherwise get a phantom "" section.
        let sections = SkillsGrouping.sections([item("b", category: "Media"), item("a")])
        XCTAssertEqual(sections.map(\.title), ["A", "B"])
    }

    func testEmptyCatalogueHasNoSections() {
        XCTAssertTrue(SkillsGrouping.sections([]).isEmpty)
    }

    func testSummaryCountsWhatIsOn() {
        XCTAssertEqual(SkillsGrouping.summary([item("a"), item("b", enabled: false)]),
                       "1 of 2 on")
    }

    // MARK: Argument form

    private let schema: [String: Any] = SkillSchema.object([
        "text": SkillSchema.string("What to copy"),
        "count": SkillSchema.integer(min: 1),
        "level": SkillSchema.number(min: 0, max: 1),
        "loud": SkillSchema.boolean,
        "mode": SkillSchema.enumeration(["a", "b"]),
    ], required: ["text"])

    func testFieldsAreTypedRequiredFirstThenAlphabetical() {
        let fields = SkillArgsForm.fields(from: schema)
        XCTAssertEqual(fields.map(\.key), ["text", "count", "level", "loud", "mode"])
        XCTAssertTrue(fields[0].required)
        XCTAssertEqual(fields[0].detail, "What to copy")
        XCTAssertEqual(fields.map(\.kind), [.text, .integer, .number, .boolean, .choice])
        XCTAssertEqual(fields.last?.options, ["a", "b"])
    }

    func testSchemaWithoutPropertiesHasNoFields() {
        XCTAssertTrue(SkillArgsForm.fields(from: SkillSchema.empty).isEmpty)
        XCTAssertTrue(SkillArgsForm.fields(from: [:]).isEmpty)
    }

    func testArgumentsCoerceByTypeAndDropBlanks() {
        let fields = SkillArgsForm.fields(from: schema)
        let args = SkillArgsForm.arguments(["text": " hi ", "count": "3", "level": "0.5",
                                            "loud": "yes", "mode": "b", "unknown": "x"],
                                           fields: fields)
        XCTAssertEqual(args["text"] as? String, "hi")
        XCTAssertEqual(args["count"] as? Int, 3)
        XCTAssertEqual(args["level"] as? Double, 0.5)
        XCTAssertEqual(args["loud"] as? Bool, true)
        XCTAssertEqual(args["mode"] as? String, "b")
        // A key with no field is not smuggled through.
        XCTAssertNil(args["unknown"])
    }

    func testBlankAndUnparseableValuesAreOmittedNotZeroed() {
        let fields = SkillArgsForm.fields(from: schema)
        let args = SkillArgsForm.arguments(["text": "  ", "count": "abc"], fields: fields)
        XCTAssertTrue(args.isEmpty, "\(args)")
    }

    func testPrettyJSONIsStableAndSurvivesNonJSONPayloads() {
        XCTAssertEqual(SkillArgsForm.prettyJSON(["b": 1, "a": 2]),
                       "{\n  \"a\" : 2,\n  \"b\" : 1\n}")
        XCTAssertFalse(SkillArgsForm.prettyJSON(["d": Date()]).isEmpty)
    }

    // MARK: Model + hosting

    private func makeModel() -> SkillsPageModel {
        let registry = SkillRegistry(store: MemoryKeyValueStore(), skills: [
            AnySkill(name: "copy_text", description: "Put text on the clipboard",
                     inputSchema: schema) { _ in ["ok": true] },
            AnySkill(name: "open_app", description: "Open an app",
                     requiresForeground: true) { _ in ["launched": true] },
        ])
        let model = SkillsPageModel(registry: registry, runner: InvokeRunner(registry: registry))
        model.reload()
        return model
    }

    func testModelMirrorsTheRegistryAndItsToggles() {
        let model = makeModel()
        XCTAssertEqual(model.items.map(\.name), ["copy_text", "open_app"])
        XCTAssertEqual(model.summary, "2 of 2 on")
        XCTAssertTrue(model.items[1].requiresForeground)
        model.setEnabled(false, for: "copy_text")
        XCTAssertEqual(model.summary, "1 of 2 on")
        XCTAssertFalse(model.items[0].enabled)
    }

    func testRunningASkillAppendsToTheLog() async {
        let model = makeModel()
        let result = await model.run("copy_text", arguments: ["text": "hi"])
        XCTAssertTrue(result.contains("\"ok\""), result)
        XCTAssertEqual(model.log.first?.skill, "copy_text")
        XCTAssertFalse(model.log.first?.failed ?? true)
        XCTAssertEqual(Set(model.log.map(\.id)).count, model.log.count)
    }

    func testPausingTheRunnerRefusesInvokes() async {
        let model = makeModel()
        model.setPaused(true)
        XCTAssertTrue(model.paused)
        let result = await model.run("copy_text", arguments: [:])
        XCTAssertEqual(result, "error: paused")
        XCTAssertTrue(model.log.first?.failed ?? false)
    }

    func testPageRenders() {
        let model = makeModel()
        moreUIBHost(SkillsPage(model: model))
    }

    func testPageRendersWithNoMatchAndWithAnEmptyRegistry() {
        let model = makeModel()
        model.query = "nothing matches this"
        XCTAssertFalse(model.hasResults)
        moreUIBHost(SkillsPage(model: model))

        let empty = SkillsPageModel(registry: SkillRegistry(store: MemoryKeyValueStore()),
                                    runner: InvokeRunner(registry: SkillRegistry(store: MemoryKeyValueStore())))
        empty.reload()
        XCTAssertTrue(empty.isEmpty)
        moreUIBHost(SkillsPage(model: empty))
    }

    func testTestSheetRenders() {
        let model = makeModel()
        moreUIBHost(SkillTestSheet(model: model, skill: model.items[0]))
        moreUIBHost(SkillTestSheet(model: model, skill: model.items[1]))
    }
}
