import XCTest
@testable import JarvisCopilot

final class PcBuiltForTests: XCTestCase {
    private func specs(board: String = "B760M-C", gpu: String = "NVIDIA GeForce RTX 5070", sticks: Int = 2) -> PcSpecs {
        PcSpecs(readAt: 1, cpu: nil, gpus: [.init(name: gpu, vramMb: 12227, driver: nil)],
                board: .init(maker: "ASRock", product: board, bios: nil),
                memory: .init(totalMb: 16384 * sticks, modules: Array(repeating: .init(maker: "Team Group Inc", part: "UD5-6400", sizeMb: 16384, mhz: 6400), count: sticks)),
                storage: nil, displays: nil, os: nil, system: nil)
    }

    func testTheModelMatchesThisPC() {
        XCTAssertEqual(PcBuiltFor.outOfDate(specs()), false)
    }

    func testAGPUSwapMakesItOutOfDate() {
        XCTAssertEqual(PcBuiltFor.outOfDate(specs(gpu: "NVIDIA GeForce RTX 5080")), true)
    }

    func testMoreRAMSticksMakesItOutOfDate() {
        XCTAssertEqual(PcBuiltFor.outOfDate(specs(sticks: 4)), true)
    }

    func testNoSpecsSaysNothing() {
        XCTAssertNil(PcBuiltFor.outOfDate(nil))
    }
}
