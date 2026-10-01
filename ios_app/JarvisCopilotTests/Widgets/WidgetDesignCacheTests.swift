import WidgetKit
import XCTest
@testable import JarvisCopilot

/// Widget designs cached in the App Group, and the index the widget lists them from.
final class WidgetDesignCacheTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("widget-designs-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func json(_ id: String, name: String = "Steps") -> Data {
        Data(#"{"schema":1,"id":"\#(id)","name":"\#(name)","icon":"figure.walk","presentations":{"small":{"type":"stat","label":"Steps","value":{"src":"health.steps"}}}}"#.utf8)
    }

    func testASavedDesignLoadsBackAndIsListed() throws {
        let info = try WidgetDesignCache.save(json("steps"), in: dir)
        XCTAssertEqual(info, WidgetDesignInfo(id: "steps", name: "Steps", icon: "figure.walk"))
        XCTAssertEqual(WidgetDesignCache.load("steps", in: dir)?.node(for: .small)?.type, "stat")
        XCTAssertEqual(WidgetDesignCache.infos(in: dir).map(\.id), ["steps"])
        XCTAssertNotNil(WidgetDesignCache.rawJSON("steps", in: dir))
    }

    func testSavingAgainUpdatesTheIndexInPlace() throws {
        try WidgetDesignCache.save(json("a", name: "One"), in: dir)
        try WidgetDesignCache.save(json("b", name: "Two"), in: dir)
        try WidgetDesignCache.save(json("a", name: "Renamed"), in: dir)
        XCTAssertEqual(WidgetDesignCache.infos(in: dir).map(\.name), ["Renamed", "Two"])
    }

    func testRemovingDropsTheFileAndTheListing() throws {
        try WidgetDesignCache.save(json("a"), in: dir)
        WidgetDesignCache.remove("a", in: dir)
        XCTAssertNil(WidgetDesignCache.load("a", in: dir))
        XCTAssertTrue(WidgetDesignCache.infos(in: dir).isEmpty)
    }

    func testABadIdIsRefused() {
        XCTAssertThrowsError(try WidgetDesignCache.save(json("../escape"), in: dir))
        XCTAssertThrowsError(try WidgetDesignCache.save(Data("not json".utf8), in: dir))
    }

    func testEveryWidgetFamilyHasASize() {
        XCTAssertEqual(WidgetSize(family: .systemSmall), .small)
        XCTAssertEqual(WidgetSize(family: .systemMedium), .medium)
        XCTAssertEqual(WidgetSize(family: .systemLarge), .large)
        XCTAssertEqual(WidgetSize(family: .systemExtraLarge), .extraLarge)
        XCTAssertEqual(WidgetSize(family: .accessoryCircular), .circular)
        XCTAssertEqual(WidgetSize(family: .accessoryRectangular), .rectangular)
        XCTAssertEqual(WidgetSize(family: .accessoryInline), .inline)
    }

    func testADeletedDesignStillResolvesSoTheWidgetCanSaySo() async throws {
        let entities = try await WidgetDesignQuery().entities(for: ["deleted-\(UUID().uuidString.lowercased())"])
        XCTAssertEqual(entities.count, 1)
    }

    func testABlankRenderIsNeverSavedAsAModelPicture() {
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        XCTAssertTrue(WidgetModelSnapshots.isBlank(blank))
    }

}
