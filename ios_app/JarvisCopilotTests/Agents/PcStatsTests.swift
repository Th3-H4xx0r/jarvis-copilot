import XCTest
@testable import JarvisCopilot

/// PC Stats on the phone (2026-11-15): the server's shapes decode, the grid reflows into one
/// column top-to-bottom then left-to-right, a one-column order goes back onto the 12-column
/// grid with the same first-free-slot rule as Jarvis's tool, and readings are written as
/// "unavailable" (never 0) when missing, with "est." for estimates.
@MainActor
final class PcStatsTests: XCTestCase {

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    private func w(_ id: String, _ x: Int, _ y: Int, _ ww: Int, _ hh: Int, kind: PcWidgetKind = .number) -> PcWidget {
        PcWidget(id: id, kind: kind, x: x, y: y, w: ww, h: hh, readings: ["cpu.load"])
    }

    private let catalog = PcCatalog(json: [
        "readings": [
            "cpu.load": ["label": "CPU load", "unit": "%", "group": "cpu", "estimated": false],
            "cpu.temp": ["label": "CPU temperature", "unit": "°C", "group": "cpu", "estimated": false],
            "gpu.load": ["label": "GPU load", "unit": "%", "group": "gpu", "estimated": false],
            "ram.used": ["label": "RAM used", "unit": "GB", "group": "memory", "estimated": false],
            "ram.total": ["label": "RAM total", "unit": "GB", "group": "memory", "estimated": false],
            "power.gpu": ["label": "GPU power (model)", "unit": "W", "group": "power", "estimated": false],
            "power.cpu": ["label": "CPU power (model)", "unit": "W", "group": "power", "estimated": false],
            "power.total": ["label": "PC (est.)", "unit": "W", "group": "power", "estimated": true],
            "fps": ["label": "Frame rate", "unit": "fps", "group": "frames", "estimated": false],
        ],
        "widget_kinds": ["hero", "number", "chart", "bars", "ring", "sparkline", "stats", "text", "session", "moments"],
        "columns": 12,
    ])

    // MARK: Decoding

    func testLiveDecodes() {
        let live = PcLive(json: json("""
        {"device_id":"pc-1","name":"PRANAV-PC","online":true,"at":1763200000.5,
         "sample":{"r":{"cpu.load":38,"gpu.load":96.4,"power.total":462.0},"game":"Cyberpunk2077.exe"},
         "estimated":["power.cpu","power.total"]}
        """))
        XCTAssertEqual(live.deviceId, "pc-1")
        XCTAssertEqual(live.name, "PRANAV-PC")
        XCTAssertTrue(live.online)
        XCTAssertTrue(live.hasSample)
        XCTAssertEqual(live.at, Date(timeIntervalSince1970: 1763200000.5))
        XCTAssertEqual(live.values["cpu.load"], 38)
        XCTAssertEqual(live.values["gpu.load"], 96.4)
        XCTAssertEqual(live.game, "Cyberpunk2077.exe")
        XCTAssertEqual(live.estimated, ["power.cpu", "power.total"])
    }

    func testLiveNeverReportedDecodes() {
        let live = PcLive(json: json(#"{"device_id":null,"name":"","online":false,"at":null,"sample":null,"estimated":[]}"#))
        XCTAssertNil(live.deviceId)
        XCTAssertFalse(live.online)
        XCTAssertFalse(live.hasSample)
        XCTAssertNil(live.at)
        XCTAssertTrue(live.values.isEmpty)
        XCTAssertNil(live.game)
    }

    func testSummaryDecodesNullsAsMissing() {
        let s = PcSummary(json: json(#"{"device_id":"pc-1","online":true,"at":1763200000,"cpu":12.5,"gpu":null,"hottest":71,"watts":180.2}"#))
        XCTAssertTrue(s.online)
        XCTAssertEqual(s.cpu, 12.5)
        XCTAssertNil(s.gpu)
        XCTAssertEqual(s.hottest, 71)
        XCTAssertEqual(s.watts, 180.2)
        XCTAssertEqual(s.at, Date(timeIntervalSince1970: 1763200000))
    }

    func testSummaryCardShowsEachTempBesideItsUsage() {
        let s = PcSummary(json: json(#"{"online":true,"at":1,"cpu":38,"gpu":96.4,"cpu_temp":71.6,"gpu_temp":67,"hottest":72,"watts":462}"#))
        XCTAssertEqual(s.cpuTemp, 71.6)
        XCTAssertEqual(s.gpuTemp, 67)
        XCTAssertEqual(s.cardMetrics, [.init(label: "CPU", value: "38%", temp: "72°"),
                                       .init(label: "GPU", value: "96%", temp: "67°"),
                                       .init(label: "PC (est.)", value: "462 W", temp: nil)])
        // A missing temperature is left out, not drawn as 0.
        let noCpuTemp = PcSummary(json: json(#"{"online":true,"cpu":5,"gpu":10,"cpu_temp":null,"gpu_temp":40,"watts":null}"#))
        XCTAssertNil(noCpuTemp.cardMetrics[0].temp)
        XCTAssertEqual(noCpuTemp.cardMetrics.last?.value, "—")
        // An older server (no per-part temps) shows the hottest as its own number.
        let old = PcSummary(json: json(#"{"online":true,"cpu":5,"gpu":10,"hottest":61,"watts":90}"#))
        XCTAssertEqual(old.cardMetrics.map(\.label), ["CPU", "GPU", "Hottest", "PC (est.)"])
    }

    func testDashboardsDecodeAndRoundTrip() {
        let list = PcDashboard.list(json("""
        {"dashboards":[{"id":"overview","name":"Overview","auto":null,"rev":3,"widgets":[
          {"id":"gpu","kind":"hero","x":0,"y":0,"w":6,"h":4,"readings":["gpu.load"],
           "style":{"label":"GPU","chart":"area","meta":["gpu.temp","gpu.clock"],"warn":85,"crit":95}},
          {"id":"bad","kind":"nonsense","x":0,"y":4,"w":1,"h":1,"readings":[],"style":{}}]},
         {"id":"gaming","name":"Gaming","auto":"game","rev":1,"widgets":[]}]}
        """))
        XCTAssertEqual(list.map(\.id), ["overview", "gaming"])
        let o = list[0]
        XCTAssertEqual(o.rev, 3)
        XCTAssertNil(o.auto)
        XCTAssertEqual(o.widgets.count, 1, "an unknown kind is skipped, not crashed on")
        let g = o.widgets[0]
        XCTAssertEqual(g.kind, .hero)
        XCTAssertEqual([g.x, g.y, g.w, g.h], [0, 0, 6, 4])
        XCTAssertEqual(g.style.label, "GPU")
        XCTAssertEqual(g.style.chart, .area)
        XCTAssertEqual(g.style.meta, ["gpu.temp", "gpu.clock"])
        XCTAssertEqual(g.style.warn, 85)
        XCTAssertEqual(g.style.crit, 95)
        XCTAssertEqual(list[1].auto, "game")

        // What PUT sends carries no rev and only the style keys that are set.
        let body = o.json
        XCTAssertNil(body["rev"])
        XCTAssertTrue(body["auto"] is NSNull)
        let style = ((body["widgets"] as? [[String: Any]])?.first?["style"] as? [String: Any]) ?? [:]
        XCTAssertEqual(Set(style.keys), ["label", "chart", "meta", "warn", "crit"])
        XCTAssertEqual(PcDashboard(json: body)?.widgets, o.widgets)
    }

    func testHistorySessionsEnergyDecode() {
        let pts = PcPoint.list(json(#"{"points":[[100,50.5,40,61],[110,52,52,52]]}"#))
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[0].avg, 50.5)
        XCTAssertEqual(pts[0].min, 40)
        XCTAssertEqual(pts[0].max, 61)

        let s = PcSession(json: json(#"{"id":"s1","exe":"eldenring.exe","title":"","start":1000,"end":4600,"fps_avg":58.2}"#))
        XCTAssertEqual(s?.name, "eldenring")
        XCTAssertEqual(s?.duration(), 3600)
        XCTAssertEqual(s?.fpsAvg, 58.2)
        XCTAssertNil(s?.energyWh)

        let e = PcEnergy(json: json(#"{"buckets":[{"start":0,"kwh":1.0,"cost":0.15},{"start":86400,"kwh":0.5,"cost":0.075}],"price":0.15,"currency":"EUR"}"#))
        XCTAssertEqual(e.totalKwh, 1.5, accuracy: 1e-9)
        XCTAssertEqual(e.totalCost, 0.225, accuracy: 1e-9)
        XCTAssertEqual(e.currency, "EUR")
    }

    func testSaveResultReadsConflictAndErrors() throws {
        let conflict = try PcStatsClient.saveResult(status: 409, data: Data(#"{"error":"changed elsewhere","dashboard":{"id":"overview","name":"Overview","rev":7,"widgets":[]}}"#.utf8))
        XCTAssertEqual(conflict, .conflict(PcDashboard(id: "overview", name: "Overview", widgets: [], rev: 7)))
        let invalid = try PcStatsClient.saveResult(status: 400, data: Data(#"{"errors":["widget 'a': overlaps 'b'"]}"#.utf8))
        XCTAssertEqual(invalid, .invalid(["widget 'a': overlaps 'b'"]))
        let saved = try PcStatsClient.saveResult(status: 200, data: Data(#"{"dashboard":{"id":"x","name":"X","rev":2,"widgets":[]}}"#.utf8))
        XCTAssertEqual(saved, .saved(PcDashboard(id: "x", name: "X", rev: 2)))
        // 409 from the Power gate (integration off) is an error, not a conflict.
        XCTAssertThrowsError(try PcStatsClient.saveResult(status: 409, data: Data(#"{"error":"PC Stats is off"}"#.utf8)))
    }

    // MARK: Reflow and grid placement

    func testReflowOrdersByRowThenColumn() {
        let widgets = [w("power", 0, 4, 4, 4), w("frames", 9, 0, 3, 4), w("gpu", 0, 0, 6, 4),
                       w("cooling", 8, 4, 4, 4), w("cpu", 6, 0, 3, 4), w("memory", 4, 4, 4, 4)]
        XCTAssertEqual(PcLayout.reflow(widgets).map(\.id), ["gpu", "cpu", "frames", "power", "memory", "cooling"])
    }

    func testFreeSlotMatchesTheToolsRule() {
        // tools/pc_stats_tool.py _free_slot: first (x, y) row by row where it fits.
        let placed = [w("a", 0, 0, 6, 4), w("b", 6, 0, 3, 2)]
        XCTAssertEqual(PcLayout.freeSlot(placed, w: 3, h: 2).x, 9)
        XCTAssertEqual(PcLayout.freeSlot(placed, w: 3, h: 2).y, 0)
        XCTAssertEqual(PcLayout.freeSlot(placed, w: 6, h: 2).x, 6)
        XCTAssertEqual(PcLayout.freeSlot(placed, w: 6, h: 2).y, 2)
        XCTAssertEqual(PcLayout.freeSlot(placed, w: 12, h: 1).y, 4)
        XCTAssertEqual(PcLayout.freeSlot([], w: 20, h: 1).x, 0, "wider than the grid is clamped to 12")
    }

    func testPlaceKeepsSizesAndOrder() {
        // He moved "power" to the top on the phone.
        let order = [w("power", 0, 4, 4, 4), w("gpu", 0, 0, 6, 4), w("cpu", 6, 0, 3, 4), w("wide", 0, 8, 12, 2), w("tile", 9, 0, 3, 2)]
        let placed = PcLayout.place(order)
        XCTAssertEqual(placed.map { [$0.x, $0.y, $0.w, $0.h] },
                       [[0, 0, 4, 4], [4, 0, 6, 4], [0, 4, 3, 4], [0, 8, 12, 2], [0, 10, 3, 2]])
        XCTAssertEqual(PcLayout.reflow(placed).map(\.id), order.map(\.id), "the grid reads back in his order")
        assertNoOverlap(placed)
    }

    func testCommitKeepsTheGridWhenNothingMoved() {
        let original = [w("gpu", 0, 0, 6, 4), w("cpu", 6, 0, 3, 4), w("tile", 0, 6, 3, 2)]   // a gap at row 4–5
        var edited = PcLayout.reflow(original)
        edited[1].style.label = "Processor"
        let out = PcLayout.commit(original: original, edited: edited)
        XCTAssertEqual(out.map { [$0.x, $0.y] }, [[0, 0], [6, 0], [0, 6]], "positions untouched, gap kept")
        XCTAssertEqual(out[1].style.label, "Processor")
    }

    func testCommitPutsANewWidgetAfterTheLast() {
        let original = [w("gpu", 0, 0, 6, 4), w("cpu", 6, 0, 3, 4)]
        let added = PcWidget(id: "new", kind: .number, w: 3, h: 2, readings: ["fps"])
        let out = PcLayout.commit(original: original, edited: PcLayout.reflow(original) + [added])
        XCTAssertEqual(out.map(\.id), ["gpu", "cpu", "new"])
        XCTAssertEqual([out[2].x, out[2].y], [9, 0])
        assertNoOverlap(out)
    }

    func testCommitReplacesEverythingWhenReordered() {
        let original = [w("gpu", 0, 0, 6, 4), w("cpu", 6, 0, 3, 4), w("fps", 9, 0, 3, 4)]
        let edited = [original[2], original[0], original[1]]
        let out = PcLayout.commit(original: original, edited: edited)
        XCTAssertEqual(PcLayout.reflow(out).map(\.id), ["fps", "gpu", "cpu"])
        XCTAssertEqual(out.map { [$0.w, $0.h] }, [[3, 4], [6, 4], [3, 4]], "each keeps its own size")
        assertNoOverlap(out)
    }

    func testCommitAfterDeleteKeepsTheRest() {
        let original = [w("gpu", 0, 0, 6, 4), w("cpu", 6, 0, 3, 4), w("fps", 9, 0, 3, 4)]
        let out = PcLayout.commit(original: original, edited: [original[0], original[2]])
        XCTAssertEqual(out.map { [$0.x, $0.y] }, [[0, 0], [9, 0]])
    }

    func testPhoneRowsPairSmallTilesOnly() {
        let rows = PcLayout.rows([w("hero", 0, 0, 6, 4, kind: .hero), w("a", 0, 4, 3, 2), w("b", 3, 4, 3, 2),
                                  w("c", 6, 4, 3, 2), w("bars", 0, 6, 4, 4, kind: .bars)])
        XCTAssertEqual(rows.map { $0.map(\.id) }, [["hero"], ["a", "b"], ["c"], ["bars"]])
    }

    func testStackedSmallTilesPairOnThePhone() {
        // Gaming: two rings stacked in one grid column, a stats tile beside them.
        let order = PcLayout.reflow([w("fps", 0, 0, 6, 4, kind: .hero), w("gpu", 6, 0, 2, 2, kind: .ring),
                                     w("perf", 8, 0, 4, 4, kind: .stats), w("cpu", 6, 2, 2, 2, kind: .ring)])
        XCTAssertEqual(PcLayout.rows(order).map { $0.map(\.id) }, [["fps"], ["gpu", "cpu"], ["perf"]])
        XCTAssertEqual(PcCatalog.words("nvme_ssd_samsung_990_pro"), "NVMe SSD Samsung 990 Pro")
        XCTAssertEqual(PcCatalog.words("vrm_mos"), "VRM MOS")
        XCTAssertEqual(PcCatalog.words("system_fan_1"), "System Fan 1")
    }

    func testNewIDs() {
        XCTAssertEqual(PcLayout.newWidgetID(kind: .number, reading: "gpu.temp", taken: ["gpu-temp"]), "gpu-temp-2")
        XCTAssertEqual(PcLayout.newWidgetID(kind: .text, reading: nil, taken: []), "text")
        XCTAssertEqual(PcDashboard.newID(name: "My Racing!", taken: []), "my-racing")
        XCTAssertEqual(PcDashboard.newID(name: "Gaming", taken: ["gaming"], suffix: { "ab12" }), "gaming-ab12")
        XCTAssertEqual(PcDashboard.newID(name: "  ", taken: []), "dashboard")
    }

    func testActiveDashboardFallsBackToFirst() {
        let boards = [PcDashboard(id: "overview", name: "Overview"), PcDashboard(id: "power", name: "Power")]
        XCTAssertEqual(PcStatsPrefs.resolve("power", in: boards)?.id, "power")
        XCTAssertEqual(PcStatsPrefs.resolve("deleted", in: boards)?.id, "overview")
        XCTAssertEqual(PcStatsPrefs.resolve(nil, in: boards)?.id, "overview")
        XCTAssertNil(PcStatsPrefs.resolve("x", in: []))
    }

    // MARK: Formatting

    func testMissingReadingIsUnavailableNeverZero() {
        let live = PcLive(json: json(#"{"online":true,"at":1,"sample":{"r":{"cpu.load":0,"gpu.load":0.0}},"estimated":[]}"#))
        XCTAssertEqual(PcFormat.value("cpu.load", live: live, catalog: catalog), .value("0", unit: "%"),
                       "a real 0 is shown as 0")
        XCTAssertEqual(PcFormat.value("cpu.temp", live: live, catalog: catalog), .unavailable("Needs the sensor driver"))
        XCTAssertEqual(PcFormat.value("fps", live: live, catalog: catalog), .unavailable("No game running"))
        XCTAssertEqual(PcFormat.value("ram.used", live: live, catalog: catalog), .unavailable("Unavailable"))
        XCTAssertEqual(PcFormat.value("cpu.load", live: .none, catalog: catalog), .unavailable("No data yet"))
        XCTAssertEqual(PcFormat.value(nil, live: live, catalog: catalog), .unavailable("No reading chosen"))
        XCTAssertEqual(PcFormat.compact(nil, unit: "%"), "—")
        XCTAssertEqual(PcFormat.compact(0, unit: "%"), "0%")
    }

    func testNumbersUnitsAndDecimals() {
        let live = PcLive(json: json(#"{"online":true,"at":1,"sample":{"r":{"ram.used":21.43,"cpu.temp":71.6,"power.total":462.4}},"estimated":[]}"#))
        XCTAssertEqual(PcFormat.value("ram.used", live: live, catalog: catalog), .value("21.4", unit: "GB"))
        XCTAssertEqual(PcFormat.value("cpu.temp", live: live, catalog: catalog), .value("72", unit: "°"))
        XCTAssertEqual(PcFormat.value("power.total", live: live, catalog: catalog), .value("462", unit: "W"))
        XCTAssertEqual(PcFormat.value("cpu.temp", live: live, catalog: catalog, style: PcWidgetStyle(decimals: 1)),
                       .value("71.6", unit: "°"))
        XCTAssertEqual(PcFormat.compact(71.6, unit: "°C"), "72°")
        XCTAssertEqual(PcFormat.compact(462.4, unit: "W"), "462 W")
        XCTAssertEqual(PcFormat.number(-0.2, unit: "W"), "0", "no negative zero")
    }

    func testEstimatedBadge() {
        let live = PcLive(json: json(#"{"online":true,"at":1,"sample":{"r":{"power.cpu":40}},"estimated":["power.cpu"]}"#))
        XCTAssertTrue(PcFormat.isEstimated("power.cpu", live: live, catalog: catalog), "the PC said so")
        XCTAssertTrue(PcFormat.isEstimated("power.total", live: live, catalog: catalog), "the catalog says so")
        XCTAssertFalse(PcFormat.isEstimated("cpu.load", live: live, catalog: catalog))
        XCTAssertFalse(PcFormat.isEstimated(nil, live: live, catalog: catalog))
    }

    func testThresholdTone() {
        let style = PcWidgetStyle(warn: 85, crit: 95)
        XCTAssertEqual(PcFormat.tone(70, style: style), .normal)
        XCTAssertEqual(PcFormat.tone(85, style: style), .warn)
        XCTAssertEqual(PcFormat.tone(99, style: style), .crit)
        XCTAssertEqual(PcFormat.tone(nil, style: style), .normal)
    }

    func testBarFractions() {
        let v: [String: Double] = ["power.gpu": 312, "power.cpu": 118, "power.total": 462, "ram.used": 16, "ram.total": 32,
                                   "cpu.load": 38]
        let power = ["power.gpu", "power.cpu"]
        XCTAssertEqual(PcFormat.barFraction("power.gpu", values: v, peers: power, catalog: catalog), 312 / 462, accuracy: 1e-9)
        XCTAssertEqual(PcFormat.barFraction("ram.used", values: v, peers: ["ram.used"], catalog: catalog), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PcFormat.barFraction("cpu.load", values: v, peers: [], catalog: catalog), 0.38, accuracy: 1e-9)
        XCTAssertEqual(PcFormat.barFraction("cpu.temp", values: v, peers: [], catalog: catalog), 0, "missing → empty bar")
        XCTAssertEqual(PcFormat.barValue("ram.used", values: v, catalog: catalog, style: PcWidgetStyle()), "50%")
    }

    func testLoadHeroLiftsItsTemperatureBesideTheUsage() {
        let gpu = PcWidget(id: "gpu", kind: .hero, w: 6, h: 4, readings: ["gpu.load"],
                           style: PcWidgetStyle(meta: ["gpu.temp", "gpu.clock", "gpu.power"]))
        XCTAssertEqual(PcFormat.heroTemperature(gpu), "gpu.temp")
        XCTAssertEqual(PcFormat.heroMeta(gpu), ["gpu.clock", "gpu.power"], "dropped from the small meta row")
        let style = PcFormat.heroTemperatureStyle(gpu, key: "gpu.temp")
        XCTAssertEqual([style.warn, style.crit], [85, 95], "GPU defaults when the widget sets none")
        XCTAssertEqual(PcFormat.tone(88, style: style), .warn)
        XCTAssertEqual(PcFormat.tone(96, style: style), .crit)

        let live = PcLive(json: json(#"{"online":true,"at":1,"sample":{"r":{"gpu.temp":66.7}},"estimated":[]}"#))
        XCTAssertEqual(PcFormat.heroTemperatureValue("gpu.temp", live: live), .value("67", unit: "°"), "inline °")
        XCTAssertEqual(PcFormat.heroTemperatureValue("cpu.temp", live: live), .unavailable("Needs the sensor driver"))

        let cpu = PcWidget(id: "cpu", kind: .hero, w: 3, h: 4, readings: ["cpu.load"],
                           style: PcWidgetStyle(warn: 80, meta: ["cpu.clock", "temp.package"]))
        XCTAssertEqual(PcFormat.heroTemperature(cpu), "temp.package")
        XCTAssertEqual(PcFormat.heroTemperatureStyle(cpu, key: "cpu.temp").warn, 80, "the widget's own threshold wins")

        let fps = PcWidget(id: "f", kind: .hero, w: 3, h: 4, readings: ["fps"], style: PcWidgetStyle(meta: ["gpu.temp"]))
        XCTAssertNil(PcFormat.heroTemperature(fps), "only a load hero")
        XCTAssertEqual(PcFormat.heroMeta(fps), ["gpu.temp"])
        let number = PcWidget(id: "n", kind: .number, w: 3, h: 2, readings: ["gpu.load"], style: PcWidgetStyle(meta: ["gpu.temp"]))
        XCTAssertNil(PcFormat.heroTemperature(number))
    }

    func testDynamicReadingsResolveLikeTheServer() {
        XCTAssertEqual(catalog.info("fan.cpu_fan")?.label, "CPU Fan", "acronyms stay in capitals")
        XCTAssertEqual(catalog.info("fan.cpu_fan")?.unit, "rpm")
        XCTAssertEqual(catalog.info("temp.vrm")?.unit, "°C")
        XCTAssertNil(catalog.info("fan.Bad-Name"))
        XCTAssertNil(catalog.info("nope"))
        let groups = catalog.grouped(extraKeys: ["fan.pump"]).map(\.group)
        XCTAssertEqual(groups.first, "cpu")
        XCTAssertTrue(groups.contains("cooling"))
    }

    func testStatusWords() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(PcStatsCopy.status(online: true, at: now, now: now), "Online")
        XCTAssertEqual(PcStatsCopy.status(online: true, at: now, game: "Elden Ring", now: now), "Online · Playing Elden Ring")
        XCTAssertEqual(PcStatsCopy.status(online: false, at: now.addingTimeInterval(-300), now: now),
                       "PC offline · last seen 5 min ago")
        XCTAssertEqual(PcStatsCopy.status(online: false, at: nil, now: now), "No stats from this PC yet")
        XCTAssertEqual(PcStatsCopy.window(300), "5 min")
        XCTAssertEqual(PcStatsCopy.window(86_400), "24 h")
    }

    func testRangeWindows() {
        let chart = PcWidget(id: "c", kind: .chart, w: 6, h: 4, readings: ["fps"], style: PcWidgetStyle(window: 3600))
        let hero = PcWidget(id: "h", kind: .hero, w: 6, h: 4, readings: ["fps"])
        XCTAssertEqual(PcRange.live.window(for: chart), 3600)
        XCTAssertEqual(PcRange.live.window(for: hero), PcLayout.liveWindow)
        XCTAssertEqual(PcRange.day.window(for: chart), 86_400)
    }

    func testChartGapsBreakTheLine() {
        let pts = [0, 10, 20, 30, 400, 410].map { PcPoint(t: Double($0), avg: 1) }
        let segs = PcChartScale.segments(pts, span: PcTimeSpan(from: 0, to: 420))
        XCTAssertEqual(segs.map(\.count), [4, 2])
        XCTAssertEqual(PcChartScale.range([10, 50], unit: "%"), 0...100)
    }

    // MARK: Apple look: chart maths and categories

    func testCentredMovingAverageSmoothsSpikes() {
        let raw = [10, 10, 10, 60, 10, 10, 10].enumerated().map { PcPoint(t: Double($0.offset), avg: Double($0.element)) }
        let s = PcChartMath.smooth(raw, radius: 2)
        XCTAssertEqual(s.count, raw.count)
        XCTAssertEqual(s[3].avg, 20, accuracy: 1e-9, "the spike is spread over 5 samples")
        XCTAssertEqual(s[0].avg, 10, accuracy: 1e-9, "edges average what's there")
        XCTAssertEqual(s[1].avg, 90.0 / 4, accuracy: 1e-9, "samples 0…3")
        XCTAssertEqual(s.map(\.t), raw.map(\.t), "times untouched")
        XCTAssertEqual(s[3].max, 60, "min/max stay raw")
        XCTAssertEqual(PcChartMath.smooth(Array(raw.prefix(2))), Array(raw.prefix(2)), "too short to smooth")
        XCTAssertEqual(PcChartMath.smooth(raw, radius: 0), raw)
    }

    func testSmoothingWidensForLongSeries() {
        XCTAssertEqual(PcChartMath.smoothingRadius(count: 60), 2, "≈ 5 samples at 1 Hz")
        XCTAssertGreaterThan(PcChartMath.smoothingRadius(count: 1200), 2)
        XCTAssertLessThanOrEqual(PcChartMath.smoothingRadius(count: 100_000), 24)
    }

    func testYRangeIgnoresASingleSpike() {
        XCTAssertEqual(PcChartMath.yRange([3, 99], unit: "%"), 0...100)
        var watts = Array(repeating: 200.0, count: 99)
        watts.append(2000)
        let r = PcChartMath.yRange(watts, unit: "W")
        XCTAssertEqual(r.lowerBound, 0)
        XCTAssertEqual(r.upperBound, 230, accuracy: 1e-9, "p98 × 1.15, not the spike")
        let temps = PcChartMath.yRange([62, 66, 71], unit: "°C")
        XCTAssertEqual(temps.lowerBound, 50, "a floor in tens under the lowest")
        XCTAssertEqual(temps.upperBound, 71 * 1.15, accuracy: 1e-9)
        XCTAssertEqual(PcChartMath.yRange([], unit: "W"), 0...1)
        XCTAssertEqual(PcChartMath.yRange([0, 0], unit: "MB/s"), 0...1, "never a zero-height range")
        XCTAssertEqual(PcChartMath.percentile([1, 2, 3, 4, 5], 0.5), 3)
        XCTAssertEqual(PcChartMath.gridlines(0...100), [0, 50, 100])
    }

    func testStatLine() {
        let pts = [58.0, 66, 74].enumerated().map { PcPoint(t: Double($0.offset), avg: $0.element) }
        XCTAssertEqual(PcChartMath.statLine(pts, unit: "°C"), "Min 58 · Avg 66 · Max 74")
        XCTAssertNil(PcChartMath.statLine([], unit: "°C"))
    }

    func testCategoryTints() {
        XCTAssertEqual(PcCategory.of("gpu.load"), .gpu)
        XCTAssertEqual(PcCategory.of("gpu.vram_used"), .memory)
        XCTAssertEqual(PcCategory.of("gpu.fan"), .cooling)
        XCTAssertEqual(PcCategory.of("gpu.temp"), .temps)
        XCTAssertEqual(PcCategory.of("temp.vrm"), .temps)
        XCTAssertEqual(PcCategory.of("cpu.clock"), .cpu)
        XCTAssertEqual(PcCategory.of("fps.low1"), .frames)
        XCTAssertEqual(PcCategory.of("frametime"), .frames)
        XCTAssertEqual(PcCategory.of("power.total"), .power)
        XCTAssertEqual(PcCategory.of("ram.used"), .memory)
        XCTAssertEqual(PcCategory.of("net.down"), .network)
        XCTAssertEqual(PcCategory.of("fan.pump"), .cooling)
        XCTAssertEqual(PcCategory.of(nil), .other)
        // Colour inside the data: each line its group; a part's temperature takes the part's colour
        // among several lines; a same-group second line at 55 %.
        let temps = PcCategory.seriesShades(["gpu.temp", "cpu.temp"])
        XCTAssertEqual(temps.map(\.category), [.gpu, .cpu])
        XCTAssertEqual(PcCategory.seriesShades(["gpu.temp"]).map(\.category), [.temps], "a single temperature is a temperature")
        let net = PcCategory.seriesShades(["net.down", "net.up"])
        XCTAssertEqual(net.map(\.category), [.network, .network])
        XCTAssertEqual(net.map(\.opacity), [1, 0.55])
        XCTAssertEqual(PcCategory.seriesShades(["power.total", "power.gpu", "power.cpu"]).map(\.opacity), [1, 0.55, 0.30])
        XCTAssertEqual(PcCategory.gpu.symbol, "display")
    }

    // MARK: Denser dashboards: wildcards and stats tiles

    func testWildcardsExpandToThePCsOwnKeysSorted() {
        let live = PcLive(json: json(#"{"online":true,"at":1,"sample":{"r":{"cpu.temp":70,"temp.vrm":55,"temp.chipset":48,"fan.fan_2":900,"fan.fan_1":1200,"gpu.fan":1600}},"estimated":[]}"#))
        XCTAssertEqual(PcFormat.expand(["cpu.temp", "gpu.temp", "gpu.hotspot", "temp.*"], live: live),
                       ["cpu.temp", "gpu.temp", "gpu.hotspot", "temp.chipset", "temp.vrm"])
        XCTAssertEqual(PcFormat.expand(["gpu.fan", "fan.*"], live: live), ["gpu.fan", "fan.fan_1", "fan.fan_2"])
        XCTAssertEqual(PcFormat.expand(["temp.vrm", "temp.*"], live: live), ["temp.vrm", "temp.chipset"],
                       "a key named outright isn't repeated")
        XCTAssertEqual(PcFormat.expand(["fan.*"], live: .none), [], "nothing reported yet")
        XCTAssertEqual(catalog.info("fan.fan_1")?.label, "Fan 1", "dynamic keys read as words")
        XCTAssertEqual(PcFormat.shortLabel("temp.chipset", catalog: catalog), "Chipset")
        XCTAssertEqual(catalog.info("temp.*")?.label, "All temperatures")
        XCTAssertTrue(catalog.grouped().contains { g in g.readings.contains { $0.key == "fan.*" } }, "offered in the library")
    }

    func testStatsCellFormatting() {
        let live = PcLive(json: json(#"{"online":true,"at":1,"sample":{"r":{"cpu.temp":71.6,"cpu.clock":5400,"ram.used":21.43,"fan.fan_1":1180}},"estimated":[]}"#))
        XCTAssertEqual(PcFormat.statsCell("cpu.temp", live: live, catalog: catalog),
                       .init(label: "CPU temperature", value: "72°", unit: ""), "temps carry ° inline")
        XCTAssertEqual(PcFormat.statsCell("ram.used", live: live, catalog: catalog),
                       .init(label: "RAM used", value: "21.4", unit: "GB"))
        XCTAssertEqual(PcFormat.statsCell("fan.fan_1", live: live, catalog: catalog),
                       .init(label: "Fan 1", value: "1180", unit: "rpm"))
        XCTAssertEqual(PcFormat.statsCell("gpu.load", live: live, catalog: catalog),
                       .init(label: "GPU load", value: "—", unit: ""), "missing is a dash, never 0")
        XCTAssertEqual(PcFormat.statsCell("cpu.temp", live: live, catalog: catalog, style: PcWidgetStyle(decimals: 1)).value, "71.6°")
        XCTAssertTrue(PcWidgetKind.stats.multiReading)
        XCTAssertTrue(PcWidgetKind.stats.hasChart)
        XCTAssertEqual(PcLayout.rows([PcWidget(id: "s", kind: .stats, w: 3, h: 2), w("a", 3, 0, 3, 2)]).map { $0.map(\.id) },
                       [["s"], ["a"]], "a stats tile is full width")
    }

    private func assertNoOverlap(_ widgets: [PcWidget], file: StaticString = #filePath, line: UInt = #line) {
        var cells = Set<Int>()
        for wd in widgets {
            XCTAssertLessThanOrEqual(wd.x + wd.w, 12, file: file, line: line)
            for cx in wd.x..<(wd.x + wd.w) {
                for cy in wd.y..<(wd.y + wd.h) {
                    XCTAssertTrue(cells.insert(cy * 12 + cx).inserted, "\(wd.id) overlaps at \(cx),\(cy)", file: file, line: line)
                }
            }
        }
    }
}
