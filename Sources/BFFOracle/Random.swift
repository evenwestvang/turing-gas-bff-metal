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

    /// A soup of `programs * 64` bytes all equal to `byte` (default 0). A fully
    /// ordered, zero-Shannon-entropy starting state. Additive and independent of the
    /// uniform `initialSoup` path — it does not touch the RNG streams, so choosing it
    /// cannot perturb any subsequent mutation/pairing draw. Intended for measuring
    /// entropy *increase* from a known floor; with `byte == 0` the soup is inert
    /// (every byte is a no-op) and dynamics are driven purely by mutation.
    public static func constantSoup(programs: Int, byte: UInt8 = 0) -> [UInt8] {
        precondition(programs > 0)
        return [UInt8](repeating: byte, count: programs * BFF.tapeSize)
    }

    /// A reproducible low-entropy soup drawn from a small alphabet (default: the ten
    /// BFF opcode bytes, `BFFOp.all`). Deterministic under `counter-pcg-v1`,
    /// reproducible across machines, and it adds no new RNG. Unlike an all-zero soup
    /// this seeds the soup with *executable* opcodes, so interactions do real work
    /// from epoch 0 while the order-0 Shannon entropy still starts low
    /// (≤ log2(alphabet.count) bits/byte) — the intended regime for observing entropy
    /// growth. The uniform `initialSoup` is unchanged and remains the default.
    ///
    /// Exact contract (pinned by `StructureMetricsTests`; do NOT change without
    /// re-pinning, as it would change every `.opcode` trajectory):
    ///
    /// - **Alphabet — the ten command bytes.** The default `alphabet` is `BFFOp.all`,
    ///   whose byte VALUES are exactly the ten commands of cubff's `CommandRepr`
    ///   `"[]+-.,<>{}"` (`0x5B 0x5D 0x2B 0x2D 0x2E 0x2C 0x3C 0x3E 0x7B 0x7D`). NB the
    ///   index ORDER of `BFFOp.all` is its own — `< > { } + - . , [ ]`
    ///   (`0x3C 0x3E 0x7B 0x7D 0x2B 0x2D 0x2E 0x2C 0x5B 0x5D`), NOT the `CommandRepr`
    ///   order — and that index order is what the modulo below selects into.
    /// - **Stream/index mapping.** Byte `i` uses the SAME draw the uniform path uses:
    ///   `draw = rng3(seed, stream(epoch: 0, pass: .soupInit), index: UInt32(i))`,
    ///   i.e. stream `0*4 + 2 = 2` and index = the byte position `i`.
    /// - **Symbol selection is `draw % alphabet.count`** (= `draw % 10` for the
    ///   default alphabet): `soup[i] = alphabet[Int(draw % n)]`.
    /// - **Modulo bias contract.** `draw` is a uniform `UInt32` over `[0, 2^32)`.
    ///   `2^32 = 429496729 * 10 + 6`, so residues `0...5` each occur one extra time:
    ///   the ten symbols are NOT perfectly equiprobable (indices `0...5` are favored
    ///   by ~1 part in 4.3e8). This negligible, fully-deterministic bias is the
    ///   pinned contract — the same one the pairing shuffle documents — chosen for a
    ///   one-hash-per-byte draw over statistical perfection.
    /// - **Relation to the epoch loop.** This runs once at epoch 0. Thereafter each
    ///   epoch mutates BEFORE pairing/evaluation (`SoupPlanner.plan`: mutate stream
    ///   `epoch*4+0`, then pairing stream `epoch*4+1`), at the default per-byte
    ///   probability `BFF.defaultMutationP32 = 1<<20` (= 1/4096) unless overridden.
    public static func opcodeSoup(programs: Int, seed: UInt32,
                                  alphabet: [UInt8] = BFFOp.all) -> [UInt8] {
        precondition(programs > 0)
        precondition(!alphabet.isEmpty, "alphabet must be non-empty")
        let byteCount = programs * BFF.tapeSize
        var soup = [UInt8](repeating: 0, count: byteCount)
        let s = stream(epoch: 0, pass: .soupInit)
        let n = UInt32(alphabet.count)
        for i in 0..<byteCount {
            let draw = rng3(seed: seed, stream: s, index: UInt32(i))
            soup[i] = alphabet[Int(draw % n)]
        }
        return soup
    }

    // MARK: - Mutation

    /// Exact per-byte Bernoulli mutation, verbatim port of `bff_mutate` (02 §7):
    /// byte `i` is replaced iff `rng3(seed, epoch*4+0, i) < mutationP32`, and the
    /// replacement is the low 8 bits of a second draw at index `i ^ 0x80000000`.
    /// The replacement is uniform over 0–255 and may be 0 or a command byte.
    /// `mutationP32 == 0` is a supported mode and leaves the soup untouched.
    ///
    /// Returns the number of bytes whose mutation predicate fired — i.e. draws
    /// that satisfied `< mutationP32`, counted whether or not the replacement byte
    /// happened to equal the original. This is the single source of truth for the
    /// "mutation count" epoch diagnostic; it is intrinsic to the draw stream and
    /// adds no new randomness. (`@discardableResult` so existing callers that only
    /// want the in-place effect are unaffected.)
    @discardableResult
    public static func mutate(
        soup: inout [UInt8], seed: UInt32, epoch: UInt32, mutationP32: UInt32
    ) -> Int {
        guard mutationP32 > 0 else { return 0 }
        let s = stream(epoch: epoch, pass: .mutate)
        var mutated = 0
        for i in 0..<soup.count {
            let idx = UInt32(i)
            if rng3(seed: seed, stream: s, index: idx) < mutationP32 {
                soup[i] = UInt8(truncatingIfNeeded:
                    rng3(seed: seed, stream: s, index: idx ^ 0x8000_0000))
                mutated += 1
            }
        }
        return mutated
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
