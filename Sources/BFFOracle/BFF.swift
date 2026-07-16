/// Core constants and types for the BFF interpreter.
///
/// Normative source: `Docs/Architecture/01-bff-spec.md`, grounded against cubff at
/// commit `f212e849027c98fcf4b242eccfb5fed435223e23` (see `Docs/CubffGrounding.md`).
/// Evaluator-level parity with cubff is proven by the fixtures in
/// `Tests/BFFOracleTests/Fixtures/cubff-evaluator-v1.json`; simulation-level (RNG,
/// shuffle, mutation-stream) parity is intentionally NOT claimed — the oracle keeps
/// its own `counter-pcg-v1` contract.

/// Fixed sizes and defaults (01 §1).
public enum BFF {
    /// Bytes per program (`kSingleTapeSize`).
    public static let tapeSize = 64
    /// Bytes in a paired interaction tape (two programs concatenated).
    public static let pairTapeSize = 128
    /// Steps per interaction before a `BUDGET` halt.
    public static let stepBudget = 8192
    /// Default soup population (128 * 1024 programs). Tests use much smaller values.
    public static let defaultSoupPrograms = 131_072
    /// Per-byte per-epoch mutation threshold: mutate iff a uniform `UInt32` draw is
    /// `< mutationP32`. Default `2^20 / 2^32 = 1/4096`.
    public static let defaultMutationP32: UInt32 = 1 << 20
}

/// The ten command byte values, using the ASCII table of 01 §2 (cubff `CommandRepr`
/// `"[]+-.,<>{}"`). All other 246 byte values — including 0, the "null" the loop
/// commands test against — are inert no-ops when executed.
///
/// The exact byte values matter dynamically: e.g. under ASCII, `+` applied twice turns
/// `[` (0x5B) into `]` (0x5D). This is alignment tag 1 of 01 §7.4 — CONFIRMED against
/// cubff `bff.inc.h` `GetOpKind` (ASCII case labels; byte 0 is `kNull`, everything
/// else `kNoop`). See Docs/CubffGrounding.md §1.
public enum BFFOp {
    public static let head0Left: UInt8 = 0x3C   // '<'  head0 -= 1
    public static let head0Right: UInt8 = 0x3E  // '>'  head0 += 1
    public static let head1Left: UInt8 = 0x7B   // '{'  head1 -= 1
    public static let head1Right: UInt8 = 0x7D  // '}'  head1 += 1
    public static let inc: UInt8 = 0x2B         // '+'  tape[head0] += 1 (wrapping)
    public static let dec: UInt8 = 0x2D         // '-'  tape[head0] -= 1 (wrapping)
    public static let write: UInt8 = 0x2E       // '.'  tape[head1] = tape[head0]
    public static let read: UInt8 = 0x2C        // ','  tape[head0] = tape[head1]
    public static let loopOpen: UInt8 = 0x5B    // '['  if tape[head0] == 0 jump past match
    public static let loopClose: UInt8 = 0x5D   // ']'  if tape[head0] != 0 jump back past match

    /// All ten command bytes.
    public static let all: [UInt8] = [
        head0Left, head0Right, head1Left, head1Right,
        inc, dec, write, read, loopOpen, loopClose,
    ]
}

/// Why an interaction stopped (01 §3). Raw values match `BFFHaltReason` in the
/// (future) shared GPU header; 0 is reserved/never used.
public enum HaltReason: UInt8, Codable, Equatable, Sendable {
    /// The 8192-step budget was exhausted.
    case budget = 1
    /// The pc walked off either end of the 128-byte tape (pc does not wrap).
    case pcOut = 2
    /// A *taken* bracket had no match on the live tape (dynamic scan) or in the
    /// frozen table (jump-table mode).
    case unmatched = 3
}

/// Initial-state variant (01 §3).
public enum BFFVariant: String, Codable, Equatable, Sendable, CaseIterable {
    /// cubff repo default and our default: `pc = 0, head0 = 0, head1 = 0`.
    case noheads
    /// The paper's original `bff`: the first two tape bytes seed the head positions —
    /// `head0 = tape[0] % 128`, `head1 = tape[1] % 128`, `pc = 2`.
    /// Alignment tag 2 of 01 §7.4 — CONFIRMED against cubff `bff.inc.h`
    /// `InitialState` (BFF_HEADS) and `headpos`. See Docs/CubffGrounding.md §2.
    case seededHeads = "bff"
}

/// Bracket-matching strategy (01 §3, 02 §5, 06 D1).
public enum BracketMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Normative semantics: every taken bracket scans the *live, self-modified* tape
    /// for its match at the moment it executes. This is the oracle's default.
    case dynamicScan
    /// GPU fast path: matches are frozen in a jump table built from the tape as it
    /// was at interaction start. Programs that rewrite their own brackets mid-run see
    /// stale matches — the deliberate semantic risk tracked as 06 D1.
    case jumpTable
}

/// Per-interaction result. `steps`, `halt`, `copyWrites`, `loopOps` mirror the GPU
/// `ProgStats` fields; `remapEvents` is oracle-only instrumentation for D1.
public struct InteractionResult: Equatable, Sendable {
    /// Final 128-byte pair tape (both halves, after mutual modification).
    public var tape: [UInt8]
    /// Executed-op count. Every executed op costs exactly 1 step, including no-ops,
    /// non-taken brackets, and the taken-but-unmatched bracket that halts the run
    /// (matching cubff `bff.inc.h` `Evaluate`, where the loop counter `i` ticks for
    /// every executed byte and the halting iteration runs `i++` before breaking).
    /// Bracket *scanning* never counts (alignment tag 4, confirmed).
    public var steps: Int
    public var halt: HaltReason
    /// `.`/`,` executions whose heads were in different 64-byte halves.
    public var copyWrites: Int
    /// Bracket ops executed (taken or not).
    public var loopOps: Int
    /// Taken brackets whose live-scan match differed from the frozen jump-table entry
    /// — exactly the moments the jump-table fast path is wrong (01 §7.3). Counted in
    /// both bracket modes; only in `.jumpTable` mode does a remap actually alter
    /// execution.
    public var remapEvents: Int
    /// Executed steps that were "comments" in cubff terms: byte 0 and every
    /// non-command byte (cubff `EvaluateOne` returning false, counted as `nskip`).
    /// They consume step budget but are excluded from cubff's reported op count.
    public var noopSteps: Int

    /// cubff's observable op count: `Evaluate`'s return value `i - nskip`
    /// (`bff.inc.h`) — executed command bytes only, including non-taken brackets
    /// and the taken-but-unmatched bracket that halts the run.
    public var commandSteps: Int { steps - noopSteps }
}
