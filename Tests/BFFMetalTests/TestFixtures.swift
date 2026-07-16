import Foundation
import BFFOracle

/// Builds in-memory `CubffFixtureFile` values for unit tests. BFFOracle's
/// fixture types are decode-only outside their module (their memberwise inits
/// are internal, on purpose — real fixtures come from the generator), so tests
/// construct them the same way production does: by decoding JSON.
enum TestFixtures {

    struct CaseSpec {
        var name = "case"
        var variant = "bff_noheads"
        var stepBudget = 8192
        var inputHex = String(repeating: "00", count: 128)
        var expectedHex = String(repeating: "00", count: 128)
        var expectedOps = 0
    }

    static func file(_ specs: [CaseSpec]) throws -> CubffFixtureFile {
        let cases = try specs.map { spec -> String in
            let object: [String: Any] = [
                "name": spec.name,
                "variant": spec.variant,
                "stepBudget": spec.stepBudget,
                "inputTapeHex": spec.inputHex,
                "expectedTapeHex": spec.expectedHex,
                "expectedOps": spec.expectedOps,
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        let json = """
        {
          "formatVersion": 1,
          "upstream": {"url": "test", "commit": "test", "sourceFiles": [], "build": "test"},
          "generator": {"command": "test", "version": 1},
          "observables": "test",
          "cases": [\(cases.joined(separator: ","))]
        }
        """
        return try JSONDecoder().decode(CubffFixtureFile.self, from: Data(json.utf8))
    }

    static func singleCase(_ spec: CaseSpec) throws -> CubffFixtureFile.Case {
        try file([spec]).cases[0]
    }
}
