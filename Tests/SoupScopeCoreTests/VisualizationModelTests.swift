import XCTest
import BFFOracle
@testable import SoupScopeCore

/// Bounded, Metal-free tests for the visualization pure models: grid mapping,
/// camera transform, LOD blends, metric normalization, opcode coloring, the batch
/// controller, the render snapshot, and the render-uniform host layout.
final class VisualizationModelTests: XCTestCase {

    // MARK: - ProgramGrid: dimensions, index mapping, padded cells

    func testGridDimensionsCoverProgramsWithMinimalPadding() {
        // Perfect square: no padding.
        let square = ProgramGrid(programCount: 1024)
        XCTAssertEqual(square.width, 32)
        XCTAssertEqual(square.height, 32)
        XCTAssertEqual(square.cellCount, 1024)
        XCTAssertEqual(square.paddedCellCount, 0)
        XCTAssertEqual(square.byteWidth, 32 * 8)
        XCTAssertEqual(square.byteHeight, 32 * 8)

        // Non-square modest count: width² ≥ N, height covers, some padding.
        let g = ProgramGrid(programCount: 1000)
        XCTAssertEqual(g.width, 32)
        XCTAssertEqual(g.height, 32)
        XCTAssertGreaterThanOrEqual(g.cellCount, 1000)
        XCTAssertEqual(g.paddedCellCount, g.cellCount - 1000)
    }

    func testGridIndexMappingAndPaddedCellsReturnNil() {
        let g = ProgramGrid(programCount: 8)   // width 3, height 3 → 1 padded cell
        XCTAssertEqual(g.width, 3)
        XCTAssertEqual(g.height, 3)
        XCTAssertEqual(g.paddedCellCount, 1)

        // Every real program round-trips through cell ↔ index.
        for id in 0 ..< 8 {
            let c = g.cell(of: id)
            XCTAssertEqual(g.programIndex(col: c.col, row: c.row), id)
        }
        // The trailing cell (2,2) = index 8 is padding — must not index the soup.
        XCTAssertNil(g.programIndex(col: 2, row: 2))
        // Out-of-grid cells are nil, never a wild index.
        XCTAssertNil(g.programIndex(col: 3, row: 0))
        XCTAssertNil(g.programIndex(col: 0, row: 3))
        XCTAssertNil(g.programIndex(col: -1, row: 0))
    }

    func testByteOffsetIsTapeReadingOrder() {
        XCTAssertEqual(ProgramGrid.byteOffset(inBlockX: 0, inBlockY: 0), 0)
        XCTAssertEqual(ProgramGrid.byteOffset(inBlockX: 7, inBlockY: 0), 7)
        XCTAssertEqual(ProgramGrid.byteOffset(inBlockX: 0, inBlockY: 1), 8)
        XCTAssertEqual(ProgramGrid.byteOffset(inBlockX: 7, inBlockY: 7), 63)
    }

    // MARK: - Camera: bounds, anchor preservation, finite transforms

    private func geometry() -> CameraGeometry {
        CameraGeometry(soupByteWidth: 256, soupByteHeight: 256,
                       viewPxWidth: 800, viewPxHeight: 600, maxBytePx: 96)
    }

    func testFitAllUsesMinZoomAndClampsInBounds() {
        var cam = Camera()
        let g = geometry()
        cam.fitAll(g)
        XCTAssertEqual(cam.bytePx, cam.minBytePx(g), accuracy: 1e-9)
        XCTAssertTrue(cam.originByteX.isFinite && cam.originByteY.isFinite)
    }

    func testZoomIsBoundedByMinAndMax() {
        var cam = Camera()
        let g = geometry()
        cam.fitAll(g)
        // Zoom way in: clamped to maxBytePx.
        for _ in 0 ..< 50 { cam.zoom(factor: 2, anchorPxX: 400, anchorPxY: 300, geometry: g) }
        XCTAssertLessThanOrEqual(cam.bytePx, g.maxBytePx + 1e-9)
        // Zoom way out: clamped to minBytePx.
        for _ in 0 ..< 50 { cam.zoom(factor: 0.5, anchorPxX: 400, anchorPxY: 300, geometry: g) }
        XCTAssertGreaterThanOrEqual(cam.bytePx, cam.minBytePx(g) - 1e-9)
    }

    func testZoomPreservesTheCursorAnchor() {
        var cam = Camera()
        let g = geometry()
        cam.fitAll(g)
        let ax = 400.0, ay = 300.0                       // viewport center — clamp-safe
        let before = cam.screenToByte(pxX: ax, pxY: ay)
        cam.zoom(factor: 3, anchorPxX: ax, anchorPxY: ay, geometry: g)
        let after = cam.screenToByte(pxX: ax, pxY: ay)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-4)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-4)
    }

    func testPanKeepsSoupOnScreenAndFinite() {
        var cam = Camera()
        let g = geometry()
        cam.fitAll(g)
        // Pan absurdly far in both directions; origin must stay clamped/finite.
        for _ in 0 ..< 100 { cam.pan(dxPx: 100_000, dyPx: 100_000, geometry: g) }
        XCTAssertTrue(cam.originByteX.isFinite && cam.originByteY.isFinite)
        // Soup right/bottom edge cannot pass the overscroll margin off-screen.
        let visW = g.viewPxWidth / cam.bytePx
        XCTAssertLessThanOrEqual(cam.originByteX, g.soupByteWidth - visW + g.overscroll * visW + 1e-6)
    }

    func testNonFiniteInputsAreIgnored() {
        var cam = Camera()
        let g = geometry()
        cam.fitAll(g)
        let snapshot = cam
        cam.zoom(factor: .infinity, anchorPxX: 10, anchorPxY: 10, geometry: g)
        cam.zoom(factor: .nan, anchorPxX: 10, anchorPxY: 10, geometry: g)
        cam.zoom(factor: -1, anchorPxX: 10, anchorPxY: 10, geometry: g)
        cam.pan(dxPx: .nan, dyPx: 0, geometry: g)
        cam.pan(dxPx: .infinity, dyPx: .infinity, geometry: g)
        XCTAssertEqual(cam, snapshot, "invalid inputs must leave the transform untouched")
        XCTAssertTrue(cam.bytePx.isFinite && cam.originByteX.isFinite && cam.originByteY.isFinite)
    }

    // MARK: - LOD blends

    func testLODBlendThresholdsAreContinuous() {
        let lod = LODModel()
        // Fully macro below macroStart, fully micro at/above macroEnd.
        XCTAssertEqual(lod.microBlend(bytePx: 0.2), 0, accuracy: 1e-9)
        XCTAssertEqual(lod.microBlend(bytePx: 1.5), 1, accuracy: 1e-9)
        XCTAssertEqual(lod.macroBlend(bytePx: 0.2), 1, accuracy: 1e-9)
        // Midpoint of the crossfade is strictly between 0 and 1 (smoothstep = 0.5).
        let mid = lod.microBlend(bytePx: 1.0)
        XCTAssertEqual(mid, 0.5, accuracy: 1e-9)
        // Glyphs invisible before glyphStart, opaque at glyphEnd, partial between.
        XCTAssertEqual(lod.glyphBlend(bytePx: 11), 0, accuracy: 1e-9)
        XCTAssertEqual(lod.glyphBlend(bytePx: 18), 1, accuracy: 1e-9)
        let g = lod.glyphBlend(bytePx: 15)
        XCTAssertGreaterThan(g, 0)
        XCTAssertLessThan(g, 1)
    }

    func testSmoothstepHandlesNonFinite() {
        XCTAssertEqual(LODModel.smoothstep(0, 1, .nan), 0)
    }

    // MARK: - Metric normalization boundaries

    func testNormalizationFixedBoundsAndClamping() {
        let norm = MetricNormalization(stepBudget: 8192)
        XCTAssertEqual(norm.normalizedActivity(0), 0, accuracy: 1e-12)
        XCTAssertEqual(norm.normalizedActivity(8192), 1, accuracy: 1e-12)
        XCTAssertEqual(norm.normalizedActivity(4096), 0.5, accuracy: 1e-12)
        XCTAssertEqual(norm.normalizedActivity(999_999), 1, accuracy: 1e-12) // clamped
        XCTAssertEqual(norm.normalizedActivity(-5), 0, accuracy: 1e-12)      // clamped

        XCTAssertEqual(norm.normalizedEntropy(0), 0, accuracy: 1e-12)
        XCTAssertEqual(norm.normalizedEntropy(6), 1, accuracy: 1e-12)
        XCTAssertEqual(norm.normalizedEntropy(3), 0.5, accuracy: 1e-12)
        XCTAssertEqual(norm.normalizedEntropy(99), 1, accuracy: 1e-12)       // clamped
    }

    // MARK: - Opcode classification and stable byte coloring

    func testExactlyTenOpcodesClassifyAndMatchSharedBytes() {
        var opcodeBytes = Set<UInt8>()
        for op in BFFOpcode.allCases {
            opcodeBytes.insert(op.byte)
            XCTAssertEqual(OpcodeVisual.classify(op.byte), op)
        }
        XCTAssertEqual(opcodeBytes, Set(BFFOp.all), "opcode bytes must equal the shared table")
        XCTAssertEqual(opcodeBytes.count, 10)

        // Every non-opcode byte classifies as data (nil), including null (0).
        var classified = 0
        for v in 0 ... 255 where OpcodeVisual.classify(UInt8(v)) != nil { classified += 1 }
        XCTAssertEqual(classified, 10)
        XCTAssertNil(OpcodeVisual.classify(0))
    }

    func testByteColoringIsStableAndDistinct() {
        // Pinned opcode colors (03 §5).
        XCTAssertEqual(OpcodeVisual.color(BFFOp.inc), RGB(hex: 0xE08A3D))
        XCTAssertEqual(OpcodeVisual.color(BFFOp.write), RGB(hex: 0x46E052))
        XCTAssertEqual(OpcodeVisual.color(0), OpcodeVisual.nullColor)

        // The ten opcode colors are mutually distinct.
        let colors = BFFOpcode.allCases.map { OpcodeVisual.color($0.byte) }
        for i in 0 ..< colors.count {
            for j in (i + 1) ..< colors.count {
                XCTAssertNotEqual(colors[i], colors[j])
            }
        }

        // Data ramp is deterministic and follows the documented formula.
        let v: UInt8 = 100
        let lum = 0.13 + 0.17 * (Double(v) / 255)
        XCTAssertEqual(OpcodeVisual.color(v),
                       RGB(min(lum * 0.90, 1), min(lum * 0.96, 1), min(lum * 1.12, 1)))
    }

    // MARK: - Adaptive batcher

    func testBatcherColdStartAndMinBound() {
        var b = AdaptiveBatcher(targetMs: 10, minEpochs: 1, maxEpochs: 64)
        XCTAssertEqual(b.nextBatchEpochs(), 1, "cold start is one probe epoch")
        XCTAssertNil(b.emaMsPerEpoch)
    }

    func testBatcherSmoothingAndTargetResponse() {
        var b = AdaptiveBatcher(targetMs: 10, minEpochs: 1, maxEpochs: 64,
                                alpha: 0.5, rampFactor: 100)
        _ = b.nextBatchEpochs()               // 1
        b.record(batchMs: 5, epochs: 1)       // ema = 5 ms/epoch
        XCTAssertEqual(b.emaMsPerEpoch, 5)
        XCTAssertEqual(b.nextBatchEpochs(), 2, "10 ms / 5 ms per epoch")
        b.record(batchMs: 1, epochs: 1)       // sample 1; ema = 0.5·1 + 0.5·5 = 3
        XCTAssertEqual(b.emaMsPerEpoch!, 3, accuracy: 1e-9)
        XCTAssertEqual(b.nextBatchEpochs(), 3, "10 ms / 3 ms per epoch → 3")
    }

    func testBatcherMaxBoundAndRampLimit() {
        var b = AdaptiveBatcher(targetMs: 100, minEpochs: 1, maxEpochs: 8, alpha: 1, rampFactor: 2)
        _ = b.nextBatchEpochs()               // 1
        b.record(batchMs: 1, epochs: 1)       // ema = 1 → wants 100, but ramp/max bind
        XCTAssertEqual(b.nextBatchEpochs(), 2, "ramp caps growth to ×2 from 1")
        b.record(batchMs: 1, epochs: 2)
        XCTAssertEqual(b.nextBatchEpochs(), 4, "×2 again")
        b.record(batchMs: 1, epochs: 4)
        XCTAssertEqual(b.nextBatchEpochs(), 8, "reaches the max bound")
        b.record(batchMs: 1, epochs: 8)
        XCTAssertEqual(b.nextBatchEpochs(), 8, "never exceeds the max bound")
    }

    func testBatcherIgnoresInvalidTiming() {
        var b = AdaptiveBatcher()
        b.record(batchMs: .nan, epochs: 1)
        b.record(batchMs: .infinity, epochs: 1)
        b.record(batchMs: -3, epochs: 1)
        b.record(batchMs: 5, epochs: 0)
        XCTAssertNil(b.emaMsPerEpoch, "no valid sample recorded")
        b.record(batchMs: 4, epochs: 2)
        XCTAssertEqual(b.emaMsPerEpoch, 2)
    }

    // MARK: - Render snapshot validation and ordering

    func testSnapshotValidatesLengthsAndStableOrder() throws {
        let programCount = 4
        var bytes = [UInt8](repeating: 0, count: programCount * BFF.tapeSize)
        for id in 0 ..< programCount { bytes[id * BFF.tapeSize] = UInt8(id + 1) }
        let activity = [10, 20, 30, 40]
        let entropy = [0.0, 1.0, 2.0, 3.0]
        let snap = try RenderSnapshot(epoch: 7, programCount: programCount,
                                      programBytes: bytes, activity: activity, entropy: entropy)
        XCTAssertEqual(snap.programByteSlice(2).first, 3)   // program 2's first byte
        XCTAssertEqual(snap.activity[3], 40)
        XCTAssertEqual(snap.programByteSlice(0).count, BFF.tapeSize)

        // Wrong byte length / metric count are rejected (renderer resource/config gate).
        XCTAssertThrowsError(try RenderSnapshot(epoch: 0, programCount: programCount,
                                                programBytes: [0, 1, 2],
                                                activity: activity, entropy: entropy))
        XCTAssertThrowsError(try RenderSnapshot(epoch: 0, programCount: programCount,
                                                programBytes: bytes,
                                                activity: [1, 2], entropy: entropy))
        XCTAssertThrowsError(try RenderSnapshot(epoch: 0, programCount: 0,
                                                programBytes: [], activity: [], entropy: []))
    }

    func testSnapshotNormalizedMetricsUseFixedBounds() throws {
        let snap = try RenderSnapshot(epoch: 0, programCount: 2,
                                      programBytes: [UInt8](repeating: 0, count: 128),
                                      activity: [0, 8192], entropy: [0, 6])
        let norm = MetricNormalization(stepBudget: 8192)
        let m = snap.normalizedMetrics(norm)
        XCTAssertEqual(m[0].activity, 0, accuracy: 1e-12)
        XCTAssertEqual(m[0].entropy, 0, accuracy: 1e-12)
        XCTAssertEqual(m[1].activity, 1, accuracy: 1e-12)
        XCTAssertEqual(m[1].entropy, 1, accuracy: 1e-12)
    }

    // MARK: - VizUniforms host layout

    func testVizLayoutHostProbeWordsMatchDocumentedLiterals() {
        XCTAssertEqual(VizLayout.probeWordCount, 14)
        XCTAssertEqual(VizLayout.hostProbeWords(),
                       [48, 4, 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44])
    }

    // MARK: - Launch options

    func testLaunchOptionDefaultsAndParsing() throws {
        let defaults = try AppLaunchOptions.parse([])
        XCTAssertEqual(defaults.programCount, 16_384)
        XCTAssertNil(defaults.validationSeconds)

        let parsed = try AppLaunchOptions.parse(
            ["--seed", "7", "--programs", "64", "--budget", "512",
             "--shadow-sample", "all", "--variant", "bff", "--validation-seconds", "3.5"])
        XCTAssertEqual(parsed.seed, 7)
        XCTAssertEqual(parsed.programCount, 64)
        XCTAssertEqual(parsed.stepBudget, 512)
        XCTAssertEqual(parsed.shadowSampleCount, 32)      // 'all' = pairs = 64/2
        XCTAssertEqual(parsed.variant, .seededHeads)
        XCTAssertEqual(parsed.validationSeconds, 3.5)

        XCTAssertThrowsError(try AppLaunchOptions.parse(["--programs", "notint"]))
        XCTAssertThrowsError(try AppLaunchOptions.parse(["--bogus"]))
        XCTAssertThrowsError(try AppLaunchOptions.parse(["--variant", "xyz"]))

        // A valid config is produced from the defaults.
        XCTAssertNoThrow(try defaults.soupConfig())
    }
}
