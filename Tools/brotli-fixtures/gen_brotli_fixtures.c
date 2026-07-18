/*
 * gen_brotli_fixtures.c — emit authoritative Brotli 1.1.0 quality-2 compressed
 * byte counts for a fixed set of small literal inputs, as JSON.
 *
 * The compression call is byte-identical to cubff's higher-order-complexity
 * measurement (paradigms-of-intelligence/cubff, common_language.h):
 *
 *     BrotliEncoderCompress(2, 24, BROTLI_MODE_GENERIC, n, in, &out_size, out);
 *
 * i.e. quality 2, lgwin 24 (BROTLI_MAX_WINDOW_BITS), generic mode, whole buffer
 * in one shot, output buffer sized by BrotliEncoderMaxCompressedSize(n). The
 * emitted `compressedByteCount` is exactly the `*encoded_size` brotli returns.
 *
 * This tool is compiled and linked against a pinned Brotli 1.1.0 checkout by
 * Tools/brotli-fixtures/generate.sh; it refuses to run against any other encoder
 * version so a fixture can never be minted from the wrong Brotli. The inputs are
 * generated deterministically in-process and echoed as hex, so each fixture case
 * is fully self-contained and regeneration is bit-stable.
 *
 * Args: <commit> <url> <build-info>. Output: fixture JSON on stdout.
 */
#include <brotli/encode.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FIXTURE_FORMAT_VERSION 1
#define GENERATOR_VERSION 1
#define EXPECTED_VERSION_HEX 0x1001000u /* Brotli 1.1.0 */

/* cubff's exact parameters. */
enum { Q = 2, LGWIN = 24, MODE = BROTLI_MODE_GENERIC };

/* SplitMix64 — the same mixer cubff uses; lets a "random" case be reproduced
 * from a recorded seed rather than committing an opaque blob. */
static uint64_t splitmix64(uint64_t *state) {
  uint64_t z = (*state += 0x9E3779B97F4A7C15ull);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}

static const char *OPCODES = "[]+-.,<>{}"; /* cubff CommandRepr(), 10 bytes */

/* Fill `buf` (length n) with one of the deterministic patterns. */
static void fill(const char *kind, uint8_t *buf, size_t n) {
  if (!strcmp(kind, "zeros")) {
    memset(buf, 0, n);
  } else if (!strcmp(kind, "constA")) {
    memset(buf, 0x41, n);
  } else if (!strcmp(kind, "opcodes-cycle")) {
    for (size_t i = 0; i < n; i++) buf[i] = (uint8_t)OPCODES[i % 10];
  } else if (!strcmp(kind, "iota")) {
    for (size_t i = 0; i < n; i++) buf[i] = (uint8_t)(i & 0xFF);
  } else if (!strcmp(kind, "splitmix")) {
    uint64_t s = 0x9E3779B97F4A7C15ull;
    for (size_t i = 0; i < n; i++) buf[i] = (uint8_t)(splitmix64(&s) & 0xFF);
  } else if (!strcmp(kind, "opcode-soup")) {
    /* command-rich but structured: each byte is a random opcode */
    uint64_t s = 0xD1B54A32D192ED03ull;
    for (size_t i = 0; i < n; i++) buf[i] = (uint8_t)OPCODES[splitmix64(&s) % 10];
  } else {
    fprintf(stderr, "unknown pattern '%s'\n", kind);
    exit(2);
  }
}

static size_t brotli_q2(const uint8_t *in, size_t n) {
  size_t cap = BrotliEncoderMaxCompressedSize(n);
  if (cap == 0) cap = 64; /* MaxCompressedSize(0) can be 0; give the empty case room */
  uint8_t *out = (uint8_t *)malloc(cap);
  if (!out) { fprintf(stderr, "oom\n"); exit(3); }
  size_t out_size = cap;
  BROTLI_BOOL ok = BrotliEncoderCompress(Q, LGWIN, MODE, n, in, &out_size, out);
  if (!ok) { fprintf(stderr, "BrotliEncoderCompress failed for n=%zu\n", n); exit(4); }
  free(out);
  return out_size;
}

static void print_hex(const uint8_t *b, size_t n) {
  for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
}

/* Emit one JSON case object. `first` controls the leading comma. */
static void emit_case(int *first, const char *name, const char *note,
                      const char *kind, size_t n) {
  uint8_t *buf = n ? (uint8_t *)malloc(n) : (uint8_t *)malloc(1);
  if (!buf) { fprintf(stderr, "oom\n"); exit(3); }
  if (n) fill(kind, buf, n);
  size_t comp = brotli_q2(buf, n);
  printf("%s\n    {\n", *first ? "" : ",");
  *first = 0;
  printf("      \"name\": \"%s\",\n", name);
  printf("      \"note\": \"%s\",\n", note);
  printf("      \"inputByteCount\": %zu,\n", n);
  printf("      \"inputHex\": \"");
  print_hex(buf, n);
  printf("\",\n");
  printf("      \"compressedByteCount\": %zu\n", comp);
  printf("    }");
  free(buf);
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s <commit> <url> <build-info>\n", argv[0]);
    return 64;
  }
  const char *commit = argv[1];
  const char *url = argv[2];
  const char *build = argv[3];

  uint32_t v = BrotliEncoderVersion();
  if (v != EXPECTED_VERSION_HEX) {
    fprintf(stderr,
            "linked Brotli version 0x%x != expected 0x%x (1.1.0); refusing to "
            "mint fixtures from a non-authoritative encoder\n",
            v, EXPECTED_VERSION_HEX);
    return 5;
  }

  printf("{\n");
  printf("  \"formatVersion\": %d,\n", FIXTURE_FORMAT_VERSION);
  printf("  \"brotli\": {\n");
  printf("    \"url\": \"%s\",\n", url);
  printf("    \"commit\": \"%s\",\n", commit);
  printf("    \"version\": \"1.1.0\",\n");
  printf("    \"versionHex\": \"0x%x\",\n", v);
  printf("    \"build\": \"%s\"\n", build);
  printf("  },\n");
  printf("  \"parameters\": {\n");
  printf("    \"quality\": %d,\n", Q);
  printf("    \"lgwin\": %d,\n", LGWIN);
  printf("    \"mode\": \"generic\",\n");
  printf("    \"call\": \"BrotliEncoderCompress(2, 24, BROTLI_MODE_GENERIC, n, in, &out, buf)\"\n");
  printf("  },\n");
  printf("  \"generator\": {\n");
  printf("    \"command\": \"Tools/brotli-fixtures/generate.sh\",\n");
  printf("    \"version\": %d\n", GENERATOR_VERSION);
  printf("  },\n");
  printf("  \"observables\": \"compressedByteCount = *encoded_size from "
         "BrotliEncoderCompress(quality=2, lgwin=24, BROTLI_MODE_GENERIC) over "
         "the exact inputHex bytes; the count cubff logs as brotli_size.\",\n");
  printf("  \"cases\": [");

  int first = 1;
  emit_case(&first, "empty", "zero-length input; edge case for the encoder", "zeros", 0);
  emit_case(&first, "single-zero", "one null byte", "zeros", 1);
  emit_case(&first, "zeros-64", "one all-zero 64-byte program tape (constant init floor)", "zeros", 64);
  emit_case(&first, "constA-128", "128 bytes of 0x41 — a single long run", "constA", 128);
  emit_case(&first, "opcodes-cycle-128", "the ten BFF opcodes cycled to 128 bytes (period-10 structure)", "opcodes-cycle", 128);
  emit_case(&first, "iota-256", "bytes 0..255 once each — flat histogram, no repeats", "iota", 256);
  emit_case(&first, "splitmix-256", "256 SplitMix64(seed=0x9E3779B97F4A7C15) bytes — high-entropy", "splitmix", 256);
  emit_case(&first, "opcode-soup-256", "256 random-opcode bytes (10-symbol alphabet) — command-rich", "opcode-soup", 256);

  printf("\n  ]\n}\n");
  return 0;
}
