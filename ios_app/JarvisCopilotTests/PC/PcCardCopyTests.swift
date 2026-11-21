import XCTest
@testable import JarvisCopilot

final class PcCardCopyTests: XCTestCase {
    private func state(_ effects: [String], on: Bool = true) -> PcLightingState {
        var parts: [String: PcPartLight] = [:]
        for (i, p) in PcPart.allCases.enumerated() {
            parts[p.rawValue] = PcPartLight(effect: effects[min(i, effects.count - 1)], color: "#ffffff", speed: 5)
        }
        return PcLightingState(on: on, brightness: 80, t0: 0, frozenAt: nil, stillInGames: false, rev: 1, parts: parts)
    }

    private let mapped = PcLedMap(version: 1, rev: 1, zones: [], segments: [
        PcSegment(part: "top", index: 0, controller: 0, zone: 0, start: 0, count: 16)])

    func testLightsPillSaysWhatThePCShows() {
        XCTAssertEqual(PcCardCopy.lights(state: state(["rainbow"]), map: mapped, powerOn: true), "Rainbow")
        XCTAssertEqual(PcCardCopy.lights(state: state(["rainbow", "static"]), map: mapped, powerOn: true), "Mixed")
        XCTAssertEqual(PcCardCopy.lights(state: state(["rainbow"], on: false), map: mapped, powerOn: true), "Off")
        XCTAssertEqual(PcCardCopy.lights(state: state(["rainbow"]), map: PcLedMap(), powerOn: true), "Set up")
        XCTAssertNil(PcCardCopy.lights(state: state(["rainbow"]), map: mapped, powerOn: false))
        XCTAssertNil(PcCardCopy.lights(state: nil, map: nil, powerOn: true))
    }

    func testComponentInfoUsesTheRealSpecsAndLiveNumbers() {
        let specs = PcSpecs(readAt: 1, cpu: .init(name: "Intel(R) Core(TM) i7-14700F", cores: 20, threads: 28, maxMhz: 2100),
                            gpus: [.init(name: "NVIDIA GeForce RTX 5070", vramMb: 12227, driver: "32.0.16.2124")],
                            board: .init(maker: "ASRock", product: "B760M-C", bios: "11.02"),
                            memory: .init(totalMb: 32768, modules: [.init(maker: "Team Group Inc", part: "UD5-6400", sizeMb: 16384, mhz: 6400),
                                                                     .init(maker: "Team Group Inc", part: "UD5-6400", sizeMb: 16384, mhz: 6400)]),
                            storage: [], displays: [], os: nil, system: .init(maker: "CyberPowerPC", model: "GamingPC"))
        let live = PcSummary(online: true, at: nil, cpu: 31, gpu: 74, cpuTemp: 58, gpuTemp: 66, hottest: 66, watts: 412)
        let gpu = PcComponentInfo.make("gpu", specs: specs, summary: live)
        XCTAssertEqual(gpu.title, "NVIDIA GeForce RTX 5070")
        XCTAssertTrue(gpu.rows.contains { $0.label == "Load" && $0.value == "74%" })
        XCTAssertTrue(gpu.rows.contains { $0.label == "Memory" && $0.value == "12 GB" })
        let ram = PcComponentInfo.make("ram", specs: specs, summary: live)
        XCTAssertEqual(ram.title, "32 GB memory")
        XCTAssertTrue(ram.rows.contains { $0.value.contains("UD5-6400") })
        let board = PcComponentInfo.make("board", specs: specs, summary: nil)
        XCTAssertEqual(board.title, "ASRock B760M-C")
        let unknown = PcComponentInfo.make("psu", specs: nil, summary: nil)
        XCTAssertEqual(unknown.title, "Power supply")
    }
}
