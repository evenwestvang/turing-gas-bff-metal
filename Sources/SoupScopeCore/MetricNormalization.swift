import BFFMetal

/// Fixed, replay-stable normalization of per-program metrics into `[0, 1]` for the
/// aggregate texture (03 §4, REQUIRED 3).
///
/// Normalization uses **fixed bounds**, never running min/max auto-scaling: with
/// auto-scaling the same soup would map to different colors depending on the rest
/// of the frame, making a deterministic replay look visually nondeterministic. The
/// bounds are:
///
///  - **activity** (a program's command-step count, `steps − noopSteps`): divided
///    by the run's `stepBudget` and clamped to `[0, 1]`. The step budget is fixed
///    for the whole run, so the mapping is constant. A program can execute at most
///    `stepBudget` steps, so command steps ≤ budget and the clamp only guards
///    against an out-of-contract count.
///  - **entropy** (order-0 Shannon entropy of the 64 program bytes, bits/byte):
///    divided by `entropyMax = 6` and clamped to `[0, 1]`. A 64-byte window holds
///    at most 64 distinct values, so the entropy range is exactly `[0, 6]`
///    (`log2 64 = 6`) — 6 is a hard bound, not an observed maximum.
///
/// Pure value type; no Metal.
public struct MetricNormalization: Equatable, Sendable {
    /// Activity denominator (the run's step budget).
    public let activityMax: Double
    /// Entropy denominator; 6 bits/byte is the hard maximum for a 64-byte window.
    public let entropyMax: Double

    public init(stepBudget: Int, entropyMax: Double = 6) {
        precondition(stepBudget > 0, "step budget must be positive")
        precondition(entropyMax > 0, "entropy max must be positive")
        self.activityMax = Double(stepBudget)
        self.entropyMax = entropyMax
    }

    @inline(__always)
    private static func clamp01(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        return Swift.min(Swift.max(x, 0), 1)
    }

    /// Normalize an integer command-step activity into `[0, 1]`.
    public func normalizedActivity(_ activity: Int) -> Double {
        Self.clamp01(Double(activity) / activityMax)
    }

    /// Normalize a bits/byte entropy value into `[0, 1]`.
    public func normalizedEntropy(_ entropyBitsPerByte: Double) -> Double {
        Self.clamp01(entropyBitsPerByte / entropyMax)
    }

    /// Both normalized channels for one `ProgramMetric`, in the `(activity,
    /// entropy)` order the aggregate texture's R,G channels use.
    public func normalized(_ metric: ProgramMetric) -> (activity: Double, entropy: Double) {
        (normalizedActivity(metric.activity),
         normalizedEntropy(metric.entropyBitsPerByte))
    }
}
