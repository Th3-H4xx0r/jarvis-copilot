import XCTest
import SwiftUI
@testable import JarvisCopilot

/// The phone layout never runs wider than the screen (2026-11-15: a 5-fan legend and fixed-size
/// rows pushed the whole page past 393 pt on his phone). Lays out the real v4 dashboards with a
/// busy PC at iPhone widths and checks nothing exceeds the column.
@MainActor
final class PcStatsLayoutTests: XCTestCase {

    private func width<V: View>(_ view: V, at w: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view.environment(\.colorScheme, .dark))
        return host.sizeThatFits(in: CGSize(width: w, height: 20_000)).width
    }

    func testEveryDashboardFitsTheColumn() {
        for id in ["overview", "gaming", "power"] {
            let model = PcStatsFixtures.model(dashboard: id)
            guard let board = model.active else { return XCTFail("no \(id)") }
            XCTAssertEqual(board.id, id)
            for screen in [375.0, 393.0, 320.0] as [CGFloat] {
                let column = screen - 2 * JcUnified.pageInset
                XCTAssertLessThanOrEqual(width(PcDashboardColumn(widgets: board.widgets, ctx: model.widgetContext), at: column),
                                         column + 0.5, "\(id) at \(screen) pt")
                for w in board.widgets {
                    XCTAssertLessThanOrEqual(width(PcWidgetView(widget: w, ctx: model.widgetContext), at: column), column + 0.5,
                                             "\(id)/\(w.id) at \(screen) pt")
                }
            }
        }
    }

    func testWholePageFitsTheScreen() {
        for id in ["overview", "gaming", "power"] {
            let page = PcStatsPage(deviceId: "pc", name: "pranav-computer", model: PcStatsFixtures.model(dashboard: id))
            for screen in [375.0, 393.0] as [CGFloat] {
                XCTAssertLessThanOrEqual(width(page.content, at: screen), screen + 0.5, "\(id) page at \(screen) pt")
            }
        }
    }

    /// The Jarvis look takes every colour from the app's tokens (JcAccent / JcTheme / JcButton):
    /// no PC Stats file spells out a hue.
    func testNoHardCodedHuesInPcStats() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // JarvisCopilotTests/Agents
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("JarvisCopilot/Copilot/Agents/PcStats")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 6, "found the PC Stats sources at \(dir.path)")
        let banned = try NSRegularExpression(pattern:
            ##"Color\(jcHex|Color\(red:|Color\(\.sRGB|UIColor\(|0x[0-9A-Fa-f]{6}\b|"#[0-9A-Fa-f]{6}"|Color\.(black|white|red|green|blue|orange|yellow|purple|pink|teal|cyan|indigo|mint|gray)\b|\.foregroundStyle\(\.(red|green|blue|orange|yellow|purple|pink|teal|cyan|indigo|mint)\)"##)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNil(banned.firstMatch(in: line, range: range),
                             "\(file.lastPathComponent):\(n + 1) hard-codes a colour: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    func testPairsOnlyWhenEachFitsHalf() {
        XCTAssertTrue(PcPairLayout.sideBySide(idealWidths: [150, 160], width: 343, spacing: 12))
        XCTAssertFalse(PcPairLayout.sideBySide(idealWidths: [179, 120], width: 343, spacing: 12),
                       "the pair fits in total, but one tile would be squeezed")
        XCTAssertFalse(PcPairLayout.sideBySide(idealWidths: [100], width: 343, spacing: 12))
    }

    func testFlowWrapsInsteadOfOverflowing() {
        let items = (1...6).map { "System fan \($0) peak 1180 rpm" }
        let flow = PcFlow(spacing: 14) { ForEach(items, id: \.self) { Text($0).lineLimit(1) } }
        XCTAssertLessThanOrEqual(width(flow, at: 300), 300.5)
        let host = UIHostingController(rootView: flow)
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 300, height: 5000)).height, 40, "wrapped onto more lines")
    }
}
