import BFFOracle
import BFFMetal

/// An immutable, deterministic render snapshot of the latest stable soup
/// (REQUIRED 3): one record per stable program ID carrying its 64 post-epoch
/// bytes, its integer activity (command steps), and its byte entropy.
///
/// "Immutable snapshot" is the lifetime-safety contract: the renderer only ever
/// uploads a value of this type, never a live handle into the running soup, so
/// there is no CPU/GPU race on the evolving buffers. Ordering is by stable program
/// ID (record `i` is program `i`), and the close-up path indexes bytes by
/// `(programID, byteIndex)` — never by shuffled pair position, so there is no
/// pair-position leakage.
public struct RenderSnapshot: Equatable, Sendable {
    /// Epochs completed when this snapshot was taken.
    public let epoch: Int
    /// Number of stable programs.
    public let programCount: Int
    /// `programCount · 64` bytes; program `i` occupies `i·64 ..< (i+1)·64`.
    public let programBytes: [UInt8]
    /// Per-program activity (command-step count), index = stable program ID.
    public let activity: [Int]
    /// Per-program byte entropy (bits/byte, `[0, 6]`), index = stable program ID.
    public let entropy: [Double]

    public enum SnapshotError: Error, Equatable, CustomStringConvertible {
        case nonPositiveProgramCount(Int)
        case byteLengthMismatch(expected: Int, got: Int)
        case activityCountMismatch(expected: Int, got: Int)
        case entropyCountMismatch(expected: Int, got: Int)

        public var description: String {
            switch self {
            case .nonPositiveProgramCount(let n):
                return "program count \(n) must be positive"
            case .byteLengthMismatch(let e, let g):
                return "program bytes length \(g) != expected \(e) (programCount·64)"
            case .activityCountMismatch(let e, let g):
                return "activity count \(g) != expected \(e)"
            case .entropyCountMismatch(let e, let g):
                return "entropy count \(g) != expected \(e)"
            }
        }
    }

    /// Validate lengths against `programCount` before constructing — the renderer
    /// resource/config validation gate. Throws on any mismatch.
    public init(epoch: Int, programCount: Int, programBytes: [UInt8],
                activity: [Int], entropy: [Double]) throws {
        guard programCount > 0 else {
            throw SnapshotError.nonPositiveProgramCount(programCount)
        }
        let expectedBytes = programCount * BFF.tapeSize
        guard programBytes.count == expectedBytes else {
            throw SnapshotError.byteLengthMismatch(expected: expectedBytes,
                                                   got: programBytes.count)
        }
        guard activity.count == programCount else {
            throw SnapshotError.activityCountMismatch(expected: programCount,
                                                      got: activity.count)
        }
        guard entropy.count == programCount else {
            throw SnapshotError.entropyCountMismatch(expected: programCount,
                                                     got: entropy.count)
        }
        self.epoch = epoch
        self.programCount = programCount
        self.programBytes = programBytes
        self.activity = activity
        self.entropy = entropy
    }

    /// Build from a soup and its per-program metrics (as produced by
    /// `SoupMetrics.programMetrics`, in stable-ID order).
    public static func build(epoch: Int, programCount: Int, soup: [UInt8],
                             metrics: [ProgramMetric]) throws -> RenderSnapshot {
        try RenderSnapshot(epoch: epoch, programCount: programCount,
                           programBytes: soup,
                           activity: metrics.map { $0.activity },
                           entropy: metrics.map { $0.entropyBitsPerByte })
    }

    /// An epoch-0 snapshot straight from the seeded soup: activity all zero (no
    /// interaction has run) and entropy computed per program. Gives the renderer
    /// something deterministic to draw before the first epoch batch.
    public static func initial(programCount: Int, soup: [UInt8]) throws -> RenderSnapshot {
        var entropy = [Double]()
        entropy.reserveCapacity(programCount)
        for id in 0 ..< programCount {
            let start = id * BFF.tapeSize
            entropy.append(SoupMetrics.entropyBitsPerByte(Array(soup[start ..< start + BFF.tapeSize])))
        }
        return try RenderSnapshot(epoch: 0, programCount: programCount, programBytes: soup,
                                  activity: [Int](repeating: 0, count: programCount),
                                  entropy: entropy)
    }

    /// The 64 bytes of program `id` (a copy).
    public func programByteSlice(_ id: Int) -> [UInt8] {
        precondition(id >= 0 && id < programCount, "program id out of range")
        let start = id * BFF.tapeSize
        return Array(programBytes[start ..< start + BFF.tapeSize])
    }

    /// Fixed-normalized `(activity, entropy)` per program, in ID order — exactly
    /// the two channels the aggregate metric texture uploads (R = activity,
    /// G = entropy).
    public func normalizedMetrics(_ norm: MetricNormalization) -> [(activity: Double, entropy: Double)] {
        (0 ..< programCount).map { i in
            (norm.normalizedActivity(activity[i]), norm.normalizedEntropy(entropy[i]))
        }
    }
}
