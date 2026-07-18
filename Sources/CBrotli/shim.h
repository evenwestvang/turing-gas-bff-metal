/* Umbrella shim for the Brotli encoder module.
 *
 * We use only the one-shot encoder API — BrotliEncoderCompress,
 * BrotliEncoderMaxCompressedSize, BrotliEncoderVersion, and the
 * BROTLI_MODE_GENERIC / BROTLI_MAX_WINDOW_BITS constants — all declared in
 * <brotli/encode.h>. The header is resolved through pkg-config (Linux) or
 * Homebrew (macOS); see Package.swift's `pkgConfig`/`providers`. */
#include <brotli/encode.h>
