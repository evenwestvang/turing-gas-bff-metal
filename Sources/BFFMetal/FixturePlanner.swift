import BFFOracle

/// One GPU dispatch worth of fixture cases. `BFFEvalParams` is dispatch-wide, so
/// a dispatch can carry exactly one (variant, stepBudget) combination; a mixed
/// fixture file becomes several dispatches.
public struct EvaluatorDispatchGroup: Equatable, Sendable {
    public var variant: BFFVariant
    public var stepBudget: Int
    /// Indices into `CubffFixtureFile.cases`, in file order. Thread `i` of the
    /// dispatch evaluates the tape of `cases[caseIndices[i]]`.
    public var caseIndices: [Int]

    public init(variant: BFFVariant, stepBudget: Int, caseIndices: [Int]) {
        self.variant = variant
        self.stepBudget = stepBudget
        self.caseIndices = caseIndices
    }
}

/// Platform-independent dispatch planning for the GPU fixture parity runner —
/// pure data transformation, testable on Linux.
public enum EvaluatorFixturePlanner {

    /// Group every runnable case by (variant, stepBudget), preserving file order
    /// within a group and ordering groups by first appearance.
    ///
    /// A case is runnable when its variant is known, both tapes decode to
    /// exactly 128 bytes, and its budget fits the shared `uint32_t` field and is
    /// positive. Unrunnable cases are reported in `issues` (one line each,
    /// prefixed with the case name) and never silently dropped.
    public static func plan(
        for file: CubffFixtureFile
    ) -> (groups: [EvaluatorDispatchGroup], issues: [String]) {
        struct Key: Hashable {
            let variant: BFFVariant
            let stepBudget: Int
        }
        var order: [Key] = []
        var indices: [Key: [Int]] = [:]
        var issues: [String] = []

        for (i, c) in file.cases.enumerated() {
            guard let variant = c.oracleVariant else {
                issues.append("\(c.name): unknown variant '\(c.variant)'")
                continue
            }
            guard let input = c.inputTape, input.count == BFF.pairTapeSize else {
                issues.append("\(c.name): undecodable or wrong-size input tape")
                continue
            }
            guard let expected = c.expectedTape, expected.count == BFF.pairTapeSize else {
                issues.append("\(c.name): undecodable or wrong-size expected tape")
                continue
            }
            guard c.stepBudget > 0, c.stepBudget <= BFFEvalLayout.maxStepBudget else {
                issues.append("\(c.name): step budget \(c.stepBudget) not representable "
                              + "in the shared uint32 field")
                continue
            }
            let key = Key(variant: variant, stepBudget: c.stepBudget)
            if indices[key] == nil {
                order.append(key)
                indices[key] = []
            }
            indices[key]!.append(i)
        }

        let groups = order.map {
            EvaluatorDispatchGroup(variant: $0.variant, stepBudget: $0.stepBudget,
                                   caseIndices: indices[$0]!)
        }
        return (groups, issues)
    }
}
