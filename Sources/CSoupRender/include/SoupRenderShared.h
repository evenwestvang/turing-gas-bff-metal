// SoupRenderShared.h — the byte layout of the render uniform block shared between
// the Swift host and the runtime-compiled render shader (Sources/SoupScopeApp/
// Shaders/SoupRender.metal).
//
// MIRROR CONTRACT (same three layers as BFFShared.h):
//   1. The _Static_asserts below pin every size, alignment, and field offset to
//      documented literals — checked by every C compile, including Linux.
//   2. static_asserts in SoupRender.metal pin the MSL mirror to the SAME literals
//      at Metal compile time.
//   3. `viz_layout_probe` reports sizeof/alignof/offsetof as the Metal compiler
//      laid them out; the renderer refuses to draw unless every reported value
//      equals Swift's MemoryLayout of the struct imported from this header
//      (see VizLayout.hostProbeWords()).
//
// Importing the struct from C (rather than declaring a native Swift struct) is
// what guarantees the host layout is C-standard declaration order — Swift may
// reorder native stored properties, C does not.
//
// All fields are 4 bytes (float / uint32_t): one alignment everywhere, no implicit
// padding, dense arrays.

#ifndef SOUP_RENDER_SHARED_H
#define SOUP_RENDER_SHARED_H

#include <stddef.h>
#include <stdint.h>

/// Per-frame render uniforms, bound as `constant VizUniforms&` (buffer index 0).
/// `microBlend`/`glyphBlend` are evaluated on the host from the shared `LODModel`
/// so the LOD blend definition lives in one tested place, not in the shader.
typedef struct {
    float viewportPxX;   /* offset 0  — drawable width in pixels */
    float viewportPxY;   /* offset 4  — drawable height in pixels */
    float originByteX;   /* offset 8  — soup byte coord at top-left pixel */
    float originByteY;   /* offset 12 */
    float bytePx;        /* offset 16 — pixels per byte cell (LOD variable) */
    float microBlend;    /* offset 20 — smoothstep(0.5,1.5,bytePx) */
    float glyphBlend;    /* offset 24 — smoothstep(12,18,bytePx) */
    uint32_t gridWidth;  /* offset 28 — program grid columns */
    uint32_t gridHeight; /* offset 32 — program grid rows */
    uint32_t programCount; /* offset 36 — real programs; cells >= this are background */
    uint32_t metricChannel; /* offset 40 — 0 activity, 1 entropy, 2 life composite */
    uint32_t flags;      /* offset 44 — reserved, must be 0 */
} VizUniforms;           /* size 48, alignment 4 */

_Static_assert(sizeof(VizUniforms) == 48, "VizUniforms must be 48 bytes");
_Static_assert(_Alignof(VizUniforms) == 4, "VizUniforms must be 4-byte aligned");
_Static_assert(offsetof(VizUniforms, viewportPxX) == 0, "viewportPxX at 0");
_Static_assert(offsetof(VizUniforms, viewportPxY) == 4, "viewportPxY at 4");
_Static_assert(offsetof(VizUniforms, originByteX) == 8, "originByteX at 8");
_Static_assert(offsetof(VizUniforms, originByteY) == 12, "originByteY at 12");
_Static_assert(offsetof(VizUniforms, bytePx) == 16, "bytePx at 16");
_Static_assert(offsetof(VizUniforms, microBlend) == 20, "microBlend at 20");
_Static_assert(offsetof(VizUniforms, glyphBlend) == 24, "glyphBlend at 24");
_Static_assert(offsetof(VizUniforms, gridWidth) == 28, "gridWidth at 28");
_Static_assert(offsetof(VizUniforms, gridHeight) == 32, "gridHeight at 32");
_Static_assert(offsetof(VizUniforms, programCount) == 36, "programCount at 36");
_Static_assert(offsetof(VizUniforms, metricChannel) == 40, "metricChannel at 40");
_Static_assert(offsetof(VizUniforms, flags) == 44, "flags at 44");

#endif /* SOUP_RENDER_SHARED_H */
