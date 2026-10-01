import XCTest
@testable import JarvisCopilot

/// The creator's list of designs: what it saves, reopens and deletes.
@MainActor
final class WidgetDesignStoreTests: XCTestCase {

    private var dir: URL!
    private var server: WidgetSyncTests.FakeServer!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("widget-store-\(UUID().uuidString)")
        server = WidgetSyncTests.FakeServer()
    }

    private func store() -> WidgetDesignStore {
        let sync = WidgetSync(server: server, directory: dir,
                              defaults: UserDefaults(suiteName: "WidgetDesignStoreTests-\(UUID().uuidString)")!,
                              reload: {}, buttons: { [] })
        return WidgetDesignStore(sync: sync, directory: dir)
    }

    func testASavedDraftIsListedAndReopensAsTheSameDraft() async {
        let s = store()
        let draft = WidgetTemplates.all[0].make([])
        _ = await s.save(draft)
        XCTAssertEqual(s.designs.map(\.id), [draft.id])
        XCTAssertEqual(s.draft(draft.id), draft)
        XCTAssertNotNil(server.stored[draft.id])
    }

    func testADesignMadeByHandIsListedButHasNoDraft() async throws {
        let s = store()
        try WidgetDesignCache.save(Data(#"{"schema":1,"id":"hand","name":"By Jarvis","presentations":{"small":{"type":"text","value":"x"}}}"#.utf8), in: dir)
        s.reload()
        XCTAssertEqual(s.designs.map(\.name), ["By Jarvis"])
        XCTAssertNil(s.draft("hand"))
        XCTAssertNotNil(s.design("hand"))
    }

    func testDeletingRemovesIt() async {
        let s = store()
        let draft = WidgetTemplates.all[1].make([])
        _ = await s.save(draft)
        await s.delete(draft.id)
        XCTAssertTrue(s.designs.isEmpty)
    }

    func testEveryWidgetSizeHasAPreviewSize() {
        for size in WidgetSize.allCases {
            let frame = WidgetPreviewSize.points(size)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }
}
