/// The scalar BFF interpreter — the CPU oracle of 02 §10 stage v0.
///
/// Implements the normative step semantics of 01 §3 exactly, in both bracket modes,
/// with the remap-event counter required by the D1 decision procedure (01 §7.3).

public enum BFFInterpreter {

    /// CPU-side sentinel for "no match" in a frozen jump-table entry.
    ///
    /// The GPU's `BFF_JT_UNMATCHED` is `0xFF`: its tables are `uchar`, and valid
    /// match indices are 0...127, so the high half of the byte range is free to
    /// carry the sentinel (02 §5). This table is `[Int]`, so `-1` is the natural
    /// choice. The two encodings are deliberately *different numbers for the same
    /// semantic value* — ports must agree on the predicate "is this entry
    /// unmatched?", never on the raw sentinel bits.
    static let jumpTableUnmatched = -1

    // MARK: - Bracket matching

    /// Normative forward match (01 §3): scan `q = p+1 ... 127` over the *given* tape,
    /// `[` increments depth, `]` at depth 0 is the match. Returns nil if unmatched.
    public static func matchForward(in tape: [UInt8], from p: Int) -> Int? {
        var depth = 0
        var q = p + 1
        while q < tape.count {
            let c = tape[q]
            if c == BFFOp.loopOpen {
                depth += 1
            } else if c == BFFOp.loopClose {
                if depth == 0 { return q }
                depth -= 1
            }
            q += 1
        }
        return nil
    }

    /// Normative backward match: symmetric, scanning `q = p-1 ... 0`.
    public static func matchBackward(in tape: [UInt8], from p: Int) -> Int? {
        var depth = 0
        var q = p - 1
        while q >= 0 {
            let c = tape[q]
            if c == BFFOp.loopClose {
                depth += 1
            } else if c == BFFOp.loopOpen {
                if depth == 0 { return q }
                depth -= 1
            }
            q -= 1
        }
        return nil
    }

    /// Frozen jump table built from the interaction-start tape (02 §5).
    ///
    /// `table[i]` is the match index for a bracket at `i`, or `jumpTableUnmatched`.
    /// Semantic trap, deliberately preserved: entries are only *written* for bytes
    /// that are brackets at build time. A byte that self-modifies *into* a bracket
    /// mid-run reads whatever the table holds at that position. The GPU kernel
    /// leaves such entries as uninitialized garbage ("non-bracket entries are never
    /// read" — untrue under self-modification); the oracle pins them to "unmatched"
    /// so jump-table-mode behavior is at least deterministic. This is one of the
    /// divergence sources the D1 experiment measures.
    public static func buildJumpTable(for tape: [UInt8]) -> [Int] {
        var table = [Int](repeating: jumpTableUnmatched, count: tape.count)
        var stack: [Int] = []
        for i in 0..<tape.count {
            let c = tape[i]
            if c == BFFOp.loopOpen {
                stack.append(i)
            } else if c == BFFOp.loopClose {
                if let open = stack.popLast() {
                    table[open] = i
                    table[i] = open
                } else {
                    table[i] = jumpTableUnmatched
                }
            }
        }
        // Leftover unclosed '[' entries stay unmatched.
        return table
    }

    // MARK: - Interaction execution

    /// Run one interaction on a 128-byte pair tape.
    ///
    /// - Parameters:
    ///   - pairTape: exactly `BFF.pairTapeSize` bytes — `A` in `[0..<64]`, `B` in
    ///     `[64..<128]`. The interpreter never distinguishes the halves; there is no
    ///     protection boundary.
    ///   - variant: initial pc/head state (01 §3).
    ///   - bracketMode: normative `.dynamicScan` or frozen `.jumpTable`.
    ///   - stepBudget: halt with `.budget` when this many ops have executed.
    /// - Returns: final tape plus stats. See `InteractionResult` for the exact
    ///   step-counting convention (matches the GPU kernel, alignment tag 4).
    public static func run(
        pairTape: [UInt8],
        variant: BFFVariant = .noheads,
        bracketMode: BracketMode = .dynamicScan,
        stepBudget: Int = BFF.stepBudget
    ) -> InteractionResult {
        precondition(pairTape.count == BFF.pairTapeSize,
                     "pair tape must be exactly \(BFF.pairTapeSize) bytes")
        precondition(stepBudget > 0, "step budget must be positive")

        var tape = pairTape
        // The frozen table is built unconditionally: jump-table mode consults it;
        // dynamic-scan mode uses it only to count remap events.
        let frozen = buildJumpTable(for: tape)

        var pc: Int
        var h0: Int
        var h1: Int
        switch variant {
        case .noheads:
            pc = 0; h0 = 0; h1 = 0
        case .seededHeads:
            // headpos(b) = b % 128; the first two bytes are consumed as seeds, and
            // execution starts past them (alignment tag 2 — assumed vs cubff).
            h0 = Int(tape[0]) & 127
            h1 = Int(tape[1]) & 127
            pc = 2
        }

        var steps = 0
        var copyWrites = 0
        var loopOps = 0
        var remapEvents = 0
        var halt: HaltReason

        runLoop: while true {
            if steps >= stepBudget { halt = .budget; break }
            if pc < 0 || pc >= BFF.pairTapeSize { halt = .pcOut; break }

            // `unmatchedHalt` is deferred so the halting bracket consumes exactly one
            // step and advances pc once before `.unmatched` is recorded — the canonical
            // rule of 01 §3, mirroring the GPU kernel's load-bearing fall-through to
            // `pc++; steps++` (02 §6). Assumed cubff behavior (alignment tag 4 extended
            // to the unmatched case); still needs golden confirmation.
            var unmatchedHalt = false
            let op = tape[pc]
            switch op {
            case BFFOp.head0Left:  h0 = (h0 &- 1) & 127
            case BFFOp.head0Right: h0 = (h0 &+ 1) & 127
            case BFFOp.head1Left:  h1 = (h1 &- 1) & 127
            case BFFOp.head1Right: h1 = (h1 &+ 1) & 127
            case BFFOp.inc: tape[h0] &+= 1
            case BFFOp.dec: tape[h0] &-= 1
            case BFFOp.write:
                tape[h1] = tape[h0]
                if (h0 >> 6) != (h1 >> 6) { copyWrites += 1 }
            case BFFOp.read:
                tape[h0] = tape[h1]
                if (h0 >> 6) != (h1 >> 6) { copyWrites += 1 }
            case BFFOp.loopOpen:
                loopOps += 1
                if tape[h0] == 0 {
                    let live = matchForward(in: tape, from: pc) ?? jumpTableUnmatched
                    let table = frozen[pc]
                    if live != table { remapEvents += 1 }
                    let target = (bracketMode == .dynamicScan) ? live : table
                    if target == jumpTableUnmatched { unmatchedHalt = true } else { pc = target }
                }
            case BFFOp.loopClose:
                loopOps += 1
                if tape[h0] != 0 {
                    let live = matchBackward(in: tape, from: pc) ?? jumpTableUnmatched
                    let table = frozen[pc]
                    if live != table { remapEvents += 1 }
                    let target = (bracketMode == .dynamicScan) ? live : table
                    if target == jumpTableUnmatched { unmatchedHalt = true } else { pc = target }
                }
            default:
                break // byte 0 and all other data values: no-op
            }
            // Shared advance: a taken `[` landed *on* its `]` and now moves past it;
            // a taken `]` landed *on* its `[` and now re-enters the body without
            // re-executing the `[` (alignment tag 5).
            pc += 1
            steps += 1
            if unmatchedHalt { halt = .unmatched; break runLoop }
        }

        return InteractionResult(
            tape: tape, steps: steps, halt: halt,
            copyWrites: copyWrites, loopOps: loopOps, remapEvents: remapEvents)
    }

    /// Convenience: run a pair of 64-byte programs (concatenated per 01 §3) and
    /// return the result; `result.tape` halves are the written-back programs.
    public static func runPair(
        a: [UInt8],
        b: [UInt8],
        variant: BFFVariant = .noheads,
        bracketMode: BracketMode = .dynamicScan,
        stepBudget: Int = BFF.stepBudget
    ) -> InteractionResult {
        precondition(a.count == BFF.tapeSize && b.count == BFF.tapeSize,
                     "programs must be exactly \(BFF.tapeSize) bytes")
        return run(pairTape: a + b, variant: variant,
                   bracketMode: bracketMode, stepBudget: stepBudget)
    }

    // MARK: - Bracket-mode comparison (D1 instrumentation)

    /// Result of running the same interaction under both bracket strategies.
    public struct BracketModeComparison: Equatable, Sendable {
        public let dynamicScan: InteractionResult
        public let jumpTable: InteractionResult

        /// Index of the first final-tape byte that differs, if any.
        public var firstTapeDivergenceIndex: Int? {
            for i in 0..<dynamicScan.tape.count where dynamicScan.tape[i] != jumpTable.tape[i] {
                return i
            }
            return nil
        }
        public var tapesDiverge: Bool { dynamicScan.tape != jumpTable.tape }
        /// Steps, halt reason, or op counters differ.
        public var statsDiverge: Bool {
            dynamicScan.steps != jumpTable.steps
                || dynamicScan.halt != jumpTable.halt
                || dynamicScan.copyWrites != jumpTable.copyWrites
                || dynamicScan.loopOps != jumpTable.loopOps
        }
        public var diverges: Bool { tapesDiverge || statsDiverge }
    }

    /// Run `pairTape` under both bracket modes and report divergence. This is the
    /// per-interaction building block of the 01 §7.3 experiment.
    public static func compareBracketModes(
        pairTape: [UInt8],
        variant: BFFVariant = .noheads,
        stepBudget: Int = BFF.stepBudget
    ) -> BracketModeComparison {
        BracketModeComparison(
            dynamicScan: run(pairTape: pairTape, variant: variant,
                             bracketMode: .dynamicScan, stepBudget: stepBudget),
            jumpTable: run(pairTape: pairTape, variant: variant,
                           bracketMode: .jumpTable, stepBudget: stepBudget))
    }
}
