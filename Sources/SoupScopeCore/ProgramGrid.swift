/// Deterministic 2-D layout of the soup's stable program IDs (03 §1).
///
/// The soup is a *set*; the grid imposes an honest row-major layout that never
/// changes, so a program cell can be watched over time (identity is stable — the
/// same guarantee `PairIdentity` gives the evaluator). Program `i` sits at cell
/// `(i % width, i / width)`, and each program renders as an 8×8 block of byte
/// cells (byte `j` at in-block `(j % 8, j / 8)`, reading order = tape order).
///
/// Unlike the 03-doc default (`width = 2^⌈log2 √N⌉`, which assumes power-of-two
/// N), this sizing handles any positive even `programCount`: `width = ⌈√N⌉` and
/// `height = ⌈N / width⌉`, so `width · height ≥ N` with at most `width − 1` empty
/// trailing cells. Padded cells (`index ≥ programCount`) are not programs and must
/// render as background — the renderer and the shader both guard on
/// `programCount`, never on `width · height`.
///
/// Pure value type: no Metal, fully testable on any platform.
public struct ProgramGrid: Equatable, Sendable {
    /// Number of real programs laid out (`> 0`).
    public let programCount: Int
    /// Columns of program cells.
    public let width: Int
    /// Rows of program cells (`width · height ≥ programCount`).
    public let height: Int

    /// Byte cells along each program-block edge (fixed 8×8 = 64 bytes).
    public static let blockEdge = 8

    public init(programCount: Int) {
        precondition(programCount > 0, "programCount must be positive")
        self.programCount = programCount
        // ⌈√N⌉ columns; enough rows to hold every program.
        var w = Int(Double(programCount).squareRoot().rounded(.up))
        if w < 1 { w = 1 }
        // Rounding of the square root can undershoot by one for perfect-square-ish
        // counts; widen until width² covers, but never past programCount.
        while w * w < programCount { w += 1 }
        self.width = w
        self.height = (programCount + w - 1) / w
    }

    /// Total cells including padding (`width · height`).
    public var cellCount: Int { width * height }

    /// Trailing padded (non-program) cells (`cellCount − programCount ≥ 0`).
    public var paddedCellCount: Int { cellCount - programCount }

    /// Soup byte-space extent: `width · 8` by `height · 8` byte cells.
    public var byteWidth: Int { width * Self.blockEdge }
    /// Soup byte-space height in byte cells.
    public var byteHeight: Int { height * Self.blockEdge }

    /// The program at grid cell `(col, row)`, or `nil` when the cell is padding
    /// (`index ≥ programCount`) or out of the grid. Never returns an index that
    /// would read outside the soup.
    public func programIndex(col: Int, row: Int) -> Int? {
        guard col >= 0, col < width, row >= 0, row < height else { return nil }
        let index = row * width + col
        return index < programCount ? index : nil
    }

    /// The grid cell `(col, row)` holding program `index`.
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
