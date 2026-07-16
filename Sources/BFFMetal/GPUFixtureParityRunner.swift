import BFFOracle

#if canImport(Metal)

/// Drives a full fixture file through the GPU evaluator and checks every case
/// against both semantic anchors (cubff fixture + CPU oracle).
///
/// Pure orchestration: planning lives in `EvaluatorFixturePlanner`, execution in
/// `MetalBFFEvaluator`, checking in `GPUFixtureComparator` — all three usable
/// (and the first and last tested) without a GPU.
public enum GPUFixtureParityRunner {

    public static func run(file: CubffFixtureFile) throws -> ParityRunReport {
        let evaluator = try MetalBFFEvaluator()
        let (groups, planningIssues) = EvaluatorFixturePlanner.plan(for: file)

        // Collect per-case results keyed by fixture index, then emit in file order.
        var byIndex: [Int: ParityRunReport.CaseResult] = [:]
        for group in groups {
            // Planner guarantees decodable 128-byte input tapes for planned cases.
            let tapes = group.caseIndices.map { file.cases[$0].inputTape! }
            let outcomes = try evaluator.evaluate(pairTapes: tapes,
                                                  variant: group.variant,
                                                  stepBudget: group.stepBudget)
            for (slot, caseIndex) in group.caseIndices.enumerated() {
                let c = file.cases[caseIndex]
                let issues = GPUFixtureComparator.compare(fixtureCase: c,
                                                          gpu: outcomes[slot])
                byIndex[caseIndex] = ParityRunReport.CaseResult(name: c.name,
                                                                issues: issues)
            }
        }

        let ordered = byIndex.keys.sorted().map { byIndex[$0]! }
        return ParityRunReport(caseResults: ordered,
                               planningIssues: planningIssues,
                               dispatchCount: groups.count,
                               deviceName: evaluator.deviceName)
    }
}
#endif
