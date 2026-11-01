import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Insights → Costs drawn from real payloads, to look at before installing.
///
/// Reads the JSON from `COSTS_FIXTURE_DIR` (costs_overview.json,
/// costs_detail_anthropic.json, costs_detail_claude_code.json); skipped when
/// they aren't there. PNGs land in /tmp/ringshots (or `RING_SNAPSHOT_DIR`).
@MainActor
final class CostsRenderTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONObject {
        let dir = ProcessInfo.processInfo.environment["COSTS_FIXTURE_DIR"] ?? "/tmp/costs-fixtures"
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no fixture at \(url.path)") }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? JSONObject)
    }

    private func store() throws -> (CostsStore, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        let claude = try JSONSerialization.data(withJSONObject: try fixture("costs_detail_claude_code.json"))
        let anthropic = try JSONSerialization.data(withJSONObject: try fixture("costs_detail_anthropic.json"))
        transport.route("/api/costs/service", reply: { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "id" }?.value ?? ""
            return MockTransport.Reply(body: id == "claude-code" ? claude : anthropic)
        })
        transport.route("/api/costs", json: try fixture("costs_overview.json"))
        return (CostsStore(api: CostsAPI(api: api)), transport)
    }

    func testTheCostsTabRenders() async throws {
        let (store, _) = try store()
        await store.reload()
        let page = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InsightsSegmentedPill(options: InsightsTab.allCases.map { ($0, $0.label) },
                                      selection: InsightsTab.costs) { _ in }
                    .padding(.bottom, 16)
                InsightsPeriodSelector(days: 30) { _ in }.padding(.bottom, 16)
                CostsView(store: store)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        try RenderHarness.write(page, size: CGSize(width: 402, height: 2600), name: "costs-tab")
    }

    func testServiceSheetsRender() async throws {
        let (store, _) = try store()
        await store.reload()
        for id in ["anthropic", "claude-code"] {
            let model = CostServiceModel(serviceID: id, store: store)
            await model.load()
            XCTAssertNotNil(model.detail)
            let sheet = ScrollView { CostServiceDetailView(model: model).padding(20) }
                .background(JcTheme.surface)
            try RenderHarness.write(sheet, size: CGSize(width: 402, height: 2000), name: "costs-sheet-\(id)")
        }
    }
}
