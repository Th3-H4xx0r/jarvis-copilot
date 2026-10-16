import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Settings → Battery usage drawn from a made-up day like Oct 15's, to look at before installing.
@MainActor
final class BatteryUsageRenderTests: XCTestCase {
    func testTheBatteryUsagePageRenders() throws {
        let end = Date(timeIntervalSince1970: 1_792_166_400)   // Oct 16, 11:00 CDT
        var hours: [EnergyLedger.Hour] = []
        var level = 0.95
        for i in 0..<18 {
            let start = end.addingTimeInterval(Double(i - 18) * 3600)
            let onScreen = [3, 6, 15, 16, 17].contains(i)
            let fg = onScreen ? 900.0 : 0
            let lost = onScreen ? 0.06 : 0.012
            var hour = EnergyLedger.Hour(start: start, end: start.addingTimeInterval(3600))
            hour.seconds = ["foreground": fg, "background": 3600 - fg, "bg.keepalive": (3600 - fg) * 0.95,
                            "bg.wifi": i < 14 ? 3600 - fg : 0, "bg.cellular": i >= 14 ? 3600 - fg : 0,
                            "where.chat|": fg * 0.5, "where.devices|Car": fg * 0.3, "where.health|Sleep": fg * 0.2,
                            "link.E910 band": 3600, "bg.link.E910 band": 3600 - fg,
                            "link.Colmi R12": 1800, "bg.link.Colmi R12": 1800]
            hour.cpu = ["foreground": onScreen ? 260 : 0, "background": 22,
                        "where.chat|": onScreen ? 120 : 0, "where.devices|Car": onScreen ? 100 : 0,
                        "where.health|Sleep": onScreen ? 40 : 0]
            hour.counts = ["bridge.in": 90, "bridge.out": 90, "net.Health history": i % 2 == 0 ? 7 : 0,
                           "net.bg.Health history": i % 2 == 0 ? 7 : 0, "bytes.Health history": 90_000,
                           "net.Coding agents": 2, "net.bg.Coding agents": 2, "bytes.Coding agents": 8_000,
                           "net.Chat": onScreen ? 12 : 0, "bytes.Chat": 40_000, "bridge.drop": i == 4 ? 3 : 0]
            hour.threads = ["main": onScreen ? 170 : 14, "com.apple.SwiftUI.AsyncRenderer": onScreen ? 60 : 1,
                            "com.apple.scenekit.scnview-renderer": onScreen ? 22 : 1, "AURemoteIO::IOThread": 1.5]
            hour.batteryStart = level
            level -= lost
            hour.batteryEnd = level
            hours.append(hour)
        }
        let samples = hours.map { EnergyLedger.Sample(at: $0.start, level: $0.batteryStart ?? 0, charging: false) }
        let screens = hours.filter { $0.seconds("foreground") > 0 }
            .map { EnergyLedger.Span(start: $0.start, end: $0.start.addingTimeInterval(900)) }
        let summary = BatteryUsageSummary(hours: hours)

        let page = ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                BatteryHeadline(summary: summary, label: "last 24 hours")
                BatteryLevelChart(samples: samples, screens: screens,
                                  domain: end.addingTimeInterval(-86_400)...end)
                BatteryCPUChart(bars: summary.bars)
                BatteryBreakdown(summary: summary)
            }
            .padding(.horizontal, 20)
        }
        try RenderHarness.write(page, size: CGSize(width: 402, height: 3000), name: "battery-usage")
    }
}
