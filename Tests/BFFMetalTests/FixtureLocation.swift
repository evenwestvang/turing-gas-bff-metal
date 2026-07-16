import Foundation

/// The committed cubff evaluator fixtures are resources of BFFOracleTests
/// (single copy in the repository); this test target reaches them by source
/// location, which is stable for `swift test` from a checkout — the only
/// supported way these tests run.
enum FixtureLocation {
    static var cubffEvaluatorV1: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/BFFMetalTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("BFFOracleTests/Fixtures/cubff-evaluator-v1.json")
    }
}
