#if canImport(Metal)
import XCTest
import Metal
import BFFOracle
@testable import BFFMetal

/// The injected device/queue path added for the app's shared Metal context
/// (REQUIRED 1): one device + one queue feed both the evaluator and (in the app)
/// the renderer. macOS only; honest XCTSkip when no device exists.
final class SharedContextEvaluatorTests: XCTestCase {

    func testEvaluatorUsesInjectedDeviceAndQueue() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available on this host")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("could not create a command queue")
        }
        let evaluator: MetalBFFEvaluator
        do {
            evaluator = try MetalBFFEvaluator(device: device, queue: queue)
        } catch MetalBFFEvaluator.EvaluatorError.noDevice {
            throw XCTSkip("no Metal device available")
        }
        // The evaluator must report the exact injected device/queue — that identity
        // is what lets the renderer share them.
        XCTAssertTrue(evaluator.metalDevice === device)
        XCTAssertTrue(evaluator.commandQueue === queue)

        // And it still evaluates correctly on the shared context: an empty program
        // pair walks the pc off the tape (all no-ops) and halts PC_OUT.
        let tape = [UInt8](repeating: 0, count: BFF.pairTapeSize)
        let outcomes = try evaluator.evaluate(pairTapes: [tape], variant: .noheads,
                                              stepBudget: 8192)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].halt, UInt32(HaltReason.pcOut.rawValue))
    }
}
#endif
