import XCTest
import BFFOracle
import CBFFShared
@testable import BFFMetal

/// Host-side half of the CPU/MSL layout contract (BFFShared.h): what Swift
/// imports from the C header must match the documented literals exactly. These
/// run on every platform, including Linux; the GPU-side half is checked at
/// runner init by the `bff_layout_probe` kernel.
final class SharedLayoutTests: XCTestCase {

    // MARK: BFFEvalParams

    func testParamsSizeStrideAlignment() {
        XCTAssertEqual(MemoryLayout<BFFEvalParams>.size, 16)
        XCTAssertEqual(MemoryLayout<BFFEvalParams>.stride, 16,
                       "params arrays/setBytes must be densely packed")
        XCTAssertEqual(MemoryLayout<BFFEvalParams>.alignment, 4)
    }

    func testParamsFieldOffsets() {
        XCTAssertEqual(MemoryLayout<BFFEvalParams>.offset(of: \.pairCount), 0)
        XCTAssertEqual(MemoryLayout<BFFEvalParams>.offset(of: \.stepBudget), 4)
        XCTAssertEqual(MemoryLayout<BFFEvalParams>.offset(of: \.variant), 8)
        XCTAssertEqual(MemoryLayout<BFFEvalParams>.offset(of: \.reserved), 12)
    }

    // MARK: BFFEvalResult

    func testResultSizeStrideAlignment() {
        XCTAssertEqual(MemoryLayout<BFFEvalResult>.size, 20)
        XCTAssertEqual(MemoryLayout<BFFEvalResult>.stride, 20,
                       "result records must be densely packed: GPU results[i] "
                       + "is host byte offset i * 20")
        XCTAssertEqual(MemoryLayout<BFFEvalResult>.alignment, 4)
    }

    func testResultFieldOffsets() {
        XCTAssertEqual(MemoryLayout<BFFEvalResult>.offset(of: \.steps), 0)
        XCTAssertEqual(MemoryLayout<BFFEvalResult>.offset(of: \.noopSteps), 4)
        XCTAssertEqual(MemoryLayout<BFFEvalResult>.offset(of: \.copyWrites), 8)
        XCTAssertEqual(MemoryLayout<BFFEvalResult>.offset(of: \.loopOps), 12)
        XCTAssertEqual(MemoryLayout<BFFEvalResult>.offset(of: \.halt), 16)
    }

    // MARK: Probe schema

    func testHostProbeWordsMatchDocumentedLayout() {
        let words = BFFEvalLayout.hostProbeWords()
        XCTAssertEqual(words.count, BFFEvalLayout.probeWordCount)
        XCTAssertEqual(words, [16, 4, 0, 4, 8, 12,
                               20, 4, 0, 4, 8, 12, 16],
                       "probe word schema drifted from BFFShared.h documentation")
    }

    // MARK: Header constants vs oracle

    func testSizesMatchOracle() {
        XCTAssertEqual(Int(BFF_PROG_SIZE), BFF.tapeSize)
        XCTAssertEqual(Int(BFF_PAIR_TAPE_SIZE), BFF.pairTapeSize)
    }

    func testCommandBytesMatchOracle() {
        XCTAssertEqual(UInt8(BFF_OP_HEAD0_LEFT), BFFOp.head0Left)
        XCTAssertEqual(UInt8(BFF_OP_HEAD0_RIGHT), BFFOp.head0Right)
        XCTAssertEqual(UInt8(BFF_OP_HEAD1_LEFT), BFFOp.head1Left)
        XCTAssertEqual(UInt8(BFF_OP_HEAD1_RIGHT), BFFOp.head1Right)
        XCTAssertEqual(UInt8(BFF_OP_INC), BFFOp.inc)
        XCTAssertEqual(UInt8(BFF_OP_DEC), BFFOp.dec)
        XCTAssertEqual(UInt8(BFF_OP_WRITE), BFFOp.write)
        XCTAssertEqual(UInt8(BFF_OP_READ), BFFOp.read)
        XCTAssertEqual(UInt8(BFF_OP_LOOP_OPEN), BFFOp.loopOpen)
        XCTAssertEqual(UInt8(BFF_OP_LOOP_CLOSE), BFFOp.loopClose)
    }

    func testHaltReasonsMatchOracle() {
        XCTAssertEqual(UInt8(BFF_HALT_BUDGET), HaltReason.budget.rawValue)
        XCTAssertEqual(UInt8(BFF_HALT_PC_OUT), HaltReason.pcOut.rawValue)
        XCTAssertEqual(UInt8(BFF_HALT_UNMATCHED), HaltReason.unmatched.rawValue)
    }

    func testVariantCodesMatchHeader() {
        XCTAssertEqual(BFFEvalLayout.variantCode(.noheads),
                       UInt32(BFF_VARIANT_NOHEADS))
        XCTAssertEqual(BFFEvalLayout.variantCode(.seededHeads),
                       UInt32(BFF_VARIANT_SEEDED_HEADS))
        XCTAssertNotEqual(BFFEvalLayout.variantCode(.noheads),
                          BFFEvalLayout.variantCode(.seededHeads))
    }

    func testStepBudgetRepresentation() {
        XCTAssertEqual(BFFEvalLayout.maxStepBudget, Int(UInt32.max))
        XCTAssertLessThanOrEqual(BFF.stepBudget, BFFEvalLayout.maxStepBudget,
                                 "the default budget must fit the shared field")
    }

    // MARK: Round-trip through raw bytes (what the Metal host actually does)

    func testResultRecordRawByteRoundTrip() {
        var record = BFFEvalResult(steps: 0x01020304, noopSteps: 0x05060708,
                                   copyWrites: 0x090A0B0C, loopOps: 0x0D0E0F10,
                                   halt: UInt32(BFF_HALT_UNMATCHED))
        let bytes = withUnsafeBytes(of: &record) { [UInt8]($0) }
        XCTAssertEqual(bytes.count, 20)
        // Little-endian field placement at the documented offsets.
        XCTAssertEqual(Array(bytes[0..<4]), [0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(Array(bytes[16..<20]), [UInt8(BFF_HALT_UNMATCHED), 0, 0, 0])

        let reloaded = bytes.withUnsafeBytes { $0.load(as: BFFEvalResult.self) }
        XCTAssertEqual(reloaded.steps, 0x01020304)
        XCTAssertEqual(reloaded.noopSteps, 0x05060708)
        XCTAssertEqual(reloaded.copyWrites, 0x090A0B0C)
        XCTAssertEqual(reloaded.loopOps, 0x0D0E0F10)
        XCTAssertEqual(reloaded.halt, UInt32(BFF_HALT_UNMATCHED))
    }
}
