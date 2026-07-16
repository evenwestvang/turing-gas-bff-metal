// The shared header is macros, typedefs, and _Static_asserts only. This
// translation unit exists so the target has a compiled source on every platform
// — which is exactly what makes the header's layout asserts part of plain
// `swift build`, including on Linux.
#include "BFFShared.h"
