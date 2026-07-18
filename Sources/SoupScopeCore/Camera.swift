/// The soup-space geometry a `Camera` operation needs: the soup extent in byte
/// cells, the drawable viewport in pixels, and the hard zoom-in limit. Passed in
/// per operation so `Camera` stays a pure transform value with no stored view
/// state to tear against a resize.
///
/// Coordinate convention (matches Metal framebuffer `[[position]]` and the render
/// shader): pixel origin is top-left, `+y` points down. The gesture layer converts
/// AppKit's bottom-left mouse coordinates into this convention before calling.
public struct CameraGeometry: Equatable, Sendable {
    /// Soup width in byte cells to frame (the populated extent, `grid.populatedByteWidth`).
    public var soupByteWidth: Double
    /// Soup height in byte cells to frame (the populated extent, `grid.populatedByteHeight`).
    public var soupByteHeight: Double
    /// Drawable width in pixels (`drawableSize.width`, already backing-scaled).
    public var viewPxWidth: Double
    /// Drawable height in pixels.
    public var viewPxHeight: Double
    /// Hard zoom-in ceiling in pixels per byte cell (03 §2 uses 96).
    public var maxBytePx: Double

    public init(soupByteWidth: Double, soupByteHeight: Double,
                viewPxWidth: Double, viewPxHeight: Double,
                maxBytePx: Double = 96) {
        self.soupByteWidth = soupByteWidth
        self.soupByteHeight = soupByteHeight
        self.viewPxWidth = viewPxWidth
        self.viewPxHeight = viewPxHeight
        self.maxBytePx = maxBytePx
    }

    /// Whether every field is finite and positive enough to transform against.
    public var isUsable: Bool {
        [soupByteWidth, soupByteHeight, viewPxWidth, viewPxHeight, maxBytePx].allSatisfy {
            $0.isFinite && $0 > 0
        }
    }
}

/// Continuous pan/zoom transform over soup byte space (03 §2, §8).
///
/// State is just the byte coordinate at the top-left pixel (`originByte`) and the
/// LOD variable `bytePx` (screen pixels per byte cell). Screen → soup is
/// `b = originByte + pixel / bytePx`. Every mutating operation re-clamps so
/// `bytePx ∈ [minBytePx, maxBytePx]` and the **camera invariant** holds, and every
/// operation ignores non-finite inputs — so the transform can never become NaN/Inf
/// regardless of gesture noise.
///
/// Camera invariant (per axis): the populated content is never pannable partially
/// or fully outside the viewport. On an axis where the content is *larger* than the
/// viewport it stays fully covering it (no background gap can open at either edge —
/// there is no overscroll); on an axis where the content is *smaller than or equal
/// to* the viewport it is centered and panning on that axis is disabled. Fit/reset,
/// cursor-anchored zoom, pan, resize, and the max-zoom limit all re-establish it
/// through the shared `clamp`.
public struct Camera: Equatable, Sendable {
    /// Soup byte coordinate mapped to the top-left pixel.
    public var originByteX: Double
    /// Soup byte coordinate mapped to the top-left pixel (y, down-positive).
    public var originByteY: Double
    /// Pixels per byte cell — the single LOD variable.
    public var bytePx: Double

    public init(originByteX: Double = 0, originByteY: Double = 0, bytePx: Double = 1) {
        self.originByteX = originByteX
        self.originByteY = originByteY
        self.bytePx = bytePx
    }

    /// Minimum zoom: fit the whole soup with ~10 % breathing room. Never exceeds
    /// `maxBytePx` (a soup smaller than the viewport still gets a sane floor).
    public func minBytePx(_ g: CameraGeometry) -> Double {
        guard g.isUsable else { return 1 }
        let fit = Swift.min(g.viewPxWidth / g.soupByteWidth,
                            g.viewPxHeight / g.soupByteHeight) * 0.9
        let floor = fit.isFinite && fit > 0 ? fit : 1
        return Swift.min(floor, g.maxBytePx)
    }

    /// Screen pixel → soup byte coordinate at the current transform.
    public func screenToByte(pxX: Double, pxY: Double) -> (x: Double, y: Double) {
        (originByteX + pxX / bytePx, originByteY + pxY / bytePx)
    }

    /// Soup byte coordinate → screen pixel at the current transform.
    public func byteToScreen(byteX: Double, byteY: Double) -> (x: Double, y: Double) {
        ((byteX - originByteX) * bytePx, (byteY - originByteY) * bytePx)
    }

    /// Clamp `bytePx` into `[minBytePx, maxBytePx]` and re-establish the camera
    /// invariant on each axis (content covers the viewport, or is centered when it is
    /// smaller than the viewport). Idempotent.
    public mutating func clamp(_ g: CameraGeometry) {
        guard g.isUsable else { return }
        let lo = minBytePx(g)
        let hi = Swift.max(lo, g.maxBytePx)
        if !bytePx.isFinite || bytePx <= 0 { bytePx = lo }
        bytePx = Swift.min(Swift.max(bytePx, lo), hi)

        clampOrigin(&originByteX, viewPx: g.viewPxWidth, soupBytes: g.soupByteWidth)
        clampOrigin(&originByteY, viewPx: g.viewPxHeight, soupBytes: g.soupByteHeight)
    }

    /// Zoom by `factor` (≈ `exp(k·Δ)`) anchored at a screen pixel: the soup byte
    /// under the anchor stays under the anchor (03 §8). Non-finite/≤0 factors are
    /// ignored.
    public mutating func zoom(factor: Double, anchorPxX: Double, anchorPxY: Double,
                              geometry g: CameraGeometry) {
        guard g.isUsable, factor.isFinite, factor > 0,
              anchorPxX.isFinite, anchorPxY.isFinite else { return }
        let before = screenToByte(pxX: anchorPxX, pxY: anchorPxY)

        let lo = minBytePx(g)
        let hi = Swift.max(lo, g.maxBytePx)
        let target = Swift.min(Swift.max(bytePx * factor, lo), hi)
        guard target.isFinite, target > 0 else { return }
        bytePx = target

        // Re-anchor: origin = b_anchor − pixel_anchor / bytePx'.
        originByteX = before.x - anchorPxX / bytePx
        originByteY = before.y - anchorPxY / bytePx
        clamp(g)
    }

    /// Pan by a screen-pixel delta (dragging the content). Non-finite deltas are
    /// ignored.
    public mutating func pan(dxPx: Double, dyPx: Double, geometry g: CameraGeometry) {
        guard g.isUsable, dxPx.isFinite, dyPx.isFinite, bytePx > 0 else { return }
        originByteX -= dxPx / bytePx
        originByteY -= dyPx / bytePx
        clamp(g)
    }

    /// Frame the whole soup (used at launch and by a reset gesture).
    public mutating func fitAll(_ g: CameraGeometry) {
        guard g.isUsable else { return }
        bytePx = minBytePx(g)
        // Center the soup in the viewport.
        let visW = g.viewPxWidth / bytePx
        let visH = g.viewPxHeight / bytePx
        originByteX = (g.soupByteWidth - visW) / 2
        originByteY = (g.soupByteHeight - visH) / 2
        clamp(g)
    }

    /// Re-establish the invariant on one axis. Content larger than the viewport is
    /// clamped so it fully covers the viewport (`origin ∈ [0, soupBytes − visible]`,
    /// no background gap at either edge); content smaller than or equal to the
    /// viewport is pinned to the centered origin, which also disables panning on that
    /// axis (any pan is immediately clamped back to center).
    private func clampOrigin(_ v: inout Double, viewPx: Double, soupBytes: Double) {
        guard v.isFinite, bytePx > 0 else { v = 0; return }
        let visible = viewPx / bytePx                 // soup bytes across the viewport
        if soupBytes <= visible {
            v = (soupBytes - visible) / 2             // center; nothing to reveal by panning
        } else {
            v = Swift.min(Swift.max(v, 0), soupBytes - visible)
        }
    }
}
