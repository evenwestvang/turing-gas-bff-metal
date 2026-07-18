import XCTest
@testable import SoupScopeCore

/// The camera invariant, exercised across every operation that can move or resize
/// the view: fit/reset, cursor-anchored zoom, pan, resize, the max-zoom ceiling, and
/// non-finite gesture noise. The invariant, per axis:
///
/// - content *larger* than the viewport stays fully covering it — the origin lives in
///   `[0, soupBytes − visible]`, so no background gap opens at either edge (there is
///   no overscroll); and
/// - content *smaller than or equal to* the viewport is centered and cannot be panned
///   off-center.
///
/// A soup byte cell is populated content; padding beyond the populated extent is never
/// framed (the geometry is built from the populated extent, not the canonical canvas).
final class CameraInvariantTests: XCTestCase {

    /// Assert the invariant holds for `cam` under `g`, on both axes, with finite state.
    private func assertInvariant(_ cam: Camera, _ g: CameraGeometry, _ note: String = "",
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(cam.bytePx.isFinite && cam.bytePx > 0,
                      "bytePx must stay finite/positive \(note)", file: file, line: line)
        XCTAssertTrue(cam.originByteX.isFinite && cam.originByteY.isFinite,
                      "origin must stay finite \(note)", file: file, line: line)
        // bytePx is inside [minBytePx, maxBytePx].
        XCTAssertGreaterThanOrEqual(cam.bytePx, cam.minBytePx(g) - 1e-9,
                                    "bytePx below min \(note)", file: file, line: line)
        XCTAssertLessThanOrEqual(cam.bytePx, g.maxBytePx + 1e-9,
                                 "bytePx above max \(note)", file: file, line: line)

        let axes: [(origin: Double, soup: Double, view: Double, name: String)] = [
            (cam.originByteX, g.soupByteWidth, g.viewPxWidth, "x"),
            (cam.originByteY, g.soupByteHeight, g.viewPxHeight, "y"),
        ]
        for a in axes {
            let visible = a.view / cam.bytePx
            if a.soup > visible + 1e-9 {
                // Larger than the viewport: fully covers it, no gap.
                XCTAssertGreaterThanOrEqual(a.origin, -1e-6,
                    "\(a.name): background gap at the left/top edge \(note)", file: file, line: line)
                XCTAssertLessThanOrEqual(a.origin, a.soup - visible + 1e-6,
                    "\(a.name): background gap at the right/bottom edge \(note)", file: file, line: line)
            } else {
                // Smaller than or equal to the viewport: exactly centered, pan disabled.
                XCTAssertEqual(a.origin, (a.soup - visible) / 2, accuracy: 1e-6,
                    "\(a.name): content not centered \(note)", file: file, line: line)
            }
        }
    }

    /// A viewport-larger-than-content geometry (fit centers on both axes) and a
    /// viewport-smaller-than-content one (fit still frames, pan enabled once zoomed).
    private func wideView() -> CameraGeometry {
        CameraGeometry(soupByteWidth: 256, soupByteHeight: 128,
                       viewPxWidth: 1280, viewPxHeight: 800, maxBytePx: 96)
    }
    private func tallContent() -> CameraGeometry {
        // Full canonical field: 4096×2048 byte cells in a modest window.
        CameraGeometry(soupByteWidth: 4096, soupByteHeight: 2048,
                       viewPxWidth: 1280, viewPxHeight: 800, maxBytePx: 96)
    }

    // MARK: - Fit / reset

    func testFitCentersSmallContentAndHoldsInvariant() {
        var cam = Camera()
        let g = wideView()
        cam.fitAll(g)
        // At the fit zoom the content is smaller than the viewport on both axes, so it
        // is centered: the origin is negative-symmetric about the content.
        assertInvariant(cam, g, "after fit (small content)")
        let visX = g.viewPxWidth / cam.bytePx
        XCTAssertEqual(cam.originByteX, (g.soupByteWidth - visX) / 2, accuracy: 1e-6)
    }

    func testFitFramesLargeFieldAndHoldsInvariant() {
        var cam = Camera()
        let g = tallContent()
        cam.fitAll(g)
        assertInvariant(cam, g, "after fit (full field)")
        XCTAssertEqual(cam.bytePx, cam.minBytePx(g), accuracy: 1e-9)
    }

    // MARK: - Cursor-anchored zoom

    func testZoomKeepsCursorAnchoredWhileContentExceedsViewport() {
        var cam = Camera()
        let g = tallContent()
        cam.fitAll(g)
        // Zoom in enough that content exceeds the viewport on both axes; then the byte
        // under an interior anchor must stay under it (away from the clamp limits).
        cam.zoom(factor: 8, anchorPxX: 640, anchorPxY: 400, geometry: g)
        assertInvariant(cam, g, "mid zoom")
        let ax = 700.0, ay = 360.0
        let before = cam.screenToByte(pxX: ax, pxY: ay)
        cam.zoom(factor: 1.5, anchorPxX: ax, anchorPxY: ay, geometry: g)
        let after = cam.screenToByte(pxX: ax, pxY: ay)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-3)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-3)
        assertInvariant(cam, g, "after anchored zoom")
    }

    func testRepeatedZoomInIsBoundedByMaxAndHoldsInvariant() {
        var cam = Camera()
        let g = tallContent()
        cam.fitAll(g)
        for _ in 0 ..< 80 { cam.zoom(factor: 1.7, anchorPxX: 200, anchorPxY: 120, geometry: g) }
        XCTAssertLessThanOrEqual(cam.bytePx, g.maxBytePx + 1e-9)
        assertInvariant(cam, g, "at max zoom, off-center anchor")
    }

    func testZoomOutFromMaxLandsCenteredAtMinZoom() {
        var cam = Camera()
        let g = wideView()
        cam.fitAll(g)
        for _ in 0 ..< 40 { cam.zoom(factor: 1.5, anchorPxX: 1000, anchorPxY: 700, geometry: g) }
        assertInvariant(cam, g, "zoomed in")
        for _ in 0 ..< 60 { cam.zoom(factor: 0.6, anchorPxX: 1000, anchorPxY: 700, geometry: g) }
        XCTAssertEqual(cam.bytePx, cam.minBytePx(g), accuracy: 1e-9)
        assertInvariant(cam, g, "back at min zoom → centered")
    }

    // MARK: - Pan

    func testPanCannotOpenABackgroundGapOnLargeContent() {
        var cam = Camera()
        let g = tallContent()
        cam.fitAll(g)
        cam.zoom(factor: 30, anchorPxX: 640, anchorPxY: 400, geometry: g)
        // Slam the content in every direction; it must always cover the viewport.
        for (dx, dy) in [(1e7, 1e7), (-1e7, -1e7), (1e7, -1e7), (-1e7, 1e7)] {
            for _ in 0 ..< 20 { cam.pan(dxPx: dx, dyPx: dy, geometry: g) }
            assertInvariant(cam, g, "after extreme pan (\(dx),\(dy))")
        }
    }

    func testPanIsDisabledWhenContentSmallerThanViewport() {
        var cam = Camera()
        let g = wideView()
        cam.fitAll(g)               // small content on both axes → centered
        let centered = cam
        cam.pan(dxPx: 500, dyPx: 500, geometry: g)
        XCTAssertEqual(cam, centered, "pan must be a no-op when content is centered/locked")
        cam.pan(dxPx: -9999, dyPx: 9999, geometry: g)
        XCTAssertEqual(cam, centered, "pan on a locked axis never moves the origin")
    }

    func testPanEnabledOnOnlyTheLargerAxis() {
        // Content wider than the viewport but shorter than it: x pans, y stays centered.
        let g = CameraGeometry(soupByteWidth: 4096, soupByteHeight: 40,
                               viewPxWidth: 1280, viewPxHeight: 800, maxBytePx: 96)
        var cam = Camera()
        cam.fitAll(g)
        // At min zoom the wide axis binds, so content is < viewport on both axes; zoom
        // in until x exceeds the viewport while y is still far smaller.
        cam.zoom(factor: 6, anchorPxX: 640, anchorPxY: 400, geometry: g)
        let visX = g.viewPxWidth / cam.bytePx
        let visY = g.viewPxHeight / cam.bytePx
        XCTAssertGreaterThan(g.soupByteWidth, visX, "precondition: x content exceeds viewport")
        XCTAssertLessThan(g.soupByteHeight, visY, "precondition: y content within viewport")
        let yBefore = cam.originByteY
        cam.pan(dxPx: -400, dyPx: 400, geometry: g)
        assertInvariant(cam, g, "mixed-axis pan")
        XCTAssertEqual(cam.originByteY, yBefore, accuracy: 1e-9, "y stays centered/locked")
        XCTAssertNotEqual(cam.originByteX, 0, "x actually panned")
    }

    // MARK: - Resize

    func testResizeReframesAndKeepsInvariant() {
        var cam = Camera()
        var g = tallContent()
        cam.fitAll(g)
        cam.zoom(factor: 10, anchorPxX: 640, anchorPxY: 400, geometry: g)
        cam.pan(dxPx: -5000, dyPx: -5000, geometry: g)   // push to a corner
        assertInvariant(cam, g, "before resize")
        // Shrink the viewport hard (a window resize); re-clamp as the app does.
        for (w, h) in [(400.0, 300.0), (2400.0, 1400.0), (60.0, 4000.0)] {
            g.viewPxWidth = w
            g.viewPxHeight = h
            cam.clamp(g)
            assertInvariant(cam, g, "after resize to \(w)x\(h)")
        }
    }

    // MARK: - Non-finite gesture input

    func testNonFiniteGestureInputLeavesAValidInvariantState() {
        var cam = Camera()
        let g = tallContent()
        cam.fitAll(g)
        cam.zoom(factor: 12, anchorPxX: 640, anchorPxY: 400, geometry: g)
        let good = cam
        // Each of these must be ignored (no state change) and never poison the transform.
        cam.zoom(factor: .nan, anchorPxX: 100, anchorPxY: 100, geometry: g)
        cam.zoom(factor: .infinity, anchorPxX: 100, anchorPxY: 100, geometry: g)
        cam.zoom(factor: -3, anchorPxX: 100, anchorPxY: 100, geometry: g)
        cam.zoom(factor: 2, anchorPxX: .nan, anchorPxY: 10, geometry: g)
        cam.zoom(factor: 2, anchorPxX: 10, anchorPxY: .infinity, geometry: g)
        cam.pan(dxPx: .nan, dyPx: 0, geometry: g)
        cam.pan(dxPx: .infinity, dyPx: -.infinity, geometry: g)
        XCTAssertEqual(cam, good, "non-finite gesture input must be a no-op")
        assertInvariant(cam, g, "after non-finite noise")
    }

    func testDegenerateGeometryIsANoOp() {
        var cam = Camera(originByteX: 3, originByteY: 4, bytePx: 5)
        let snapshot = cam
        for g in [CameraGeometry(soupByteWidth: 0, soupByteHeight: 10,
                                 viewPxWidth: 100, viewPxHeight: 100),
                  CameraGeometry(soupByteWidth: 10, soupByteHeight: 10,
                                 viewPxWidth: .nan, viewPxHeight: 100),
                  CameraGeometry(soupByteWidth: 10, soupByteHeight: 10,
                                 viewPxWidth: 100, viewPxHeight: .infinity)] {
            XCTAssertFalse(g.isUsable)
            cam.fitAll(g);  cam.clamp(g)
            cam.zoom(factor: 2, anchorPxX: 1, anchorPxY: 1, geometry: g)
            cam.pan(dxPx: 1, dyPx: 1, geometry: g)
            XCTAssertEqual(cam, snapshot, "an unusable geometry must never mutate the camera")
        }
    }

    // MARK: - Poisoned public state restoration
    //
    // The public `originByte*` / `bytePx` fields are mutable, so a buggy caller (or a
    // corrupt restore-from-disk) can poison them with NaN/Inf/≤0. `clamp`, `zoom`, and
    // `pan` must restore the invariant even from that state — centering undersized axes
    // (never zeroing them), replacing a non-finite origin with a finite value before
    // clamping larger axes, and normalizing *before* any gesture-specific early return
    // so a poisoned camera + an invalid gesture still lands on a valid invariant.

    /// Cameras with one poisoned public field each — origins NaN/Inf, bytePx
    /// NaN/Inf/≤0 — against a `bytePx` that keeps both axes oversized on `tallContent`.
    private func poisonedCameras() -> [Camera] {
        [Camera(originByteX: .nan,        originByteY: 50,         bytePx: 10),
         Camera(originByteX: 50,          originByteY: .infinity,  bytePx: 10),
         Camera(originByteX: -.infinity,  originByteY: .nan,       bytePx: 10),
         Camera(originByteX: 100,         originByteY: 100,         bytePx: .nan),
         Camera(originByteX: 100,         originByteY: 100,         bytePx: .infinity),
         Camera(originByteX: 100,         originByteY: 100,         bytePx: -3),
         Camera(originByteX: 100,         originByteY: 100,         bytePx: 0)]
    }

    /// `clamp` restores the invariant from any poisoned origin on undersized axes
    /// (content smaller than the viewport → centered, never zeroed), even with NaN/Inf
    /// origins. `bytePx` stays in the undersized range so both axes are undersized.
    func testClampRestoresInvariantFromPoisonedOriginUndersizedAxes() {
        let g = wideView()
        let bytePx = 4.5  // minBytePx(wideView); keeps both axes undersized at the fit zoom
        for origin in [Double.nan, .infinity, -.infinity] {
            var cam = Camera(originByteX: origin, originByteY: origin, bytePx: bytePx)
            cam.clamp(g)
            assertInvariant(cam, g, "poisoned origin=\(origin)")
            // Undersized axes are exactly centered, not zero, not NaN.
            let visX = g.viewPxWidth / cam.bytePx
            let visY = g.viewPxHeight / cam.bytePx
            XCTAssertEqual(cam.originByteX, (g.soupByteWidth - visX) / 2, accuracy: 1e-6,
                           "x centered from origin=\(origin)")
            XCTAssertEqual(cam.originByteY, (g.soupByteHeight - visY) / 2, accuracy: 1e-6,
                           "y centered from origin=\(origin)")
        }
    }

    /// `clamp` restores the invariant from any poisoned origin on oversized axes
    /// (content larger than the viewport → origin in `[0, soupBytes − visible]`),
    /// replacing NaN/Inf with a finite value before clamping.
    func testClampRestoresInvariantFromPoisonedOriginOversizedAxes() {
        let g = tallContent()
        let bytePx = 10.0  // makes both axes oversized on tallContent (visible ≪ content)
        for origin in [Double.nan, .infinity, -.infinity] {
            var cam = Camera(originByteX: origin, originByteY: origin, bytePx: bytePx)
            cam.clamp(g)
            assertInvariant(cam, g, "poisoned origin=\(origin)")
            let visible = g.viewPxWidth / cam.bytePx
            XCTAssertGreaterThanOrEqual(cam.originByteX, -1e-6,
                "x origin finite and >= 0 from origin=\(origin)")
            XCTAssertLessThanOrEqual(cam.originByteX, g.soupByteWidth - visible + 1e-6,
                "x origin <= soupBytes − visible from origin=\(origin)")
        }
    }

    /// `clamp` restores the invariant from a poisoned `bytePx` (NaN, ±Inf, ≤0) on both
    /// undersized and oversized geometries — `bytePx` is reset into `[minBytePx, max]`
    /// and the origins re-centered/clamped against the restored zoom.
    func testClampRestoresInvariantFromPoisonedBytePx() {
        for g in [wideView(), tallContent()] {
            for bad in [Double.nan, .infinity, -.infinity, -1.0, 0.0] {
                var cam = Camera(originByteX: 100, originByteY: 100, bytePx: bad)
                cam.clamp(g)
                assertInvariant(cam, g, "poisoned bytePx=\(bad)")
            }
        }
    }

    /// `zoom` with an invalid gesture on a poisoned camera normalizes the state
    /// *before* the gesture early return — the camera lands on a valid invariant, not
    /// the poisoned input. Covers both undersized and oversized geometries.
    func testZoomNormalizesPoisonedStateBeforeGestureEarlyReturn() {
        for g in [wideView(), tallContent()] {
            for poisoned in poisonedCameras() {
                var cam = poisoned
                cam.zoom(factor: .nan, anchorPxX: 640, anchorPxY: 400, geometry: g)
                assertInvariant(cam, g, "zoom(NaN factor) from \(poisoned)")

                cam = poisoned
                cam.zoom(factor: 2, anchorPxX: .nan, anchorPxY: .infinity, geometry: g)
                assertInvariant(cam, g, "zoom(valid factor, NaN anchor) from \(poisoned)")
            }
        }
    }

    /// `pan` with an invalid gesture on a poisoned camera normalizes the state *before*
    /// the gesture early return. Covers both undersized and oversized geometries.
    func testPanNormalizesPoisonedStateBeforeGestureEarlyReturn() {
        for g in [wideView(), tallContent()] {
            for poisoned in poisonedCameras() {
                var cam = poisoned
                cam.pan(dxPx: .nan, dyPx: .infinity, geometry: g)
                assertInvariant(cam, g, "pan(NaN, Inf) from \(poisoned)")
            }
        }
    }

    /// A valid `zoom` from poisoned state restores the invariant and keeps the cursor
    /// anchor: `clamp` runs before `before` is sampled, so the byte under the anchor
    /// after the zoom equals the byte under the anchor in the *normalized* pre-state.
    func testZoomFromPoisonedStateRestoresInvariantAndKeepsAnchor() {
        let g = tallContent()
        let ax = 640.0, ay = 400.0
        for poisoned in poisonedCameras() {
            var cam = poisoned
            cam.zoom(factor: 1.5, anchorPxX: ax, anchorPxY: ay, geometry: g)
            assertInvariant(cam, g, "valid zoom from \(poisoned)")

            var normalized = poisoned
            normalized.clamp(g)
            let expected = normalized.screenToByte(pxX: ax, pxY: ay)
            let after = cam.screenToByte(pxX: ax, pxY: ay)
            XCTAssertEqual(after.x, expected.x, accuracy: 1e-3,
                           "anchor x preserved from \(poisoned)")
            XCTAssertEqual(after.y, expected.y, accuracy: 1e-3,
                           "anchor y preserved from \(poisoned)")
        }
    }

    /// A valid `pan` from poisoned state restores the invariant. Covers both undersized
    /// axes (pan locked to center) and oversized axes (pan clamped to the covering range).
    func testPanFromPoisonedStateRestoresInvariant() {
        for g in [wideView(), tallContent()] {
            for poisoned in poisonedCameras() {
                var cam = poisoned
                cam.pan(dxPx: -500, dyPx: 300, geometry: g)
                assertInvariant(cam, g, "valid pan from \(poisoned)")
            }
        }
    }

    /// A resize (re-`clamp` under changing geometry) from a poisoned start restores and
    /// preserves the invariant across every intermediate size, on both geometries.
    func testResizeFromPoisonedStateRestoresInvariant() {
        for base in [wideView(), tallContent()] {
            var g = base
            for poisoned in poisonedCameras() {
                var cam = poisoned
                for (w, h) in [(400.0, 300.0), (2400.0, 1400.0), (60.0, 4000.0)] {
                    g.viewPxWidth = w
                    g.viewPxHeight = h
                    cam.clamp(g)
                    assertInvariant(cam, g, "resize to \(w)x\(h) from \(poisoned)")
                }
            }
        }
    }
}
