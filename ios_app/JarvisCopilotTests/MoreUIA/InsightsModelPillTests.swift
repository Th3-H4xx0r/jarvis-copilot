import XCTest
@testable import JarvisCopilot

/// The by-model rows showed a bare "—" on every line: the trailing pill is
/// cost, and none of these models carry pricing. Usage is what the screen is
/// for, so the pill falls back to the model's own token count.
final class InsightsModelPillTests: XCTestCase {
    private func stat(cost: Double, tokens: Int) -> ModelStat {
        ModelStat(json: ["model": "gemma4:31b", "sessions": 7,
                         "total_tokens": tokens, "cost": cost])
    }

    func testACostedModelStillShowsItsCost() {
        XCTAssertEqual(InsightsUI.modelPill(stat(cost: 1.25, tokens: 1_100_000)), "$1.25")
    }

    func testAModelWithoutPricingShowsItsTokensInsteadOfADash() {
        let pill = InsightsUI.modelPill(stat(cost: 0, tokens: 1_100_000))
        XCTAssertNotEqual(pill, "—")
        XCTAssertEqual(pill, "1.1M")
    }

    func testAModelWithNeitherCostNorTokensIsHonestlyBlank() {
        XCTAssertEqual(InsightsUI.modelPill(stat(cost: 0, tokens: 0)), "—")
    }
}
