import BFFOracle
import Foundation

/// The two program identities that meet in one interaction. Pairing does NOT
/// redefine identity: `a` and `b` are the *stable program IDs* (indices into the
/// soup) that a shuffled position selected as partners, and results scatter back
/// to exactly these IDs. Stored as a named struct (not a tuple) so plans are
/// `Equatable` for replay tests.
public struct PairIdentity: Equatable, Sendable {
    public var a: UInt32
    public var b: UInt32
    public init(a: UInt32, b: UInt32) {
        self.a = a
        self.b = b
    }
}

/// Everything a single epoch needs before touching the GPU — a pure function of
/// `(soup, config, epoch)`, so it is fully testable without a Metal device and is
/// the exact bytes the shadow comparator captures.
public struct EpochPlan: Equatable, Sendable {
    /// 0-based epoch index this plan is for.
    public var epoch: Int
    /// The Fisher–Yates permutation of `0..<programCount` (01 §4, `BFFRandom`).
    public var permutation: [UInt32]
    /// Pair `p` is `(permutation[2p], permutation[2p+1])`, mapped to program IDs.
    public var pairs: [PairIdentity]
    /// Pair `p`'s packed 128-byte interaction tape: program `pairs[p].a`'s 64 bytes
    /// followed by program `pairs[p].b`'s 64 bytes, taken from the post-mutation
    /// soup. This is precisely what is uploaded to the GPU and what the shadow
    /// comparator re-runs.
    public var inputTapes: [[UInt8]]
    /// Number of soup bytes the mutation predicate fired on this epoch.
    public var mutationCount: Int

    public init(epoch: Int, permutation: [UInt32], pairs: [PairIdentity],
                inputTapes: [[UInt8]], mutationCount: Int) {
        self.epoch = epoch
        self.permutation = permutation
        self.pairs = pairs
        self.inputTapes = inputTapes
        self.mutationCount = mutationCount
    }
}

/// Platform-independent epoch mechanics: mutate → pair → pack, then (after the
/// evaluator runs) scatter. No GPU, no randomness of its own — it only sequences
/// the existing `counter-pcg-v1` `BFFRandom` routines.
public enum SoupPlanner {

    /// Mutate a copy of `soup` and build the epoch plan. Does not touch the caller's
    /// soup; the mutated soup is returned so the caller commits it only alongside
    /// the scattered GPU results.
    ///
    /// RNG domains are the fixed contract: mutation draws from stream `epoch*4+0`,
    /// pairing from `epoch*4+1` (`BFFRandom.Pass`). Nothing here depends on Swift
    /// hash iteration order.
    public static func plan(soup: [UInt8], config: SoupConfig, epoch: Int)
        -> (mutatedSoup: [UInt8], plan: EpochPlan) {
        // Composition of the two byte-identical sub-steps below. Kept as one call so
        // every existing caller (app, oracle, CLI, shadow) is unchanged; the split only
        // exists so the benchmark can time mutation+pairing separately from packing.
        let (mutated, perm, mutationCount) = mutateAndPair(soup: soup, config: config,
                                                           epoch: epoch)
        let plan = pack(mutated: mutated, permutation: perm, mutationCount: mutationCount,
                        config: config, epoch: epoch)
        return (mutated, plan)
    }

    /// Stage 1: mutate a copy of the soup (RNG stream `epoch*4+0`) and draw the
    /// Fisher–Yates pairing permutation (stream `epoch*4+1`). No pair tapes are packed
    /// yet — this is exactly the mutation-planning + pairing work the benchmark times as
    /// one host stage. Byte-for-byte the first half of `plan`.
    public static func mutateAndPair(soup: [UInt8], config: SoupConfig, epoch: Int)
        -> (mutated: [UInt8], permutation: [UInt32], mutationCount: Int) {
        precondition(soup.count == config.soupByteCount,
                     "soup is \(soup.count) bytes, expected \(config.soupByteCount)")
        precondition(epoch >= 0 && epoch <= Int(UInt32.max), "epoch out of range")
        let e = UInt32(epoch)

        var mutated = soup
        let mutationCount = BFFRandom.mutate(soup: &mutated, seed: config.seed,
                                             epoch: e, mutationP32: config.mutationP32)

        let perm = BFFRandom.pairingPermutation(count: config.programCount,
                                                seed: config.seed, epoch: e)
        return (mutated, perm, mutationCount)
    }

    /// Stage 2: pack each permutation-selected partner pair into its 128-byte
    /// interaction tape (the nested-array construction / allocation the GPU consumes).
    /// Pure function of the mutated soup + permutation; byte-for-byte the second half of
    /// `plan`.
    public static func pack(mutated: [UInt8], permutation perm: [UInt32],
                            mutationCount: Int, config: SoupConfig, epoch: Int)
        -> EpochPlan {
        var pairs: [PairIdentity] = []
        var tapes: [[UInt8]] = []
        pairs.reserveCapacity(config.pairCount)
        tapes.reserveCapacity(config.pairCount)
        for p in 0..<config.pairCount {
            let a = perm[2 * p]
            let b = perm[2 * p + 1]
            pairs.append(PairIdentity(a: a, b: b))

            let ra = Int(a) * BFF.tapeSize
            let rb = Int(b) * BFF.tapeSize
            var tape = [UInt8]()
            tape.reserveCapacity(BFF.pairTapeSize)
            tape.append(contentsOf: mutated[ra ..< ra + BFF.tapeSize])
            tape.append(contentsOf: mutated[rb ..< rb + BFF.tapeSize])
            tapes.append(tape)
        }

        return EpochPlan(epoch: epoch, permutation: perm, pairs: pairs,
                         inputTapes: tapes, mutationCount: mutationCount)
    }

    /// Scatter both 64-byte halves of each final pair tape back to the stable
    /// program identities that formed the pair. Pairs are disjoint (a permutation),
    /// so no two writes alias.
    public static func scatter(into soup: inout [UInt8], plan: EpochPlan,
                               finalTapes: [[UInt8]]) {
        precondition(finalTapes.count == plan.pairs.count,
                     "expected \(plan.pairs.count) final tapes, got \(finalTapes.count)")
        for (p, pair) in plan.pairs.enumerated() {
            let tape = finalTapes[p]
            precondition(tape.count == BFF.pairTapeSize,
                         "final tape \(p) is \(tape.count) bytes")
            let ra = Int(pair.a) * BFF.tapeSize
            let rb = Int(pair.b) * BFF.tapeSize
            soup.replaceSubrange(ra ..< ra + BFF.tapeSize,
                                 with: tape[0 ..< BFF.tapeSize])
            soup.replaceSubrange(rb ..< rb + BFF.tapeSize,
                                 with: tape[BFF.tapeSize ..< BFF.pairTapeSize])
        }
    }
}

/// Per-epoch aggregate accounting, reduced on the host from the per-interaction
/// GPU result records (no per-step global atomics — 02 §8 "epoch summaries come
/// free"). All counters preserve the split the evaluator/oracle define:
/// `steps` is raw gas, `noopSteps` is cubff `nskip`, `commandSteps` is derived.
public struct EpochCounters: Equatable, Sendable, Codable {
    public var epoch: Int
    public var interactions: Int
    public var mutationCount: Int
    /// Raw executed ops (budget accounting) summed over all interactions.
    public var totalRawSteps: Int
    /// Executed null/non-command bytes (cubff `nskip`) summed.
    public var totalNoopSteps: Int
    /// cubff observable op count summed: `totalRawSteps - totalNoopSteps`.
    public var totalCommandSteps: Int
    /// Bracket ops executed (taken or not) summed.
    public var totalLoopOps: Int
    /// Cross-half `.`/`,` executions summed.
    public var totalCopyWrites: Int
    /// Halt-reason histogram (01 §3): budget / pc-out / unmatched. Normatively the
    /// evaluator always halts with one of these three, but a byte read off the
    /// shared buffer is untyped, so an out-of-contract raw halt value is possible.
    public var haltBudget: Int
    public var haltPCOut: Int
    public var haltUnmatched: Int
    /// Interactions whose raw halt code was none of the three known reasons. This
    /// is normatively zero; it is counted (not silently dropped) so that every
    /// interaction lands in exactly one halt bucket regardless of whether the
    /// CPU-shadow sampled it. A nonzero value is a global signal that the evaluator
    /// emitted a halt code outside the contract — the shadow catches it only if it
    /// happened to sample that pair, but this count sees it unconditionally.
    public var haltUnknown: Int

    /// Total interactions attributed across all halt buckets (the three known
    /// reasons plus unknown). Invariant, enforced by `reduce`: this equals
    /// `interactions`, because the switch below has no drop-through branch.
    public var haltAccounted: Int {
        haltBudget + haltPCOut + haltUnmatched + haltUnknown
    }

    /// Reduce per-interaction GPU outcomes into one epoch's totals.
    public static func reduce(epoch: Int, mutationCount: Int,
                              outcomes: [GPUPairOutcome]) -> EpochCounters {
        var c = EpochCounters(
            epoch: epoch, interactions: outcomes.count, mutationCount: mutationCount,
            totalRawSteps: 0, totalNoopSteps: 0, totalCommandSteps: 0,
            totalLoopOps: 0, totalCopyWrites: 0,
            haltBudget: 0, haltPCOut: 0, haltUnmatched: 0, haltUnknown: 0)
        for o in outcomes {
            c.totalRawSteps += Int(o.steps)
            c.totalNoopSteps += Int(o.noopSteps)
            c.totalLoopOps += Int(o.loopOps)
            c.totalCopyWrites += Int(o.copyWrites)
            switch o.halt {
            case UInt32(HaltReason.budget.rawValue): c.haltBudget += 1
            case UInt32(HaltReason.pcOut.rawValue): c.haltPCOut += 1
            case UInt32(HaltReason.unmatched.rawValue): c.haltUnmatched += 1
            default: c.haltUnknown += 1 // out-of-contract: surfaced globally, not dropped
            }
        }
        c.totalCommandSteps = c.totalRawSteps - c.totalNoopSteps
        return c
    }
}

/// One deterministic metric record per stable program ID after an epoch — the raw
/// numbers a later renderer will map to color/activity, computed here with no
/// textures, mipmaps, or colors.
public struct ProgramMetric: Equatable, Sendable, Codable {
    public var programID: Int
    /// Integer activity: the interaction's *command-step* count
    /// (`steps - noopSteps`, i.e. executed non-no-op ops), attributed identically
    /// to BOTH partners of the pair. Activity is a pair-level event — the two
    /// programs shared one interaction — so both members receive the same value,
    /// mirroring the evaluator design's `progStats[ia] = progStats[ib]` (02 §6).
    public var activity: Int
    /// Order-0 (plug-in) Shannon entropy of the program's 64 post-epoch bytes, in
    /// bits per byte, range [0, 6] (a 64-byte window holds at most 64 distinct
    /// values → log2(64) = 6). Uses the same definition as `ByteHistogram`.
    public var entropyBitsPerByte: Double

    public init(programID: Int, activity: Int, entropyBitsPerByte: Double) {
        self.programID = programID
        self.activity = activity
        self.entropyBitsPerByte = entropyBitsPerByte
    }
}

/// Platform-independent per-program metric computation.
public enum SoupMetrics {

    /// Program-count threshold below which per-program metric construction runs
    /// serially. Below this the concurrent-dispatch overhead exceeds the entropy
    /// savings; above it each program's metric is built on a concurrent queue with
    /// disjoint indexed writes. Chosen so every existing test/soup (≤ a few hundred
    /// programs) stays serial, while the 131,072-program default harvests all cores.
    static let parallelThreshold = 4096

    /// Byte entropy of a single 64-byte program, bits/byte in [0, 6].
    /// Thin wrapper over `ByteHistogram` so the definition lives in exactly one
    /// place; pinned by tests (uniform → 0, 64 distinct → 6).
    public static func entropyBitsPerByte(_ program: [UInt8]) -> Double {
        ByteHistogram(bytes: program).shannonEntropyBitsPerByte
    }

    /// Allocation-free order-0 Shannon entropy over a contiguous slice of `soup`,
    /// bits/byte in [0, 8]. The reusable `bins` buffer (256 entries) is zeroed and
    /// refilled per call, eliminating the per-program Array slice and 256-bin heap
    /// allocation of the `ByteHistogram(bytes:)` path used at 131,072 programs.
    ///
    /// The entropy is accumulated in byte-value order `0..<256`, exactly matching
    /// `ByteHistogram.shannonEntropyBitsPerByte`: `reduce(0, +)` for the total, then
    /// `h -= p * log2(p)` for each non-empty bin in ascending byte-value order. This
    /// preserves the floating-point summation order, so the result is bit-identical
    /// to the legacy path for every input.
    static func entropyBitsPerByte(soup: [UInt8], start: Int, length: Int,
                                   bins: inout [UInt64]) -> Double {
        precondition(start >= 0 && length >= 0 && start + length <= soup.count)
        precondition(bins.count == 256)
        // Zero-length slice ⇒ zero entropy, matching `ByteHistogram` on empty input.
        // Also avoids force-unwrapping a nil base address for an empty `soup`.
        if length == 0 { return 0 }
        return soup.withUnsafeBufferPointer { soupPtr in
            bins.withUnsafeMutableBufferPointer { binPtr in
                entropyBitsPerByte(soupBase: soupPtr.baseAddress!,
                                   start: start, length: length,
                                   bins: binPtr.baseAddress!)
            }
        }
    }

    /// Core entropy computation over raw pointers. `@inline(__always)` so the serial
    /// and parallel paths share one implementation without a call-cost penalty at the
    /// 131,072-program scale.
    ///
    /// - Parameters:
    ///   - soupBase: Base of the contiguous soup buffer.
    ///   - start: Offset of the program's first byte within `soupBase`.
    ///   - length: Number of bytes in the program (`BFF.tapeSize`).
    ///   - bins: A 256-element `UInt64` buffer; zeroed and refilled per call.
    @inline(__always)
    private static func entropyBitsPerByte(soupBase: UnsafePointer<UInt8>,
                                           start: Int, length: Int,
                                           bins: UnsafeMutablePointer<UInt64>) -> Double {
        // Zero the reusable bin buffer for this program.
        for v in 0..<256 { bins[v] = 0 }
        // Accumulate byte counts directly from the soup buffer (no Array slice).
        let p = soupBase + start
        for i in 0..<length {
            bins[Int(p[i])] += 1
        }
        // Total in byte-value order 0..<256 — identical to `bins.reduce(0, +)`.
        var total: UInt64 = 0
        for v in 0..<256 { total += bins[v] }
        guard total > 0 else { return 0 }
        // Entropy in byte-value order 0..<256, skipping zeros — identical to
        // `ByteHistogram.shannonEntropyBitsPerByte`.
        let n = Double(total)
        var h = 0.0
        for v in 0..<256 {
            let count = bins[v]
            if count > 0 {
                let prob = Double(count) / n
                h -= prob * log2(prob)
            }
        }
        return h
    }

    /// One `ProgramMetric` per program ID `0..<programCount`, in ID order.
    /// Activity is taken from the pair outcome and attributed to both partners;
    /// entropy is computed from the post-epoch soup. Every program appears in
    /// exactly one pair (the pairing is a permutation), so every activity is set.
    ///
    /// At or above `parallelThreshold` programs the per-program scan runs on a
    /// concurrent queue (disjoint indexed writes, per-chunk 256-bin buffers);
    /// below it the scan is serial with one reusable buffer. Both paths are
    /// allocation-free per program and produce element-for-element identical output.
    public static func programMetrics(soup: [UInt8], plan: EpochPlan,
                                      outcomes: [GPUPairOutcome],
                                      programCount: Int) -> [ProgramMetric] {
        programMetrics(soup: soup, plan: plan, outcomes: outcomes,
                       programCount: programCount,
                       parallel: programCount >= parallelThreshold)
    }

    /// Internal overload that forces serial or parallel metric construction. The
    /// public entry point selects based on `parallelThreshold`; this exists so tests
    /// can prove the two paths are element-for-element identical across thresholds.
    static func programMetrics(soup: [UInt8], plan: EpochPlan,
                               outcomes: [GPUPairOutcome],
                               programCount: Int,
                               parallel: Bool) -> [ProgramMetric] {
        precondition(soup.count == programCount * BFF.tapeSize)
        precondition(outcomes.count == plan.pairs.count)

        var activity = [Int](repeating: 0, count: programCount)
        for (p, pair) in plan.pairs.enumerated() {
            let a = outcomes[p].commandSteps
            activity[Int(pair.a)] = a
            activity[Int(pair.b)] = a
        }

        // Pre-allocate the output so the parallel path can write to disjoint indices
        // via UnsafeMutableBufferPointer (race-free: each program ID is written by
        // exactly one iteration). Every element is overwritten below.
        var metrics = [ProgramMetric](
            repeating: ProgramMetric(programID: 0, activity: 0, entropyBitsPerByte: 0),
            count: programCount)

        soup.withUnsafeBufferPointer { soupPtr in
            activity.withUnsafeBufferPointer { actPtr in
                metrics.withUnsafeMutableBufferPointer { mPtr in
                    if parallel {
                        parallelMetrics(soupBase: soupPtr.baseAddress!,
                                        activity: actPtr.baseAddress!,
                                        metrics: mPtr.baseAddress!,
                                        programCount: programCount)
                    } else {
                        serialMetrics(soupBase: soupPtr.baseAddress!,
                                      activity: actPtr.baseAddress!,
                                      metrics: mPtr.baseAddress!,
                                      programCount: programCount)
                    }
                }
            }
        }
        return metrics
    }

    /// Serial metric construction: one reusable 256-bin buffer for all programs.
    /// Eliminates the per-program Array slice and 256-bin allocation of the legacy
    /// `entropyBitsPerByte(Array(soup[start..<...]))` path.
    private static func serialMetrics(soupBase: UnsafePointer<UInt8>,
                                      activity: UnsafePointer<Int>,
                                      metrics: UnsafeMutablePointer<ProgramMetric>,
                                      programCount: Int) {
        var bins = [UInt64](repeating: 0, count: 256)
        bins.withUnsafeMutableBufferPointer { binPtr in
            let binBase = binPtr.baseAddress!
            for id in 0..<programCount {
                let start = id * BFF.tapeSize
                let h = entropyBitsPerByte(soupBase: soupBase, start: start,
                                           length: BFF.tapeSize, bins: binBase)
                metrics[id] = ProgramMetric(programID: id, activity: activity[id],
                                            entropyBitsPerByte: h)
            }
        }
    }

    /// Parallel metric construction across CPU cores. Each chunk gets its own
    /// 256-bin buffer (no shared mutable state); output writes are to disjoint
    /// program-ID indices, so the result is element-for-element identical to the
    /// serial path regardless of how chunks are scheduled. `concurrentPerform` is
    /// synchronous, so the function returns only after every chunk is done.
    private static func parallelMetrics(soupBase: UnsafePointer<UInt8>,
                                        activity: UnsafePointer<Int>,
                                        metrics: UnsafeMutablePointer<ProgramMetric>,
                                        programCount: Int) {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunk = (programCount + cores - 1) / cores
        // Wrap the raw pointers in an `@unchecked Sendable` container so the
        // `concurrentPerform` closure (which is `@Sendable` under Swift 6) can capture
        // them. Safety rests on the disjoint-index discipline: each concurrent
        // iteration writes to a unique program ID (no aliasing), and `soup`/`activity`
        // are read-only during the parallel section. `ProgramMetric` is a trivial
        // struct (Int/Int/Double — no reference counting), so disjoint pointer stores
        // are plain memory writes with no retain/release races.
        let ctx = ParallelContext(soup: soupBase, activity: activity, metrics: metrics)
        DispatchQueue.concurrentPerform(iterations: cores) { c in
            let lo = c * chunk
            let hi = min(lo + chunk, programCount)
            guard lo < hi else { return }
            var bins = [UInt64](repeating: 0, count: 256)
            bins.withUnsafeMutableBufferPointer { binPtr in
                let binBase = binPtr.baseAddress!
                for id in lo..<hi {
                    let start = id * BFF.tapeSize
                    let h = entropyBitsPerByte(soupBase: ctx.soup, start: start,
                                               length: BFF.tapeSize, bins: binBase)
                    ctx.metrics[id] = ProgramMetric(programID: id, activity: ctx.activity[id],
                                                    entropyBitsPerByte: h)
                }
            }
        }
    }

    /// Race-free pointer bundle for `concurrentPerform`. `@unchecked Sendable`
    /// because the parallel section writes to disjoint indices (no aliasing) and
    /// reads only from immutable buffers; see `parallelMetrics` for the invariant.
    fileprivate struct ParallelContext: @unchecked Sendable {
        let soup: UnsafePointer<UInt8>
        let activity: UnsafePointer<Int>
        let metrics: UnsafeMutablePointer<ProgramMetric>
    }
}
