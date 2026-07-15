import XCTest
import Foundation
@testable import BFFOracle

final class FixtureTests: XCTestCase {

    private func makeSimulation(epochs: Int = 2) -> Simulation {
        var sim = Simulation(config: SimulationConfig(
            seed: 7, populationSize: 8, stepBudget: 256,
            mutationP32: BFF.defaultMutationP32,
            variant: .noheads, bracketMode: .dynamicScan))
        sim.run(epochs: epochs)
        return sim
    }

    func testEncodeDecodeRoundTrip() throws {
        let sim = makeSimulation()
        let fixture = GoldenFixture(capturing: sim, source: "oracle",
                                    commandLine: "unit-test")
        let data = try fixture.jsonData()
        let decoded = try GoldenFixture.decode(from: data)
        XCTAssertEqual(decoded, fixture)
        XCTAssertEqual(try decoded.soupBytes(), sim.soup)
        XCTAssertEqual(decoded.rngContract, BFFRandom.contractID)
        XCTAssertEqual(decoded.checkpointEpoch, 2)
        XCTAssertEqual(decoded.histogram, sim.histogram().bins)
        XCTAssertEqual(decoded.expectedStats, sim.lastEpochStats)
    }

    func testUnsupportedFormatVersionIsRejected() throws {
        var fixture = GoldenFixture(capturing: makeSimulation(), source: "oracle")
        fixture.formatVersion = 999
        let data = try fixture.jsonData()
        XCTAssertThrowsError(try GoldenFixture.decode(from: data)) { error in
            XCTAssertEqual(error as? GoldenFixture.FixtureError,
                           .unsupportedFormatVersion(999))
        }
    }

    func testReplayReproducesFixture() {
        let fixture = GoldenFixture(capturing: makeSimulation(), source: "oracle")
        let result = FixtureComparator.replayAndCompare(fixture: fixture)
        XCTAssertTrue(result.matches, "issues: \(result.issues)")
        XCTAssertEqual(result.soupByteMismatchCount, 0)
        XCTAssertNil(result.firstSoupMismatchIndex)
        XCTAssertTrue(result.histogramMismatchValues.isEmpty)
    }

    func testMismatchIsDetectedAndLocated() throws {
        let sim = makeSimulation()
        var fixture = GoldenFixture(capturing: sim, source: "oracle")

        // Corrupt one soup byte (to a guaranteed-different value), re-encode, and
        // keep the fixture's histogram consistent with its corrupted soup so both
        // the byte diff and the histogram diff paths are exercised.
        var soup = try fixture.soupBytes()
        let index = 100
        soup[index] &+= 1
        fixture.soupBase64 = Data(soup).base64EncodedString()
        fixture.histogram = ByteHistogram(bytes: soup).bins

        let result = FixtureComparator.compare(
            fixture: fixture, soup: sim.soup,
            histogram: sim.histogram(), stats: sim.lastEpochStats)
        XCTAssertFalse(result.matches)
        XCTAssertEqual(result.soupByteMismatchCount, 1)
        XCTAssertEqual(result.firstSoupMismatchIndex, index)
        XCTAssertFalse(result.histogramMismatchValues.isEmpty,
                       "a single-byte change must shift two histogram bins")
        XCTAssertEqual(result.histogramMismatchValues.count, 2)
        XCTAssertFalse(result.issues.isEmpty)
    }

    func testStatsMismatchIsReported() {
        let sim = makeSimulation()
        var fixture = GoldenFixture(capturing: sim, source: "oracle")
        fixture.expectedStats?.totalSteps += 1

        let result = FixtureComparator.compare(
            fixture: fixture, soup: sim.soup,
            histogram: sim.histogram(), stats: sim.lastEpochStats)
        XCTAssertFalse(result.matches)
        XCTAssertEqual(result.soupByteMismatchCount, 0)
        XCTAssertTrue(result.issues.contains { $0.contains("stats") })
    }

    func testForeignRNGContractIsIncomparableNotMismatching() {
        var fixture = GoldenFixture(capturing: makeSimulation(), source: "cubff@deadbeef")
        fixture.rngContract = "cubff-compat-v0"
        let result = FixtureComparator.replayAndCompare(fixture: fixture)
        XCTAssertFalse(result.matches)
        XCTAssertTrue(result.issues.contains { $0.contains("RNG contract") })
        XCTAssertEqual(result.soupByteMismatchCount, 0,
                       "no byte diff is attempted across RNG contracts")
    }

    func testCorruptBase64IsReported() {
        var fixture = GoldenFixture(capturing: makeSimulation(), source: "oracle")
        fixture.soupBase64 = "not-base64!!!"
        XCTAssertThrowsError(try fixture.soupBytes())
        let sim = makeSimulation()
        let result = FixtureComparator.compare(
            fixture: fixture, soup: sim.soup, histogram: sim.histogram())
        XCTAssertFalse(result.matches)
        XCTAssertTrue(result.issues.contains { $0.contains("undecodable") })
    }

    func testFileRoundTrip() throws {
        let fixture = GoldenFixture(capturing: makeSimulation(), source: "oracle")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bff-fixture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.write(to: url)
        let loaded = try GoldenFixture.load(from: url)
        XCTAssertEqual(loaded, fixture)
    }
}
