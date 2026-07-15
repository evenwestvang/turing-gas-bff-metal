import XCTest
@testable import BFFOracle

/// Build a 128-byte pair tape: `code` bytes from index 0, plus sparse `data` overrides.
private func makeTape(_ code: [UInt8] = [], data: [Int: UInt8] = [:]) -> [UInt8] {
    precondition(code.count <= BFF.pairTapeSize)
    var t = [UInt8](repeating: 0, count: BFF.pairTapeSize)
    t.replaceSubrange(0..<code.count, with: code)
    for (i, v) in data {
        precondition(i >= code.count || code[i] == v, "data overlaps code")
        t[i] = v
    }
    return t
}

private func exec(_ tape: [UInt8],
                 variant: BFFVariant = .noheads,
                 brackets: BracketMode = .dynamicScan,
                 budget: Int = BFF.stepBudget) -> InteractionResult {
    BFFInterpreter.run(pairTape: tape, variant: variant,
                       bracketMode: brackets, stepBudget: budget)
}

final class OpcodeTests: XCTestCase {

    // '>' moves head0 right: the '+' then increments the byte under h0 (itself).
    func testHead0Right() {
        let r = exec(makeTape([BFFOp.head0Right, BFFOp.inc]))
        XCTAssertEqual(r.tape[1], BFFOp.inc &+ 1) // 0x2B -> 0x2C
        XCTAssertEqual(r.halt, .pcOut)
    }

    // '>' '>' '<' nets h0 = 1; '+' increments tape[1] (the second '>').
    func testHead0LeftAfterRight() {
        let r = exec(makeTape([BFFOp.head0Right, BFFOp.head0Right,
                              BFFOp.head0Left, BFFOp.inc]))
        XCTAssertEqual(r.tape[1], BFFOp.head0Right &+ 1) // 0x3E -> 0x3F
    }

    // '}' moves head1; '.' then writes tape[h0]=tape[0] to tape[h1].
    func testHead1RightAndWrite() {
        let r = exec(makeTape([BFFOp.head1Right, BFFOp.head1Right, BFFOp.write]))
        XCTAssertEqual(r.tape[2], BFFOp.head1Right) // tape[2] = tape[0] = 0x7D
        XCTAssertEqual(r.copyWrites, 0, "both heads in the low half")
    }

    // '{' wraps head1 to 127; ',' reads tape[127] into tape[h0=0].
    func testHead1LeftWrapAndRead() {
        let r = exec(makeTape([BFFOp.head1Left, BFFOp.read], data: [127: 0xAB]))
        XCTAssertEqual(r.tape[0], 0xAB)
        XCTAssertEqual(r.copyWrites, 1, "h0 in low half, h1 in high half")
    }

    // '+' wraps 255 -> 0 (mod-256 byte arithmetic).
    func testIncWrapsByte() {
        let r = exec(makeTape([BFFOp.head0Left, BFFOp.inc], data: [127: 255]))
        XCTAssertEqual(r.tape[127], 0)
    }

    // '-' wraps 0 -> 255.
    func testDecWrapsByte() {
        let r = exec(makeTape([BFFOp.head0Left, BFFOp.dec]))
        XCTAssertEqual(r.tape[127], 255)
    }

    // '.' across halves: tape[head1] = tape[head0], counted as a cross-half copy.
    func testWriteAcrossHalves() {
        let r = exec(makeTape([BFFOp.head1Left, BFFOp.write]))
        XCTAssertEqual(r.tape[127], BFFOp.head1Left) // tape[127] = tape[0] = '{'
        XCTAssertEqual(r.copyWrites, 1)
    }

    // runPair: program A writes into B's half; both halves come back.
    func testRunPairWritesBothHalvesBack() {
        var a = [UInt8](repeating: 0, count: BFF.tapeSize)
        a[0] = BFFOp.head1Left
        a[1] = BFFOp.write
        let b = [UInt8](repeating: 0, count: BFF.tapeSize)
        let r = BFFInterpreter.runPair(a: a, b: b)
        XCTAssertEqual(r.tape[127], BFFOp.head1Left, "A wrote into B's last byte")
        XCTAssertEqual(Array(r.tape[0..<64])[0], BFFOp.head1Left, "A's half intact")
    }

    // Byte 0 and every non-command value are no-ops costing exactly 1 step.
    func testNullTapeIsAllNoOps() {
        let r = exec(makeTape())
        XCTAssertEqual(r.halt, .pcOut)
        XCTAssertEqual(r.steps, 128)
        XCTAssertEqual(r.tape, makeTape())
        XCTAssertEqual(r.loopOps, 0)
        XCTAssertEqual(r.copyWrites, 0)
    }

    func testEveryNonCommandByteIsANoOp() {
        for value in 0...255 where !BFFOp.all.contains(UInt8(value)) {
            let t = makeTape(data: [0: UInt8(value)])
            let r = exec(t)
            XCTAssertEqual(r.halt, .pcOut, "byte \(value)")
            XCTAssertEqual(r.steps, 128, "byte \(value)")
            XCTAssertEqual(r.tape, t, "byte \(value) must not change the tape")
        }
    }
}

final class HeadWrapTests: XCTestCase {

    // '<' from 0 wraps h0 to 127.
    func testHead0WrapsBackward() {
        let r = exec(makeTape([BFFOp.head0Left, BFFOp.inc]))
        XCTAssertEqual(r.tape[127], 1)
    }

    // '<' then '>' wraps h0 127 -> 0; '+' hits tape[0].
    func testHead0WrapsForward() {
        let r = exec(makeTape([BFFOp.head0Left, BFFOp.head0Right, BFFOp.inc]))
        XCTAssertEqual(r.tape[0], BFFOp.head0Left &+ 1) // 0x3C -> 0x3D
    }

    // '{' from 0 wraps h1 to 127 (verified via testHead1LeftWrapAndRead);
    // '{' then '}' wraps h1 back to 0: '.' with h0=1 writes tape[1] into tape[0].
    func testHead1WrapsForward() {
        let r = exec(makeTape([BFFOp.head1Left, BFFOp.head1Right,
                              BFFOp.head0Right, BFFOp.write]))
        XCTAssertEqual(r.tape[0], BFFOp.head1Right) // tape[0] = tape[h0=1] = '}'
    }
}

final class LoopSemanticsTests: XCTestCase {

    // Countdown loop: 10x'>' puts h0 on a data cell holding 2; [-] decrements to 0.
    // loopOps == 3 proves the taken ']' lands ON the '[' and the shared pc+=1
    // re-enters the body WITHOUT re-executing the '[' (alignment tag 5).
    func testBalancedLoopCountsAndLanding() {
        var code = [UInt8](repeating: BFFOp.head0Right, count: 10)
        code += [2, BFFOp.loopOpen, BFFOp.dec, BFFOp.loopClose]
        let r = exec(makeTape(code))
        XCTAssertEqual(r.tape[10], 0)
        XCTAssertEqual(r.halt, .pcOut)
        XCTAssertEqual(r.loopOps, 3, "'[' once, ']' twice — '[' is not re-executed")
        // 10 '>' + data + '[' + '-' + ']' + '-' + ']' + 114 trailing no-ops
        XCTAssertEqual(r.steps, 130)
    }

    // Taken '[' lands ON the matching ']'; pc+=1 continues after it, skipping the
    // body and not executing the ']'.
    func testTakenOpenBracketLandsPastMatch() {
        // '<' h0=127 (zero) → '[' taken; body '+' must be skipped; '+' after ']' runs.
        let code: [UInt8] = [BFFOp.head0Left, BFFOp.loopOpen,
                             BFFOp.inc, BFFOp.loopClose, BFFOp.inc]
        let r = exec(makeTape(code))
        XCTAssertEqual(r.tape[127], 1, "only the '+' after the loop executed")
        XCTAssertEqual(r.steps, 126, "']' itself not executed after the jump")
        XCTAssertEqual(r.loopOps, 1)
        XCTAssertEqual(r.halt, .pcOut)
    }

    // Taken '[' with no ']' anywhere: hard halt, and the halting op still costs
    // one step (mirrors the GPU kernel's pc++/steps++ after the halt flag).
    func testUnmatchedForwardBracketHalts() {
        let r = exec(makeTape([BFFOp.head0Left, BFFOp.loopOpen]))
        XCTAssertEqual(r.halt, .unmatched)
        XCTAssertEqual(r.steps, 2)
        XCTAssertEqual(r.loopOps, 1)
    }

    // Taken ']' with no '[' behind it: hard halt.
    func testUnmatchedBackwardBracketHalts() {
        // '+' makes tape[0] nonzero (0x2B -> 0x2C), so ']' is taken.
        let r = exec(makeTape([BFFOp.inc, BFFOp.loopClose]))
        XCTAssertEqual(r.halt, .unmatched)
        XCTAssertEqual(r.steps, 2)
        XCTAssertEqual(r.loopOps, 1)
    }

    // Non-taken unmatched brackets are harmless no-ops + condition test.
    func testNonTakenUnmatchedBracketFallsThrough() {
        // h0=0, tape[0]='[' (nonzero) → '[' not taken; then '<' h0=127 (zero),
        // ']' not taken. No halt until PC_OUT.
        let r = exec(makeTape([BFFOp.loopOpen, BFFOp.head0Left, BFFOp.loopClose]))
        XCTAssertEqual(r.halt, .pcOut)
        XCTAssertEqual(r.steps, 128)
        XCTAssertEqual(r.loopOps, 2)
    }

    // ']' spinning on a nonzero cell exhausts the step budget exactly.
    func testStepBudgetHalts() {
        // '+' makes tape[0] nonzero; '[' not taken; ']' jumps back to '[' forever.
        let code: [UInt8] = [BFFOp.inc, BFFOp.loopOpen, BFFOp.loopClose]
        let r = exec(makeTape(code))
        XCTAssertEqual(r.halt, .budget)
        XCTAssertEqual(r.steps, BFF.stepBudget)

        let small = exec(makeTape(code), budget: 100)
        XCTAssertEqual(small.halt, .budget)
        XCTAssertEqual(small.steps, 100)
    }
}

final class SelfModificationTests: XCTestCase {

    // The 01 §2 example: '+' twice turns '[' (0x5B) into ']' (0x5D). The rewritten
    // byte later EXECUTES as ']' with a nonzero condition and no '[' behind it.
    func testIncTurnsOpenBracketIntoCloseBracket() {
        let r = exec(makeTape([BFFOp.head0Left, BFFOp.inc, BFFOp.inc],
                             data: [127: BFFOp.loopOpen]))
        XCTAssertEqual(r.tape[127], BFFOp.loopClose)
        XCTAssertEqual(r.halt, .unmatched,
                       "the created ']' executed, was taken, and found no '['")
        XCTAssertEqual(r.steps, 128)
    }

    // A program can synthesize an instruction ahead of the pc and have it execute:
    // '+' turns 0x2A at tape[127] into '+' (0x2B), which then runs and increments
    // itself to 0x2C.
    func testCreatedInstructionExecutes() {
        let r = exec(makeTape([BFFOp.head0Left, BFFOp.inc], data: [127: 0x2A]))
        XCTAssertEqual(r.tape[127], 0x2C)
        XCTAssertEqual(r.halt, .pcOut)
    }
}

final class BracketModeDivergenceTests: XCTestCase {

    /// A crafted tape where the two bracket strategies measurably diverge.
    ///
    /// 28×'<' puts h0=100; '+' rewrites the 0x5A at 100 into a NEW '['; '<' puts
    /// h0=99 (zero); the '[' at 30 is taken. Live scan sees the new '[' at 100
    /// nest, so it matches the ']' at 110; the frozen table (built before the
    /// rewrite) says 105. The frozen path then executes three '+' at 106–108
    /// (tape[99] = 3) and halts UNMATCHED on the ']' at 110 (frozen entry:
    /// unmatched); the live path skips them entirely and walks off the tape.
    private func divergingTape() -> [UInt8] {
        var t = [UInt8](repeating: 0, count: BFF.pairTapeSize)
        for i in 0..<28 { t[i] = BFFOp.head0Left }
        t[28] = BFFOp.inc
        t[29] = BFFOp.head0Left
        t[30] = BFFOp.loopOpen
        t[100] = 0x5A // becomes '[' mid-run
        t[105] = BFFOp.loopClose
        t[106] = BFFOp.inc
        t[107] = BFFOp.inc
        t[108] = BFFOp.inc
        t[110] = BFFOp.loopClose
        return t
    }

    func testDynamicScanFollowsLiveTape() {
        let r = exec(divergingTape(), brackets: .dynamicScan)
        XCTAssertEqual(r.halt, .pcOut)
        XCTAssertEqual(r.steps, 48)
        XCTAssertEqual(r.tape[99], 0, "the frozen-only '+' run never executed")
        XCTAssertEqual(r.tape[100], BFFOp.loopOpen, "the rewrite itself happened")
        XCTAssertEqual(r.remapEvents, 1, "the taken '[' disagreed with the table")
    }

    func testJumpTableFollowsFrozenTable() {
        let r = exec(divergingTape(), brackets: .jumpTable)
        XCTAssertEqual(r.halt, .unmatched,
                       "']' at 110 was unmatched in the interaction-start table")
        XCTAssertEqual(r.steps, 36)
        XCTAssertEqual(r.tape[99], 3, "the '+' run between the two ']'s executed")
        XCTAssertEqual(r.remapEvents, 2, "both taken brackets disagreed with the table")
    }

    func testComparisonIdentifiesDivergence() {
        let cmp = BFFInterpreter.compareBracketModes(pairTape: divergingTape())
        XCTAssertTrue(cmp.diverges)
        XCTAssertTrue(cmp.tapesDiverge)
        XCTAssertTrue(cmp.statsDiverge)
        XCTAssertEqual(cmp.firstTapeDivergenceIndex, 99)
        XCTAssertNotEqual(cmp.dynamicScan.halt, cmp.jumpTable.halt)
        XCTAssertNotEqual(cmp.dynamicScan.steps, cmp.jumpTable.steps)
    }

    // Without self-modifying brackets the two modes are bit-identical — the reason
    // random-pair diffs are necessary but not sufficient for D1 (01 §7.3).
    func testModesAgreeOnNonSelfModifyingLoops() {
        var code = [UInt8](repeating: BFFOp.head0Right, count: 10)
        code += [3, BFFOp.loopOpen, BFFOp.dec, BFFOp.loopClose]
        let cmp = BFFInterpreter.compareBracketModes(pairTape: makeTape(code))
        XCTAssertFalse(cmp.diverges)
        XCTAssertEqual(cmp.dynamicScan.remapEvents, 0)
        XCTAssertEqual(cmp.jumpTable.remapEvents, 0)
    }
}

final class VariantTests: XCTestCase {

    // seededHeads ("bff"): h0 = tape[0] % 128, h1 = tape[1] % 128, pc = 2.
    func testSeededHeadsInitialState() {
        // tape[0]=5 → h0=5; tape[1]=200 → h1=72 (mod 128); execution starts at 2.
        // '+' bumps tape[5]; '.' copies tape[5] into tape[72] (cross-half).
        let t = makeTape([5, 200, BFFOp.inc, BFFOp.write])
        let r = exec(t, variant: .seededHeads)
        XCTAssertEqual(r.tape[5], 1)
        XCTAssertEqual(r.tape[72], 1)
        XCTAssertEqual(r.copyWrites, 1)
        XCTAssertEqual(r.steps, 126, "pc starts at 2, so bytes 0 and 1 never execute")
    }

    // noheads: everything starts at zero; tape[0] executes.
    func testNoheadsExecutesFromZero() {
        let r = exec(makeTape([BFFOp.inc]), variant: .noheads)
        XCTAssertEqual(r.tape[0], BFFOp.inc &+ 1, "the '+' incremented itself")
        XCTAssertEqual(r.steps, 128)
    }
}
