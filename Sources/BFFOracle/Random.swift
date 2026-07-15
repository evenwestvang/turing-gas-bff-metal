/// Deterministic, counter-based randomness (01 §6, 02 §4).
///
/// All randomness in a run — soup initialization, mutation, pairing shuffle — derives
/// from stateless hashes of `(seed, stream, index)`. There is no stateful RNG, so a
/// run is a pure function of `(seed, config)` and any draw can be recomputed in
/// isolation (this is what makes the GPU port bit-checkable against this oracle).
///
/// This is *our* production RNG. It is deliberately NOT cubff's RNG: bit-exact cubff
/// trajectory reproduction requires the separate `cubffCompat` mode of 01 §7.1, which
/// does not exist yet (see `Docs/GoldenVectors.md`).
public enum BFFRandom {

    /// Identifier for this RNG contract, recorded in golden fixtures so a fixture
    /// can never be compared against a run using different randomness.
    public static let contractID = "counter-pcg-v1"

    /// PCG-XSH-RR-style 32-bit mix (02 §4, verbatim port of `pcg_hash`).
    @inlinable
    public static func pcgHash(_ input: UInt32) -> UInt32 {
        let x = input &* 747_796_405 &+ 2_891_336_453
        let w = ((x >> ((x >> 28) &+ 4)) ^ x) &* 277_803_737
        return (w >> 22) ^ w
    }

    /// Counter-based draw: `pcg_hash(pcg_hash(seed ^ stream * 0x9E3779B9) ^ idx)`.
    @inlinable
    public static func rng3(seed: UInt32, stream: UInt32, index: UInt32) -> UInt32 {
        pcgHash(pcgHash(seed ^ (stream &* 0x9E37_79B9)) ^ index)
    }

    /// Stream IDs: `stream = epoch * 4 + pass` (02 §4).
    public enum Pass: UInt32, Sendable {
        case mutate = 0
        case pairing = 1
        case soupInit = 2
        case selfRep = 3
    }

    @inlinable
    public static func stream(epoch: UInt32, pass: Pass) -> UInt32 {
        epoch &* 4 &+ pass.rawValue
    }

    // MARK: - Soup initialization

    /// N × 64 uniform random bytes. Byte `i` is the low 8 bits of a `.soupInit`
    /// draw at epoch 0 with index `i` (the low-8-bits convention matches the mutate
    /// kernel's `& 0xFF`; the spec fixes the streams but not this extraction, so it
    /// is pinned here as part of the `counter-pcg-v1` contract).
    public static func initialSoup(programs: Int, seed: UInt32) -> [UInt8] {
        precondition(programs > 0)
        let byteCount = programs * BFF.tapeSize
        var soup = [UInt8](repeating: 0, count: byteCount)
        let s = stream(epoch: 0, pass: .soupInit)
        for i in 0..<byteCount {
            soup[i] = UInt8(truncatingIfNeeded: rng3(seed: seed, stream: s, index: UInt32(i)))
        }
        return soup
    }

    // MARK: - Mutation

    /// Exact per-byte Bernoulli mutation, verbatim port of `bff_mutate` (02 §7):
    /// byte `i` is replaced iff `rng3(seed, epoch*4+0, i) < mutationP32`, and the
    /// replacement is the low 8 bits of a second draw at index `i ^ 0x80000000`.
    /// The replacement is uniform over 0–255 and may be 0 or a command byte.
    /// `mutationP32 == 0` is a supported mode and leaves the soup untouched.
    public static func mutate(
        soup: inout [UInt8], seed: UInt32, epoch: UInt32, mutationP32: UInt32
    ) {
        guard mutationP32 > 0 else { return }
        let s = stream(epoch: epoch, pass: .mutate)
        for i in 0..<soup.count {
            let idx = UInt32(i)
            if rng3(seed: seed, stream: s, index: idx) < mutationP32 {
                soup[i] = UInt8(truncatingIfNeeded:
                    rng3(seed: seed, stream: s, index: idx ^ 0x8000_0000))
            }
        }
    }

    // MARK: - Pairing

    /// Well-mixed pairing (01 §4): a Fisher–Yates shuffle of `0..<count`; consecutive
    /// entries `(2i, 2i+1)` form pair `i`. Every program appears exactly once.
    ///
    /// Draw convention (pinned as part of `counter-pcg-v1`): the swap partner for
    /// position `i` (iterating `i = count-1` down to `1`) is
    /// `rng3(seed, epoch*4+1, i) % (i+1)`. Modulo reduction has negligible bias at
    /// these ranges and keeps the draw one-hash-per-swap; determinism, not
    /// statistical perfection, is the contract.
    public static func pairingPermutation(count: Int, seed: UInt32, epoch: UInt32) -> [UInt32] {
        precondition(count > 0 && count % 2 == 0, "population must be positive and even")
        var perm = [UInt32](0..<UInt32(count))
        let s = stream(epoch: epoch, pass: .pairing)
        var i = count - 1
        while i > 0 {
            let r = rng3(seed: seed, stream: s, index: UInt32(i))
            let j = Int(r % UInt32(i + 1))
            perm.swapAt(i, j)
            i -= 1
        }
        return perm
    }
}
