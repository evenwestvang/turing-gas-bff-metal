import Foundation

/// Resident visualization selection identifiers and their fixed, replay-stable
/// normalization helpers. The four selections are the resident-path meanings of
/// the existing `metricChannel` uniform word:
///
/// - `0`: the producer's current RGB composite, presented as bounded low-chroma
///   Composite.
/// - `1`: resident visualization R, interaction command steps.
/// - `2`: resident visualization G, opcode-byte density.
/// - `3`: resident visualization B, structural mean/XOR fingerprint.
///
/// Important distinctions:
///
/// 1. They are backed by **GPU-resident data** — the `bff_resident_visualize`
///    kernel writes one normalized texel per program into the resident
///    visualization texture from the resident soup, the per-program activity
///    buffer, and soup-derived component counts/fingerprints. No full soup CPU
///    readback happens per epoch to produce them.
/// 2. The selector does not request new producer data. The resident producer
///    already writes the RGB composite with these component meanings; the render
///    shader either presents that composite or views one component through one
///    shared restrained scalar palette.
///
/// Naming separation: these types are prefixed `ResidentViz…` / `VizEntropy…`
/// and live in `SoupScopeCore`. They are deliberately named **apart** from the
/// paper-aligned Brotli / high-order scientific observability in `BrotliMetrics`
/// and `BFFMetal.Benchmark*`, and from the CPU-side `ByteHistogram` /
/// `SoupMetrics.entropyBitsPerByte` used in fixtures and parity. The
/// visualization entropy is a GPU-computed, float-precision, fixed-point-readback
/// approximation; the scientific entropy is a CPU-computed, double-precision,
/// paper-aligned measurement on a different cadence. The two must never share a
/// type, a buffer, or a name — see `testVizEntropyHistoryIsSemanticallySeparate`.
///
/// Pure value types; no Metal.

// MARK: - Resident fast-view identifiers

/// The four resident visualization fast views. The raw values match the
/// `metricChannel` uniform word in `VizUniforms`, so the render shell's existing
/// channel-cycling UI (`AppModel.cycleMetricChannel`) and the HUD label can be
/// shared between the resident and non-resident paths.
public enum ResidentVizChannel: UInt32, Equatable, Hashable, Sendable, CaseIterable {
    /// The existing resident RGB composite, presented as Composite.
    case composite = 0
    /// R component: interaction command steps, scaled by the resident producer.
    case interactionCommandSteps = 1
    /// G component: count/density of opcode bytes in the 64-byte program.
    case opcodeByteDensity = 2
    /// B component: structural fingerprint from byte mean and positional XOR.
    case structuralMeanXORFingerprint = 3

    /// Default fast view: Composite presentation of the current resident RGB.
    public static let defaultChannel: ResidentVizChannel = .composite

    /// Number of exposed resident fast selections. Kept as a `UInt32` so the app
    /// can cycle the `VizUniforms.metricChannel` word without changing ABI layout.
    public static var selectionCount: UInt32 { UInt32(allCases.count) }

    /// Cycle the raw uniform selector through exactly the supported resident
    /// fast selections. An out-of-range current value snaps back to the default
    /// instead of accidentally selecting a legacy shader fallback.
    public static func cyclingRawValue(after rawValue: UInt32) -> UInt32 {
        guard rawValue < selectionCount else { return defaultChannel.rawValue }
        return (rawValue + 1) % selectionCount
    }

    /// Short human-readable label suitable for a HUD line or overlay legend.
    /// These strings are deliberately truthful to the resident producer's RGB
    /// component meanings.
    public var label: String {
        switch self {
        case .composite:
            return "Composite"
        case .interactionCommandSteps:
            return "Interaction command steps — R"
        case .opcodeByteDensity:
            return "Opcode-byte density — G"
        case .structuralMeanXORFingerprint:
            return "Structural mean/XOR fingerprint — B"
        }
    }

    /// Axis/legend unit string for the channel, e.g. `"bits / byte"`.
    public var unit: String {
        switch self {
        case .composite:
            return "resident RGB"
        case .interactionCommandSteps:
            return "resident R"
        case .opcodeByteDensity:
            return "resident G"
        case .structuralMeanXORFingerprint:
            return "resident B"
        }
    }
}

/// Component slots inside the resident RGB texel. The raw value is the zero-based
/// component index used by texture/component APIs: R = 0, G = 1, B = 2.
public enum ResidentVizComponent: Int, Equatable, Hashable, Sendable, CaseIterable {
    case red = 0
    case green = 1
    case blue = 2

    public var componentIndex: Int { rawValue }

    public var channel: ResidentVizChannel {
        switch self {
        case .red:
            return .interactionCommandSteps
        case .green:
            return .opcodeByteDensity
        case .blue:
            return .structuralMeanXORFingerprint
        }
    }

    public func value(in rgb: RGB) -> Double {
        switch self {
        case .red:
            return rgb.r
        case .green:
            return rgb.g
        case .blue:
            return rgb.b
        }
    }
}

/// Stable resident selector decision: selector 0 presents the resident producer's
/// RGB composite; selectors 1...3 view a single component. Invalid selectors fall
/// back to the composite so legacy or out-of-contract callers do not invent a new
/// component interpretation.
public enum ResidentVizSelectorMapping: Equatable, Sendable {
    case composite
    case component(ResidentVizComponent)

    public static func selection(forRawValue rawValue: UInt32) -> ResidentVizSelectorMapping {
        switch rawValue {
        case 1:
            return .component(.red)
        case 2:
            return .component(.green)
        case 3:
            return .component(.blue)
        default:
            return .composite
        }
    }
}

public extension ResidentVizChannel {
    /// The component/composite decision represented by this valid channel.
    var selectorMapping: ResidentVizSelectorMapping {
        ResidentVizSelectorMapping.selection(forRawValue: rawValue)
    }
}

/// Shared scalar palette for resident component views. The shader mirrors these
/// muted blue/teal/red stops and interpolation exactly; this Swift helper is the
/// portable production contract used by tests and host-side legend/readout code.
public enum ResidentScalarPalette: Sendable {
    public static let low = RGB(hex: 0x324E67)
    public static let mid = RGB(hex: 0x4E8E86)
    public static let high = RGB(hex: 0xC97867)

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }

    private static func smoothstep01(_ value: Double) -> Double {
        let t = clamp01(value)
        return t * t * (3 - 2 * t)
    }

    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        if t <= 0 { return a }
        if t >= 1 { return b }
        return RGB(a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t)
    }

    public static func color(for value: Double) -> RGB {
        let t = clamp01(value)
        if t < 0.5 {
            return mix(low, mid, smoothstep01(t * 2))
        }
        return mix(mid, high, smoothstep01((t - 0.5) * 2))
    }
}

/// Resident macro color contract shared by overview and transition rendering:
/// composite selectors present the producer's RGB texel through a bounded
/// low-chroma transform, while component selectors pass the selected scalar
/// through `ResidentScalarPalette`. The producer's resident texture remains
/// unchanged.
public enum ResidentVizMacroColor: Sendable {
    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }

    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    public static func compositePresentation(residentRGB: RGB) -> RGB {
        let inverted = RGB(1.0 - clamp(residentRGB.r, lower: 0.0, upper: 1.0),
                           1.0 - clamp(residentRGB.g, lower: 0.0, upper: 1.0),
                           1.0 - clamp(residentRGB.b, lower: 0.0, upper: 1.0))
        let clamped = RGB(clamp(inverted.r, lower: 0.20, upper: 0.80),
                          clamp(inverted.g, lower: 0.20, upper: 0.80),
                          clamp(inverted.b, lower: 0.20, upper: 0.80))
        let luminance = clamped.r * 0.2126 + clamped.g * 0.7152 + clamped.b * 0.0722
        let result = RGB(mix(luminance, clamped.r, 0.25),
                         mix(luminance, clamped.g, 0.25),
                         mix(luminance, clamped.b, 0.25))
        return RGB(clamp(result.r, lower: 0.20, upper: 0.80),
                   clamp(result.g, lower: 0.20, upper: 0.80),
                   clamp(result.b, lower: 0.20, upper: 0.80))
    }

    public static func color(residentRGB: RGB, selectorRawValue: UInt32) -> RGB {
        switch ResidentVizSelectorMapping.selection(forRawValue: selectorRawValue) {
        case .composite:
            return compositePresentation(residentRGB: residentRGB)
        case .component(let component):
            return ResidentScalarPalette.color(for: component.value(in: residentRGB))
        }
    }
}

// MARK: - Fixed normalization

/// Fixed, replay-stable normalization helpers retained for resident
/// visualization-side summaries and overlays. Mirrors the discipline of
/// `MetricNormalization` (fixed bounds, never auto-scaling) but covers
/// resident-only signals and is kept as a separate type so the resident and
/// non-resident paths do not share stored state.
///
/// Bounds:
///  - **activity** and **runLength**: integer step counts divided by the run's
///    fixed `stepBudget` and clamped to `[0, 1]`. A pair can execute at most
///    `stepBudget` steps, so the clamp only guards against out-of-contract
///    input.
///  - **byteEntropy**: bits/byte divided by `entropyMax = 6` (the hard maximum
///    for a 64-byte window: `log2 64 = 6`) and clamped to `[0, 1]`.
///
/// Non-finite byte entropy is explicitly unavailable. `NaN`, `+infinity`,
/// and `-infinity` return `nil` rather than being coerced to a plausible
/// normalized endpoint. Activity and run length use integer inputs and are
/// therefore always finite.
public struct ResidentVizNormalization: Equatable, Sendable {
    /// Activity / run-length denominator (the run's fixed step budget).
    public let stepBudget: Int
    /// Entropy denominator; 6 bits/byte is the hard maximum for a 64-byte window.
    public let entropyMax: Double

    public init(stepBudget: Int, entropyMax: Double = 6) {
        precondition(stepBudget > 0, "step budget must be positive")
        precondition(entropyMax > 0, "entropy max must be positive")
        self.stepBudget = stepBudget
        self.entropyMax = entropyMax
    }

    /// Clamp a finite value into `[0, 1]`.
    @inline(__always)
    private static func normalize01(_ x: Double) -> Double {
        Swift.min(Swift.max(x, 0), 1)
    }

    /// Normalize an integer command-step activity into `[0, 1]`.
    public func normalizedActivity(_ commandSteps: Int) -> Double {
        Self.normalize01(Double(commandSteps) / Double(stepBudget))
    }

    /// Normalize an integer interaction run length (steps-to-halt) into `[0, 1]`.
    public func normalizedRunLength(_ steps: Int) -> Double {
        Self.normalize01(Double(steps) / Double(stepBudget))
    }

    /// Normalize a bits/byte byte-entropy visualization approximation into
    /// `[0, 1]`. Any non-finite value is unavailable and returns `nil`;
    /// finite values preserve fixed-bound clamping.
    public func normalizedByteEntropy(_ entropyBitsPerByte: Double) -> Double? {
        guard entropyBitsPerByte.isFinite else { return nil }
        return Self.normalize01(entropyBitsPerByte / entropyMax)
    }

    /// Decode the GPU's fixed-point mean-entropy accumulator (8 fractional bits)
    /// back to bits/byte in `[0, 6]`. The kernel writes
    /// `Σ_per_program truncate(entropy × 256)`; dividing by `programCount × 256`
    /// yields the mean entropy. Non-finite / out-of-range input decodes to `0`.
    public static func decodeMeanByteEntropy(sumFP8: UInt32, programCount: Int) -> Double {
        guard programCount > 0 else { return 0 }
        let raw = Double(sumFP8) / (Double(programCount) * 256.0)
        guard raw.isFinite else { return 0 }
        return Swift.min(Swift.max(raw, 0), 6.0)
    }
}

// MARK: - Bounded entropy-over-time history

/// One epoch's aggregate visualization-entropy sample for the
/// entropy-over-time overlay. Carries the epoch index and the mean per-program
/// byte entropy (bits/byte, `[0, 6]`) as decoded from the GPU's fixed-point
/// summary accumulator.
///
/// This is a **visualization-grade** sample. It is computed on the GPU and read
/// back as a single `UInt32` — never a full soup readback — and it is not
/// bit-identical to the CPU-side `ByteHistogram.shannonEntropyBitsPerByte` path
/// (Metal `float` vs Swift `Double`, atomic summation order). It exists to
/// drive a compact sparkline, not to feed a paper metric.
public struct VizEntropySample: Equatable, Sendable {
    /// The resident epoch this sample describes (0-based, post-advance).
    public var epoch: Int
    /// Mean per-program byte entropy, bits/byte in `[0, 6]`.
    public var meanByteEntropyBitsPerByte: Double

    public init(epoch: Int, meanByteEntropyBitsPerByte: Double) {
        self.epoch = epoch
        self.meanByteEntropyBitsPerByte = meanByteEntropyBitsPerByte
    }
}

/// A bounded ring buffer of `VizEntropySample`s for the entropy-over-time
/// overlay. Storage is bounded: at most `capacity` samples are retained, with
/// oldest-first eviction. Coalescing semantics: recording a sample for the
/// same epoch as the buffer's tail replaces the tail (latest-value-wins), so
/// asynchronous report delivery that lands multiple updates for one epoch
/// before the UI refreshes can never accumulate unbounded intermediate values.
///
/// Epochs are assumed to arrive in monotonically increasing order — the
/// resident driver's report callback fires on the main queue from a serial
/// simulation queue, so this invariant holds. The coalescing path handles the
/// only realistic duplicate (the tail); an out-of-order duplicate is treated as
/// a new sample, which is the documented contract.
///
/// Pure value type; no Metal, no clock, no Foundation collections beyond a
/// simple array — fully testable on Linux.
public struct VizEntropyHistory: Equatable, Sendable {
    /// Default capacity: enough for a meaningful sparkline without unbounded
    /// growth. Chosen so that at 60 epochs/sec the window covers ~4 seconds.
    public static let defaultCapacity = 256

    public let capacity: Int
    private var samples: [VizEntropySample]

    public init(capacity: Int = VizEntropyHistory.defaultCapacity) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.samples = []
        self.samples.reserveCapacity(capacity)
    }

    /// Number of samples currently retained (`0 … capacity`).
    public var count: Int { samples.count }

    /// True when no samples have been recorded.
    public var isEmpty: Bool { samples.isEmpty }

    /// The retained samples in epoch order (oldest first, latest last).
    public var allSamples: [VizEntropySample] { samples }

    /// The most recently recorded sample, or `nil` if empty.
    public var latest: VizEntropySample? { samples.last }

    /// The earliest retained sample, or `nil` if empty.
    public var earliest: VizEntropySample? { samples.first }

    /// Record one epoch's sample. Non-finite entropy values are rejected rather
    /// than coerced into a plotted endpoint. If the sample's epoch matches the
    /// buffer's tail epoch, the tail is replaced (coalescing); otherwise the
    /// sample is appended, evicting the oldest if the buffer is at capacity.
    @discardableResult
    public mutating func record(_ sample: VizEntropySample) -> Bool {
        guard sample.meanByteEntropyBitsPerByte.isFinite else { return false }
        if let last = samples.last, last.epoch == sample.epoch {
            samples[samples.count - 1] = sample
            return false                    // coalesced, did not grow
        }
        if samples.count >= capacity {
            samples.removeFirst()
        }
        samples.append(sample)
        return true                         // grew
    }
}

// MARK: - Mean-entropy decoding helpers for the host

/// Pure helpers that translate a resident epoch report's instrumentation into a
/// `VizEntropySample` for the history. Kept here (not on
/// `ResidentEpochInstrumentation`) so the SoupScopeCore pure layer has no
/// dependency on `BFFMetal`'s report type beyond the field it reads — the
/// caller passes the decoded `Double` straight in.
public enum VizEntropySampleDecoder {
    /// Build a sample from the already-decoded mean byte entropy. Returns `nil`
    /// if the instrumentation did not carry a visualization entropy value
    /// (e.g. visualization was disabled, or the CPU reference runner on a host
    /// where the summary was not read back).
    public static func sample(epoch: Int, meanByteEntropy: Double?) -> VizEntropySample? {
        guard let meanByteEntropy, meanByteEntropy.isFinite else { return nil }
        return VizEntropySample(epoch: epoch,
                                meanByteEntropyBitsPerByte: meanByteEntropy)
    }
}
