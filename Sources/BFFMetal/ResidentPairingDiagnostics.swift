import BFFOracle

/// Planner choices exposed only by the experimental resident epoch product.
public enum ResidentPairingPlanner: String, Equatable, Sendable, Codable {
    case keyed
    case cpuUpload = "cpu-upload"

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)

        public var description: String {
            switch self {
            case .unknown(let value):
                return "unknown planner '\(value)' (use keyed or cpu-upload)"
            }
        }
    }

    public init(cliValue: String) throws {
        switch cliValue {
        case "keyed":
            self = .keyed
        case "cpu-upload":
            self = .cpuUpload
        default:
            throw ParseError.unknown(cliValue)
        }
    }

    public var cliValue: String {
        switch self {
        case .keyed: return "keyed"
        case .cpuUpload: return "cpu-upload"
        }
    }

    public var identifier: String {
        switch self {
        case .keyed:
            return BFFRandom.residentPairingModeID
        case .cpuUpload:
            return "cpu-upload-fisher-yates-v1"
        }
    }

    public func permutation(count: Int, seed: UInt32, epoch: UInt32) -> [UInt32] {
        switch self {
        case .keyed:
            return BFFRandom.residentPairingPermutation(count: count, seed: seed, epoch: epoch)
        case .cpuUpload:
            return BFFRandom.pairingPermutation(count: count, seed: seed, epoch: epoch)
        }
    }
}

/// FNV-1a 64-bit fingerprint over a permutation's UInt32 entries in little-endian
/// byte order. This is a deterministic equality fingerprint, not a cryptographic hash.
public enum PermutationDigest {
    public static func digest(_ permutation: [UInt32]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for value in permutation {
            var x = value
            for _ in 0..<4 {
                hash = (hash ^ UInt64(x & 0xFF)) &* prime
                x >>= 8
            }
        }
        return hash
    }
}

/// Coarse CPU-side distribution diagnostics for resident pairing permutations.
///
/// Distance histogram bins are absolute pair-ID distances:
/// `0`, `1`, `2...3`, `4...7`, `8...15`, `16...31`, `32...63`, `64...127`,
/// `128...255`, `256...511`, `512...1023`, and `1024...`.
public struct PairingDistributionDiagnostics: Equatable, Sendable, Codable {
    public struct DistanceBin: Equatable, Sendable, Codable {
        public var label: String
        public var count: Int

        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    public var fixedPointCount: Int
    public var adjacentIDPairCount: Int
    public var meanAbsolutePairIDDistance: Double
    public var distanceHistogram: [DistanceBin]

    public static let distanceBinLabels = [
        "0", "1", "2...3", "4...7", "8...15", "16...31",
        "32...63", "64...127", "128...255", "256...511",
        "512...1023", "1024..."
    ]

    public static func analyze(permutation: [UInt32]) -> PairingDistributionDiagnostics {
        precondition(permutation.count > 0 && permutation.count % 2 == 0,
                     "permutation population must be positive and even")

        var fixedPoints = 0
        for (slot, programID) in permutation.enumerated() where UInt32(slot) == programID {
            fixedPoints += 1
        }

        var adjacentPairs = 0
        var totalDistance: UInt64 = 0
        var bins = [Int](repeating: 0, count: distanceBinLabels.count)
        for pairIndex in 0..<(permutation.count / 2) {
            let a = Int(permutation[2 * pairIndex])
            let b = Int(permutation[2 * pairIndex + 1])
            let distance = abs(a - b)
            if distance == 1 { adjacentPairs += 1 }
            totalDistance += UInt64(distance)
            bins[binIndex(forDistance: distance)] += 1
        }

        let pairCount = permutation.count / 2
        let histogram = zip(distanceBinLabels, bins).map {
            DistanceBin(label: $0.0, count: $0.1)
        }
        return PairingDistributionDiagnostics(
            fixedPointCount: fixedPoints,
            adjacentIDPairCount: adjacentPairs,
            meanAbsolutePairIDDistance: Double(totalDistance) / Double(pairCount),
            distanceHistogram: histogram)
    }

    private static func binIndex(forDistance distance: Int) -> Int {
        switch distance {
        case 0: return 0
        case 1: return 1
        case 2...3: return 2
        case 4...7: return 3
        case 8...15: return 4
        case 16...31: return 5
        case 32...63: return 6
        case 64...127: return 7
        case 128...255: return 8
        case 256...511: return 9
        case 512...1023: return 10
        default: return 11
        }
    }
}
