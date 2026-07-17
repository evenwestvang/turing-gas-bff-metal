import XCTest
import BFFOracle
@testable import SoupScopeCore

/// Bounded, Metal-free tests for the visualization pure models: grid mapping,
/// camera transform, LOD blends, metric normalization, opcode coloring, the batch
/// controller, the render snapshot, and the render-uniform host layout.
final class VisualizationModelTests: XCTestCase {

    // MARK: - ProgramGrid: canonical 512×256 coordinates, mapping, padded cells

    func testGridIsAlwaysTheCanonical512x256Canvas() {
        // Dimensions are fixed regardless of the program count (03 §1).
        for n in [2, 8, 1024, 16_384, ProgramGrid.capacity] {
            let g = ProgramGrid(programCount: n)
            XCTAssertEqual(g.width, 512)
            XCTAssertEqual(g.height, 256)
            XCTAssertEqual(g.cellCount, 512 * 256)
            XCTAssertEqual(g.byteWidth, 512 * 8)      // 4096
            XCTAssertEqual(g.byteHeight, 256 * 8)     // 2048
            XCTAssertEqual(g.paddedCellCount, 512 * 256 - n)
        }
        XCTAssertEqual(ProgramGrid.capacity, 131_072)
    }

    func testStableIDMapsToCanonicalColumnRow() {
        let g = ProgramGrid(programCount: ProgramGrid.capacity)
        // Program i → (i % 512, i / 512), checked around the row boundaries.
        XCTAssertEqual(g.cell(of: 0).col, 0)
        XCTAssertEqual(g.cell(of: 0).row, 0)
        XCTAssertEqual(g.cell(of: 511).col, 511)   // last cell of row 0
        XCTAssertEqual(g.cell(of: 511).row, 0)
        XCTAssertEqual(g.cell(of: 512).col, 0)     // first cell of row 1
        XCTAssertEqual(g.cell(of: 512).row, 1)
        XCTAssertEqual(g.cell(of: 513).col, 1)
        XCTAssertEqual(g.cell(of: 513).row, 1)

        // Last valid ID sits at the bottom-right canonical cell (511, 255).
        let last = ProgramGrid.capacity - 1                 // 131071
        XCTAssertEqual(g.cell(of: last).col, 511)
        XCTAssertEqual(g.cell(of: last).row, 255)

        // cell ↔ programIndex round-trips for every boundary ID.
        for id in [0, 511, 512, 513, last] {
            let c = g.cell(of: id)
            XCTAssertEqual(g.programIndex(col: c.col, row: c.row), id)
        }
    }

    func testPaddedAndOutOfCanvasCellsNeverIndexTheSoup() {
        let g = ProgramGrid(programCount: 1000)             // occupies IDs 0..<1000
        // ID 999 is the last real program at (999 % 512, 999 / 512) = (487, 1).
        XCTAssertEqual(g.cell(of: 999).col, 487)
        XCTAssertEqual(g.cell(of: 999).row, 1)
        XCTAssertEqual(g.programIndex(col: 487, row: 1), 999)

        // The next cell (488, 1) = index 1000 is padding — must return nil.
        XCTAssertNil(g.programIndex(col: 488, row: 1))
        // A cell deep in the empty canvas is padding, not a wild index.
        XCTAssertNil(g.programIndex(col: 0, row: 100))
        XCTAssertNil(g.programIndex(col: 511, row: 255))
        // Out-of-canvas cells are nil.
        XCTAssertNil(g.programIndex(col: 512, row: 0))
        XCTAssertNil(g.programIndex(col: 0, row: 256))
        XCTAssertNil(g.programIndex(col: -1, row: 0))
    }

    func testPopulatedExtentFramesOccupiedCellsOnly() {
        // Single partial row: extent is N columns × 1 row.
        let small = ProgramGrid(programCount: 300)
        XCTAssertEqual(small.populatedColumns, 300)
        XCTAssertEqual(small.populatedRows, 1)
        XCTAssertEqual(small.populatedByteWidth, 300 * 8)
        XCTAssertEqual(small.populatedByteHeight, 8)

        // Exactly one full row.
        let oneRow = ProgramGrid(programCount: 512)
        XCTAssertEqual(oneRow.populatedColumns, 512)
        XCTAssertEqual(oneRow.populatedRows, 1)

        // Full rows plus a partial one: columns cap at 512, rows = ⌈N/512⌉.
        let modest = ProgramGrid(programCount: 1024)         // exactly 2 rows
        XCTAssertEqual(modest.populatedColumns, 512)
        XCTAssertEqual(modest.populatedRows, 2)
        let ragged = ProgramGrid(programCount: 1025)         // 2 full + 1 cell → 3 rows
        XCTAssertEqual(ragged.populatedColumns, 512)
        XCTAssertEqual(ragged.populatedRows, 3)

        // Full canvas fills every row.
        let full = ProgramGrid(programCount: ProgramGrid.capacity)
        XCTAssertEqual(full.populatedColumns, 512)
        XCTAssertEqual(full.populatedRows, 256)
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

    // MARK: - LOD readout: the values the HUD displays, at the transition endpoints

    func testLODReadoutBlendsAtTransitionEndpoints() {
        let lod = LODModel()
        func readout(_ px: Double) -> LODReadout {
            LODReadout(camera: Camera(bytePx: px), lod: lod)
        }
        // Macro↔micro crossfade endpoints: fully macro at macroStart, fully micro at
        // macroEnd, and exactly half-and-half at the smoothstep midpoint.
        let atMacroStart = readout(lod.macroStart)
        XCTAssertEqual(atMacroStart.microBlend, 0, accuracy: 1e-9)
        XCTAssertEqual(atMacroStart.macroBlend, 1, accuracy: 1e-9)
        let atMacroEnd = readout(lod.macroEnd)
        XCTAssertEqual(atMacroEnd.microBlend, 1, accuracy: 1e-9)
        XCTAssertEqual(atMacroEnd.macroBlend, 0, accuracy: 1e-9)
        let atMacroMid = readout((lod.macroStart + lod.macroEnd) / 2)
        XCTAssertEqual(atMacroMid.microBlend, 0.5, accuracy: 1e-9)
        XCTAssertEqual(atMacroMid.macroBlend, 0.5, accuracy: 1e-9)

        // Glyph overlay endpoints: invisible at glyphStart, opaque at glyphEnd,
        // partial in between.
        XCTAssertEqual(readout(lod.glyphStart).glyphBlend, 0, accuracy: 1e-9)
        XCTAssertEqual(readout(lod.glyphEnd).glyphBlend, 1, accuracy: 1e-9)
        let glyphMid = readout((lod.glyphStart + lod.glyphEnd) / 2).glyphBlend
        XCTAssertGreaterThan(glyphMid, 0)
        XCTAssertLessThan(glyphMid, 1)

        // bytePx is the camera's, verbatim; macro is exactly the complement of micro
        // across the whole range, including the endpoints above.
        for px in [0.1, lod.macroStart, 1.0, lod.macroEnd, 5, lod.glyphStart, 15,
                   lod.glyphEnd, 96] {
            let r = readout(px)
            XCTAssertEqual(r.bytePx, px)
            XCTAssertEqual(r.macroBlend, 1 - r.microBlend, accuracy: 1e-12)
        }
    }

    func testLODReadoutMatchesTheRenderUniformStateAtBoundaries() {
        // The HUD readout and the shader's uniforms are the SAME `LODReadout`
        // instance: `makeUniforms` builds the uniform block straight from the readout
        // it is handed, so every LOD field is byte-for-byte the uploaded one and the
        // HUD can never drift from what is rendered.
        let lod = LODModel()
        let grid = ProgramGrid(programCount: 1024)
        for px in [lod.macroStart, lod.macroEnd, lod.glyphStart, lod.glyphEnd, 1.0, 15.0] {
            let camera = Camera(bytePx: px)
            let readout = LODReadout(camera: camera, lod: lod)
            let u = VizLayout.makeUniforms(readout: readout, camera: camera, grid: grid,
                                           metricChannel: 2,
                                           viewPxWidth: 800, viewPxHeight: 600)
            XCTAssertEqual(u.bytePx, Float(readout.bytePx))
            XCTAssertEqual(u.microBlend, Float(readout.microBlend))
            XCTAssertEqual(u.glyphBlend, Float(readout.glyphBlend))
        }
    }

    func testRenderUniformPathUpdatesCurrentReadoutOnCameraChange() {
        // The render-uniform path (`LODReadout.forFrame` + `makeUniforms`) is the one
        // place the frame's readout is evaluated. It must (a) report a change when the
        // camera moves — even a camera-only change with nothing else advancing, i.e. a
        // paused frame — so the observable HUD readout tracks it, (b) feed the uniforms
        // the exact readout it reports, and (c) report NO change for a steady camera so
        // the caller never publishes a redundant SwiftUI update.
        let lod = LODModel()
        let grid = ProgramGrid(programCount: 1024)

        // Model the AppModel's published state: the readout the HUD currently shows.
        var current = LODReadout(camera: Camera(bytePx: 1.0), lod: lod)

        // A paused-equivalent, camera-only change: only the camera differs (no epoch
        // advance, no HUD-model mutation). The path must still see it as changed.
        let zoomed = Camera(bytePx: 4.0)
        let frame1 = LODReadout.forFrame(camera: zoomed, lod: lod, current: current)
        XCTAssertTrue(frame1.changed, "a camera-only zoom must update the HUD readout")
        XCTAssertEqual(frame1.readout, LODReadout(camera: zoomed, lod: lod))
        if frame1.changed { current = frame1.readout }        // the publish the caller does
        XCTAssertEqual(current, LODReadout(camera: zoomed, lod: lod),
                       "the current/observable readout now equals the submitted frame's")

        // The uniforms for that frame are built from the very readout just reported,
        // so the HUD's `current` and the uploaded LOD fields are the same evaluation.
        let u = VizLayout.makeUniforms(readout: frame1.readout, camera: zoomed, grid: grid,
                                       metricChannel: 2, viewPxWidth: 800, viewPxHeight: 600)
        XCTAssertEqual(u.bytePx, Float(current.bytePx))
        XCTAssertEqual(u.microBlend, Float(current.microBlend))
        XCTAssertEqual(u.glyphBlend, Float(current.glyphBlend))

        // A steady camera on the next frame yields no change, so no redundant publish
        // (and hence no SwiftUI update loop).
        let frame2 = LODReadout.forFrame(camera: zoomed, lod: lod, current: current)
        XCTAssertFalse(frame2.changed, "an unchanged camera must not trigger a HUD update")
        XCTAssertEqual(frame2.readout, current)

        // A pan-only move that leaves bytePx unchanged does not change the LOD readout
        // (the readout is a function of zoom, not pan) — again no redundant publish.
        let panned = Camera(originByteX: 42, originByteY: 7, bytePx: zoomed.bytePx)
        let frame3 = LODReadout.forFrame(camera: panned, lod: lod, current: current)
        XCTAssertFalse(frame3.changed, "pan at the same zoom leaves the LOD readout intact")
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
        XCTAssertEqual(defaults.programCount, 1_024)      // modest interactive default
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

    func testProgramCountAboveCanvasCapacityIsRejected() throws {
        // At capacity is fine; one program above the 512×256 canvas is rejected.
        var atCapacity = AppLaunchOptions()
        atCapacity.programCount = ProgramGrid.capacity
        XCTAssertNoThrow(try atCapacity.soupConfig())

        var over = AppLaunchOptions()
        over.programCount = ProgramGrid.capacity + 2       // still even, still over
        XCTAssertThrowsError(try over.soupConfig()) { error in
            XCTAssertEqual(error as? AppLaunchOptions.ParseError,
                           .programCountExceedsCanvas(count: ProgramGrid.capacity + 2,
                                                      capacity: ProgramGrid.capacity))
        }

        // Parsing the flag still succeeds (deterministic parse); rejection is at
        // config validation.
        let parsed = try AppLaunchOptions.parse(["--programs", "200000"])
        XCTAssertEqual(parsed.programCount, 200_000)
        XCTAssertThrowsError(try parsed.soupConfig())
    }

    // MARK: - Bounded native validation state machine

    private func inputs(_ elapsed: Double, draws: Int, error: Bool = false,
                        mismatch: Int = 0) -> ValidationInputs {
        ValidationInputs(elapsedSeconds: elapsed, completedDraws: draws,
                         hasError: error, shadowMismatch: mismatch)
    }

    func testValidationSuccessNeedsDurationAndRealDrawProgress() {
        let policy = ValidationPolicy(requestedSeconds: 5, graceSeconds: 2, metalAvailable: true)
        // Time elapsed but no completed draw yet → still pending (before grace).
        XCTAssertEqual(policy.evaluate(inputs(5, draws: 0)), .pending)
        // A draw landed but the duration has not elapsed → pending.
        XCTAssertEqual(policy.evaluate(inputs(4.9, draws: 3)), .pending)
        // Duration elapsed AND at least one completed draw → success.
        XCTAssertEqual(policy.evaluate(inputs(5, draws: 1)), .success)
        XCTAssertEqual(policy.evaluate(inputs(9, draws: 42)), .success)
    }

    func testValidationNoProgressTimesOutFinitely() {
        let policy = ValidationPolicy(requestedSeconds: 5, graceSeconds: 2, metalAvailable: true)
        XCTAssertEqual(policy.graceDeadline, 7)
        // Before the grace deadline with no draw → keep waiting.
        XCTAssertEqual(policy.evaluate(inputs(6.9, draws: 0)), .pending)
        // At/after the grace deadline with no completed draw → finite failure.
        XCTAssertEqual(policy.evaluate(inputs(7, draws: 0)), .failure(.noDrawProgress))
        XCTAssertEqual(policy.evaluate(inputs(100, draws: 0)), .failure(.noDrawProgress))
        // A single draw before the deadline rescues it into success at duration.
        XCTAssertEqual(policy.evaluate(inputs(7, draws: 1)), .success)
    }

    func testValidationErrorAndMismatchFailRegardlessOfTiming() {
        let policy = ValidationPolicy(requestedSeconds: 5, metalAvailable: true)
        // Hard stops win even with plenty of successful draws and elapsed time.
        XCTAssertEqual(policy.evaluate(inputs(9, draws: 10, mismatch: 1)),
                       .failure(.shadowMismatch))
        XCTAssertEqual(policy.evaluate(inputs(9, draws: 10, error: true)),
                       .failure(.error))
        // Mismatch takes precedence over a bare error.
        XCTAssertEqual(policy.evaluate(inputs(1, draws: 0, error: true, mismatch: 2)),
                       .failure(.shadowMismatch))
        // No Metal fails immediately, before any timing consideration.
        let noMetal = ValidationPolicy(requestedSeconds: 5, metalAvailable: false)
        XCTAssertEqual(noMetal.evaluate(inputs(0, draws: 0)), .failure(.noMetal))
    }

    func testValidationExitCodes() {
        XCTAssertEqual(ValidationOutcome.success.exitCode, 0)
        XCTAssertEqual(ValidationOutcome.failure(.error).exitCode, 1)
        XCTAssertEqual(ValidationOutcome.failure(.shadowMismatch).exitCode, 1)
        XCTAssertEqual(ValidationOutcome.failure(.noDrawProgress).exitCode, 1)
        XCTAssertEqual(ValidationOutcome.failure(.noMetal).exitCode, 2)
    }

    func testValidationRunCompletesExactlyOnce() {
        var run = ValidationRun(policy: ValidationPolicy(requestedSeconds: 5,
                                                         graceSeconds: 2,
                                                         metalAvailable: true))
        // Pending steps do not latch.
        XCTAssertNil(run.step(inputs(1, draws: 0)))
        XCTAssertNil(run.step(inputs(4, draws: 1)))
        XCTAssertFalse(run.finished)
        // First terminal verdict is returned once and latched.
        XCTAssertEqual(run.step(inputs(5, draws: 1)), .success)
        XCTAssertTrue(run.finished)
        XCTAssertEqual(run.outcome, .success)
        // A racing watchdog step afterwards yields nil — single completion.
        XCTAssertNil(run.step(inputs(7, draws: 0)))
        XCTAssertNil(run.step(inputs(9, draws: 9, mismatch: 5)))
        XCTAssertEqual(run.outcome, .success)   // outcome never changes after latch
    }
}
