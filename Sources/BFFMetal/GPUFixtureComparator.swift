import BFFOracle

/// What one GPU thread produced for one interaction, decoded off the shared
/// buffers into plain host values. Field meanings are `BFFEvalResult`'s
/// (BFFShared.h); `finalTape` is the thread's 128-byte tape slice after the run.
public struct GPUPairOutcome: Equatable, Sendable {
    public var finalTape: [UInt8]
    public var steps: UInt32
    public var noopSteps: UInt32
    public var copyWrites: UInt32
    public var loopOps: UInt32
    public var halt: UInt32

    public init(finalTape: [UInt8], steps: UInt32, noopSteps: UInt32,
                copyWrites: UInt32, loopOps: UInt32, halt: UInt32) {
        self.finalTape = finalTape
        self.steps = steps
        self.noopSteps = noopSteps
        self.copyWrites = copyWrites
        self.loopOps = loopOps
        self.halt = halt
    }

    /// cubff's observable evaluator op count (the fixtures' `expectedOps`):
    /// budgeted steps minus executed null/non-command no-ops.
    public var commandSteps: Int { Int(steps) - Int(noopSteps) }
}

/// Parity checking for one fixture case, platform-independent so the diagnostics
/// are unit-testable on Linux with simulated GPU outcomes.
public enum GPUFixtureComparator {

    /// Compare a GPU outcome against BOTH semantic anchors:
    ///
    /// 1. The committed cubff fixture — final tape and cubff op count, the two
    ///    observables genuinely produced by the pinned upstream evaluator.
    /// 2. The CPU oracle's normative `.dynamicScan` run — the full accounting
    ///    (`steps`, `noopSteps`, `copyWrites`, `loopOps`, halt reason) that cubff
    ///    does not expose but 01 §3 defines and the GPU must share with the host.
    ///
    /// Returns one line per divergence, each prefixed with the fixture name;
    /// empty means exact parity.
    public static func compare(fixtureCase c: CubffFixtureFile.Case,
                               gpu: GPUPairOutcome) -> [String] {
        guard let variant = c.oracleVariant else {
            return ["\(c.name): unknown variant '\(c.variant)'"]
        }
        guard let input = c.inputTape, input.count == BFF.pairTapeSize else {
            return ["\(c.name): undecodable or wrong-size input tape"]
        }
        guard let expected = c.expectedTape, expected.count == BFF.pairTapeSize else {
            return ["\(c.name): undecodable or wrong-size expected tape"]
        }
        guard gpu.finalTape.count == BFF.pairTapeSize else {
            return ["\(c.name): GPU final tape is \(gpu.finalTape.count) bytes, "
                    + "expected \(BFF.pairTapeSize)"]
        }

        var issues: [String] = []

        // Anchor 1: the cubff fixture.
        if gpu.finalTape != expected {
            let first = (0..<BFF.pairTapeSize).first { gpu.finalTape[$0] != expected[$0] }!
            let count = (0..<BFF.pairTapeSize).count { gpu.finalTape[$0] != expected[$0] }
            issues.append("\(c.name): final tape diverges from cubff fixture at "
                          + "\(count) byte(s), first at index \(first): "
                          + "gpu 0x\(hex(gpu.finalTape[first])) "
                          + "vs cubff 0x\(hex(expected[first]))")
        }
        if gpu.commandSteps != c.expectedOps {
            issues.append("\(c.name): op count diverges from cubff fixture: "
                          + "gpu \(gpu.commandSteps) (steps \(gpu.steps) - "
                          + "noops \(gpu.noopSteps)) vs cubff \(c.expectedOps)")
        }

        // Anchor 2: the CPU oracle's full accounting under identical inputs.
        let oracle = BFFInterpreter.run(pairTape: input, variant: variant,
                                        bracketMode: .dynamicScan,
                                        stepBudget: c.stepBudget)
        if gpu.finalTape != oracle.tape {
            let first = (0..<BFF.pairTapeSize).first { gpu.finalTape[$0] != oracle.tape[$0] }!
            issues.append("\(c.name): final tape diverges from CPU oracle, first at "
                          + "index \(first): gpu 0x\(hex(gpu.finalTape[first])) "
                          + "vs oracle 0x\(hex(oracle.tape[first]))")
        }
        if Int(gpu.steps) != oracle.steps {
            issues.append("\(c.name): budgeted steps diverge: gpu \(gpu.steps) "
                          + "vs oracle \(oracle.steps)")
        }
        if Int(gpu.noopSteps) != oracle.noopSteps {
            issues.append("\(c.name): no-op steps diverge: gpu \(gpu.noopSteps) "
                          + "vs oracle \(oracle.noopSteps)")
        }
        if Int(gpu.copyWrites) != oracle.copyWrites {
            issues.append("\(c.name): copyWrites diverge: gpu \(gpu.copyWrites) "
                          + "vs oracle \(oracle.copyWrites)")
        }
        if Int(gpu.loopOps) != oracle.loopOps {
            issues.append("\(c.name): loopOps diverge: gpu \(gpu.loopOps) "
                          + "vs oracle \(oracle.loopOps)")
        }
        if gpu.halt != UInt32(oracle.halt.rawValue) {
            issues.append("\(c.name): halt reason diverges: gpu \(gpu.halt) "
                          + "vs oracle \(oracle.halt.rawValue) (\(oracle.halt))")
        }
        return issues
    }

    static func hex(_ byte: UInt8) -> String {
        String(byte, radix: 16)
    }
}

/// Outcome of a full fixture-file parity run.
public struct ParityRunReport: Sendable {
    public struct CaseResult: Sendable {
        public var name: String
        public var issues: [String]
        public init(name: String, issues: [String]) {
            self.name = name
            self.issues = issues
        }
    }

    /// One entry per case actually dispatched, in fixture-file order.
    public var caseResults: [CaseResult]
    /// Planner issues: cases that could not be dispatched at all.
    public var planningIssues: [String]
    /// Number of GPU dispatches the plan required.
    public var dispatchCount: Int
    /// Metal device the run executed on.
    public var deviceName: String

    public init(caseResults: [CaseResult], planningIssues: [String],
                dispatchCount: Int, deviceName: String) {
        self.caseResults = caseResults
        self.planningIssues = planningIssues
        self.dispatchCount = dispatchCount
        self.deviceName = deviceName
    }

    public var failedCases: [CaseResult] { caseResults.filter { !$0.issues.isEmpty } }
    /// True only when every case dispatched and every observable matched.
    public var allPassed: Bool { planningIssues.isEmpty && failedCases.isEmpty }

    /// Human-readable report, one finding per line.
    public func summaryLines() -> [String] {
        var lines: [String] = []
        lines.append("device: \(deviceName)")
        lines.append("dispatches: \(dispatchCount), cases: \(caseResults.count), "
                     + "failed: \(failedCases.count), unplannable: \(planningIssues.count)")
        lines.append(contentsOf: planningIssues.map { "PLAN  \($0)" })
        for c in failedCases {
            lines.append(contentsOf: c.issues.map { "FAIL  \($0)" })
        }
        lines.append(allPassed
            ? "PASS: GPU matches cubff fixtures and CPU oracle on all "
              + "\(caseResults.count) cases"
            : "FAIL: \(failedCases.count) case(s) diverged, "
              + "\(planningIssues.count) unplannable")
        return lines
    }
}
