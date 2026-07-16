import XCTest
import BFFOracle
@testable import SoupScopeCore

final class ScaffoldInfoTests: XCTestCase {

    func testAppNameMatchesArchitectureDoc() {
        XCTAssertEqual(ScaffoldInfo.appName, "SoupScope")
    }

    func testOracleWiringReflectsOracleConstants() {
        XCTAssertTrue(ScaffoldInfo.oracleWiring.contains("\(BFF.tapeSize)"),
                      "wiring string should surface the oracle's tape size")
        XCTAssertTrue(ScaffoldInfo.oracleWiring.contains("\(BFF.stepBudget)"),
                      "wiring string should surface the oracle's step budget")
    }
}
