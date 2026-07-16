/// Deterministic 2-D layout of the soup's stable program IDs (03 §1).
///
/// The soup is a *set*; the grid imposes an honest row-major layout that never
/// changes, so a program cell can be watched over time (identity is stable — the
/// same guarantee `PairIdentity` gives the evaluator). Each program renders as an
/// 8×8 block of byte cells (byte `j` at in-block `(j % 8, j / 8)`, reading order =
/// tape order).
///
/// Coordinates are the architecture's **canonical 512×256 program coordinate
/// canvas** (03 §1): stable program ID `i` maps to cell
/// `(column: i % 512, row: i / 512)`, giving a global byte grid of 4096×2048. The
/// canvas dimensions are fixed and *independent of the program count* — configured
/// modest soups fill the first row-major cells and every remaining cell through
/// 512×256 is padding/background that must never index the soup or the metric
/// field. The renderer and the shader both guard on `programCount`, never on
/// `width · height`. The populated sub-rectangle (`populatedColumns` ×
/// `populatedRows`) is exposed only so the camera can frame the occupied extent;
/// the coordinates themselves stay canonical.
///
/// Pure value type: no Metal, fully testable on any platform.
public struct ProgramGrid: Equatable, Sendable {
    /// Number of real programs laid out (`0 < programCount ≤ capacity`).
    public let programCount: Int
    /// Columns of program cells (canonical 512).
    public let width: Int
    /// Rows of program cells (canonical 256).
    public let height: Int

    /// Canonical program-canvas columns (03 §1).
    public static let canonicalWidth = 512
    /// Canonical program-canvas rows (03 §1).
    public static let canonicalHeight = 256
    /// Programs the canonical 512×256 canvas can hold (`512 · 256 = 131072`). Program
    /// counts above this are rejected at app launch/config validation.
    public static let capacity = canonicalWidth * canonicalHeight

    /// Byte cells along each program-block edge (fixed 8×8 = 64 bytes).
    public static let blockEdge = 8

    public init(programCount: Int) {
        precondition(programCount > 0, "programCount must be positive")
        precondition(programCount <= Self.capacity,
                     "programCount \(programCount) exceeds the 512×256 canonical "
                     + "canvas capacity \(Self.capacity)")
        self.programCount = programCount
        self.width = Self.canonicalWidth
        self.height = Self.canonicalHeight
    }

    /// Total cells including padding (`width · height` = 131072).
    public var cellCount: Int { width * height }

    /// Trailing padded (non-program) cells (`cellCount − programCount ≥ 0`).
    public var paddedCellCount: Int { cellCount - programCount }

    /// Soup byte-space extent: `width · 8` (4096) by `height · 8` (2048) byte cells.
    public var byteWidth: Int { width * Self.blockEdge }
    /// Soup byte-space height in byte cells.
    public var byteHeight: Int { height * Self.blockEdge }

    // MARK: - Populated extent (camera framing only; coordinates stay canonical)

    /// Columns occupied by real programs: `min(programCount, width)`.
    public var populatedColumns: Int { Swift.min(programCount, width) }
    /// Rows occupied by real programs: `⌈programCount / width⌉`.
    public var populatedRows: Int { (programCount + width - 1) / width }
    /// Byte-space width of the populated sub-rectangle (`populatedColumns · 8`).
    public var populatedByteWidth: Int { populatedColumns * Self.blockEdge }
    /// Byte-space height of the populated sub-rectangle (`populatedRows · 8`).
    public var populatedByteHeight: Int { populatedRows * Self.blockEdge }

    /// The program at grid cell `(col, row)`, or `nil` when the cell is padding
    /// (`index ≥ programCount`) or out of the canonical grid. Never returns an index
    /// that would read outside the soup.
    public func programIndex(col: Int, row: Int) -> Int? {
        guard col >= 0, col < width, row >= 0, row < height else { return nil }
        let index = row * width + col
        return index < programCount ? index : nil
    }

    /// The canonical grid cell `(col, row)` holding program `index`:
    /// `(index % 512, index / 512)`.
    public func cell(of index: Int) -> (col: Int, row: Int) {
        precondition(index >= 0 && index < programCount, "program index out of range")
        return (index % width, index / width)
    }

    /// Byte offset within a program for the byte cell at in-block `(x, y)` in
    /// `0..<8`. Reading order equals tape order: `j = y · 8 + x`.
    public static func byteOffset(inBlockX x: Int, inBlockY y: Int) -> Int {
        precondition((0..<blockEdge).contains(x) && (0..<blockEdge).contains(y),
                     "in-block coordinate out of 0..<8")
        return y * blockEdge + x
    }
}
