import Foundation

/// Ecology visualization fast-view identifiers and their fixed, replay-stable
/// meanings. The ecology overview producer (`bff_ecology_visualize`) writes one
/// RGBA texel per ecology **site** (512 × 256 = 131,072 sites) directly from
/// the live soup; the render shell either presents the composite or views one
/// component through a shared restrained scalar palette — exactly the resident
/// pattern, named apart so the two engines never share a type, buffer, or name.
///
/// Truthfulness contract (no overclaiming):
///
/// 1. Every channel is **soup-derived**: each texel is a deterministic
///    function of that site's 64 program bytes only (byte mean, opcode-byte
///    density, structural mean/XOR fingerprint). The producer never reads back
///    the full soup to the CPU and never computes a CPU digest.
/// 2. **Exact spatial metrics remain neutrally unavailable.** These channels
///    are *visualization-grade* scalar summaries; they are not energy, death,
///    movement, predation, fitness, reproduction, or paper reproduction. The
///    HUD/overlay explicitly labels them as unavailable rather than inventing
///    zeroes for spatial observability the producer does not expose.
///
/// The raw values match the `metricChannel` uniform word already cycled by the
/// shell's existing `AppModel.cycleMetricChannel`, so the four ecology
/// selections reuse the existing channel-cycling UI and HUD label plumbing.
public enum EcologyVizChannel: UInt32, Equatable, Hashable, Sendable, CaseIterable {
    /// The producer's RGB composite, presented as Composite.
    case composite = 0
    /// R component: opcode-byte density in the 64-byte program (count of the
    /// ten BFF command bytes), scaled by the producer.
    case opcodeByteDensity = 1
    /// G component: per-site byte mean (Σ bytes / 64), scaled by the producer.
    case byteMean = 2
    /// B component: structural fingerprint from positional XOR of the bytes.
    case structuralXORFingerprint = 3

    /// Default fast view: Composite presentation of the producer's RGB.
    public static let defaultChannel: EcologyVizChannel = .composite

    /// Number of exposed ecology fast selections. `UInt32` so it maps directly
    /// onto the `VizUniforms.metricChannel` word without ABI drift.
    public static var selectionCount: UInt32 { UInt32(allCases.count) }

    /// Cycle the raw uniform selector through exactly the supported ecology
    /// selections. An out-of-range current value snaps back to the default,
    /// matching the resident contract.
    public static func cyclingRawValue(after rawValue: UInt32) -> UInt32 {
        guard rawValue < selectionCount else { return defaultChannel.rawValue }
        return (rawValue + 1) % selectionCount
    }

    /// Short human-readable label for a HUD line or overlay legend. The
    /// strings are deliberately truthful to the producer's RGB component
    /// meanings and make no spatial-metric claim.
    public var label: String {
        switch self {
        case .composite:
            return "Composite"
        case .opcodeByteDensity:
            return "Opcode-byte density — R"
        case .byteMean:
            return "Byte mean — G"
        case .structuralXORFingerprint:
            return "Structural XOR fingerprint — B"
        }
    }

    /// Axis/legend unit string, e.g. `"bytes / site"`.
    public var unit: String {
        switch self {
        case .composite:
            return "ecology RGB"
        case .opcodeByteDensity:
            return "ecology R"
        case .byteMean:
            return "ecology G"
        case .structuralXORFingerprint:
            return "ecology B"
        }
    }
}

/// Truthful availability flags for ecology visualization observability. The
/// producer exposes RGB scalar summaries (soup-derived); exact spatial metrics
/// are neutrally unavailable. This type is the single source the HUD/overlay
/// consults so the UI never invents a metric the producer does not provide.
public struct EcologyVizAvailability: Equatable, Sendable {
    public var scalarChannelsAvailable: Bool
    public var spatialMetricsAvailable: Bool

    public init(scalarChannelsAvailable: Bool,
                spatialMetricsAvailable: Bool) {
        self.scalarChannelsAvailable = scalarChannelsAvailable
        self.spatialMetricsAvailable = spatialMetricsAvailable
    }

    /// Launch-time availability: the producer has not produced a frame yet, so
    /// scalar channels are unavailable until the first epoch report lands; exact
    /// spatial metrics are *never* available from this producer.
    public static let initial = EcologyVizAvailability(
        scalarChannelsAvailable: false,
        spatialMetricsAvailable: false)

    /// After the first ecology epoch report, the three soup-derived scalar
    /// channels are available; exact spatial metrics remain neutrally
    /// unavailable (never claimed).
    public static let afterFirstEpoch = EcologyVizAvailability(
        scalarChannelsAvailable: true,
        spatialMetricsAvailable: false)
}
