/// Bounded, adaptive per-frame epoch batching (REQUIRED 2; the modest-slice
/// analogue of 05 §4.1).
///
/// It answers one question each frame: *how many epochs should the next
/// command-buffer batch run* to spend about `targetMs` of simulation work? It
/// tracks a smoothed (EMA) measured ms-per-epoch and divides the target by it,
/// then clamps hard:
///
///  - `minEpochs … maxEpochs` — conservative absolute bounds; the maximum caps
///    any single batch so a slow measurement can never schedule a runaway catch-up
///    batch, and the minimum guarantees forward progress.
///  - a **ramp limit** (`× rampFactor` from the previous batch) so the count grows
///    smoothly out of a cold start instead of overshooting on the first fast
///    sample.
///
/// This changes only *how many* `runEpoch` calls happen between frames — never the
/// RNG, epoch semantics, or the resulting trajectory (that is a pure function of
/// `(seed, config)` in `SoupRunner`; a determinism test partitions the same epoch
/// count differently and asserts identical soups). Invalid timing samples
/// (non-finite, ≤ 0) are ignored so a bad measurement cannot corrupt the EMA.
///
/// Pure value type; no Metal, no clock — the caller supplies measured durations.
public struct AdaptiveBatcher: Equatable, Sendable {
    /// Target simulation milliseconds per batch (~10 ms).
    public let targetMs: Double
    /// Never run fewer than this many epochs per batch (≥ 1).
    public let minEpochs: Int
    /// Never run more than this many epochs per batch (the runaway guard).
    public let maxEpochs: Int
    /// EMA weight for the newest ms-per-epoch sample (0…1).
    public let alpha: Double
    /// The most a batch may grow over the previous batch's size.
    public let rampFactor: Int

    /// Smoothed milliseconds per epoch; `nil` before the first valid sample.
    public private(set) var emaMsPerEpoch: Double?
    /// Epochs chosen for the most recent batch (seeds the ramp limit).
    public private(set) var lastEpochs: Int

    public init(targetMs: Double = 10, minEpochs: Int = 1, maxEpochs: Int = 64,
                alpha: Double = 0.2, rampFactor: Int = 4) {
        precondition(targetMs > 0, "target must be positive")
        precondition(minEpochs >= 1 && maxEpochs >= minEpochs, "invalid epoch bounds")
        precondition(alpha > 0 && alpha <= 1, "alpha must be in (0, 1]")
        precondition(rampFactor >= 1, "ramp factor must be ≥ 1")
        self.targetMs = targetMs
        self.minEpochs = minEpochs
        self.maxEpochs = maxEpochs
        self.alpha = alpha
        self.rampFactor = rampFactor
        self.emaMsPerEpoch = nil
        self.lastEpochs = minEpochs
    }

    /// Fold a completed batch's measured wall/GPU duration into the EMA. Invalid
    /// samples (non-finite or ≤ 0 duration, or ≤ 0 epochs) are ignored entirely.
    public mutating func record(batchMs: Double, epochs: Int) {
        guard epochs > 0, batchMs.isFinite, batchMs > 0 else { return }
        let sample = batchMs / Double(epochs)
        guard sample.isFinite, sample > 0 else { return }
        if let prev = emaMsPerEpoch {
            emaMsPerEpoch = alpha * sample + (1 - alpha) * prev
        } else {
            emaMsPerEpoch = sample            // first valid sample seeds the EMA
        }
    }

    /// Epochs to run in the next batch: `targetMs / emaMsPerEpoch`, clamped by the
    /// ramp limit and the absolute `[minEpochs, maxEpochs]` bounds. Cold start (no
    /// sample yet) returns `minEpochs` — one conservative probe batch whose measured
    /// time seeds the EMA and lets the ramp grow the count over the next frames.
    public mutating func nextBatchEpochs() -> Int {
        let byTime: Int
        if let ms = emaMsPerEpoch, ms > 0 {
            let raw = targetMs / ms
            byTime = raw.isFinite ? Swift.max(minEpochs, Int(raw)) : minEpochs
        } else {
            byTime = minEpochs
        }
        let rampCap = Self.saturatingMul(lastEpochs, rampFactor)
        let chosen = Swift.min(byTime, rampCap, maxEpochs)
        lastEpochs = Swift.max(minEpochs, chosen)
        return lastEpochs
    }

    /// Multiply guarding against `Int` overflow (returns `.max` on overflow).
    private static func saturatingMul(_ a: Int, _ b: Int) -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? Int.max : product
    }
}
