// cubff evaluator fixture generator.
//
// Runs curated and pseudo-random 128-byte pair tapes through the ACTUAL
// pinned cubff evaluator (compiled unmodified from bff.inc.h via
// eval_bff_heads.cc / eval_bff_noheads.cc) and emits a deterministic JSON
// fixture file on stdout.
//
// The only observables cubff's Evaluate() exposes are:
//   - the final 128-byte tape (mutated in place), and
//   - the returned op count `i - nskip`: executed steps minus "comment"
//     steps (byte 0 and every non-command byte), see bff.inc.h Evaluate().
// Each fixture case records exactly those, plus full provenance.
//
// Input tapes are chosen by this generator (inputs are arbitrary; only the
// EXPECTED outputs must come from cubff). Pseudo-random tapes use cubff's
// own SplitMix64 formula so they are reproducible from the recorded seeds.
//
// Usage: gen_fixtures <upstream-commit-sha> <upstream-url> <build-info>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

size_t CubffEvalBffHeads(uint8_t *tape, size_t stepcount);
size_t CubffEvalBffNoheads(uint8_t *tape, size_t stepcount);

namespace {

constexpr size_t kPairTape = 128;
constexpr size_t kDefaultBudget = 8192;

// Same formula as cubff common_language.h SplitMix64 (used here only to
// derive reproducible random INPUT tapes, never expected outputs).
uint64_t SplitMix64(uint64_t seed) {
  uint64_t z = seed + 0x9e3779b97f4a7c15;
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
  z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
  return z ^ (z >> 31);
}

// The ten BFF command bytes (cubff CommandRepr order: "[]+-.,<>{}").
constexpr uint8_t kCommands[10] = {'[', ']', '+', '-', '.', ',',
                                   '<', '>', '{', '}'};

struct Case {
  std::string name;
  std::string variant;  // upstream language name: "bff" | "bff_noheads"
  size_t budget;
  std::vector<uint8_t> tape;  // input, exactly 128 bytes
  std::string note;
};

std::vector<uint8_t> Tape(std::initializer_list<uint8_t> code) {
  std::vector<uint8_t> t(kPairTape, 0);
  size_t i = 0;
  for (uint8_t b : code) t.at(i++) = b;
  return t;
}

void Set(std::vector<uint8_t> &t, size_t i, uint8_t v) { t.at(i) = v; }

std::vector<Case> BuildCases() {
  std::vector<Case> cases;
  auto add = [&](std::string name, std::string variant,
                 std::vector<uint8_t> tape, std::string note,
                 size_t budget = kDefaultBudget) {
    cases.push_back({std::move(name), std::move(variant), budget,
                     std::move(tape), std::move(note)});
  };

  // --- noheads initialization + ordinary ops ---
  add("noheads-all-zero", "bff_noheads", Tape({}),
      "128 null bytes: every step is a skipped comment, expectedOps must be 0");
  add("noheads-executes-from-zero", "bff_noheads", Tape({'+'}),
      "noheads starts pc=0 heads=0: the '+' increments itself");
  add("noheads-ordinary-ops", "bff_noheads",
      Tape({'>', '>', '+', '<', '-', '}', '.', '{', ','}),
      "one of each head move, inc, dec, copy in both directions");
  add("noheads-head1-moves-then-write", "bff_noheads",
      Tape({'}', '}', '.'}),
      "'.' copies tape[head0=0] into tape[head1=2]");

  // --- head wrapping ---
  add("head0-wrap-backward", "bff_noheads", Tape({'<', '+'}),
      "'<' from 0 wraps head0 to 127 (mask &127); '+' increments tape[127]");
  add("head0-wrap-forward", "bff_noheads", Tape({'<', '>', '+'}),
      "head0 wraps 0->127->wraps back to 0 (128 & 127); '+' hits tape[0]");
  {
    auto t = Tape({'{', ','});
    Set(t, 127, 0xAB);
    add("head1-wrap-backward-read", "bff_noheads", t,
        "'{' wraps head1 to 127; ',' reads tape[127]=0xAB into tape[0]");
  }
  {
    auto t = Tape({'<', '+'});
    Set(t, 127, 255);
    add("inc-wraps-byte", "bff_noheads", t, "'+' wraps 255 -> 0");
  }
  add("dec-wraps-byte", "bff_noheads", Tape({'<', '-'}),
      "'-' wraps 0 -> 255 at tape[127]");

  // --- cross-half copy ---
  add("cross-half-write", "bff_noheads", Tape({'{', '.'}),
      "head1 wraps into the high half; '.' copies tape[0] into tape[127]");
  {
    auto t = Tape({'{', ','});
    Set(t, 64, 0x11);
    Set(t, 127, 0x77);
    add("cross-half-read", "bff_noheads", t,
        "',' copies tape[127] from B's half into tape[0] in A's half");
  }

  // --- balanced loop ---
  {
    std::vector<uint8_t> t(kPairTape, 0);
    for (size_t i = 0; i < 10; i++) t[i] = '>';
    t[10] = 2;
    t[11] = '[';
    t[12] = '-';
    t[13] = ']';
    add("balanced-loop-countdown", "bff_noheads", t,
        "head0 on a cell holding 2; [-] decrements it to 0 and exits");
  }
  add("taken-open-skips-body", "bff_noheads",
      Tape({'<', '[', '+', ']', '+'}),
      "tape[head0=127]==0 so '[' jumps: body '+' skipped, execution resumes "
      "past the matching ']', final '+' runs");
  add("loop-close-reenters-body", "bff_noheads",
      Tape({'+', '[', ']'}),
      "tape[0] nonzero: ']' jumps back; lands one past the '[' so the '[' "
      "is NOT re-executed; spins to the step budget");
  add("loop-close-reenters-body-small-budget", "bff_noheads",
      Tape({'+', '[', ']'}),
      "same spin with a 100-step budget: pins budget accounting exactly",
      /*budget=*/100);

  // --- unmatched brackets (taken) ---
  add("unmatched-open-taken", "bff_noheads", Tape({'<', '['}),
      "taken '[' with no ']' anywhere: scan fails, pc set past the tape, "
      "run halts; the bracket still counts as one executed op");
  add("unmatched-close-taken", "bff_noheads", Tape({'+', ']'}),
      "taken ']' with no '[' behind it: scan fails, pc set to -1, halt");
  add("unmatched-brackets-not-taken", "bff_noheads",
      Tape({'[', '<', ']'}),
      "unmatched brackets whose condition is false fall through harmlessly");

  // --- self-modified bracket behavior ---
  {
    // A program that rewrites a byte into a NEW '[' between the taken '['
    // and its original match, changing what a live scan sees. cubff always
    // scans the live tape, so the jump target reflects the rewrite.
    std::vector<uint8_t> t(kPairTape, 0);
    for (size_t i = 0; i < 28; i++) t[i] = '<';
    t[28] = '+';   // rewrites tape[100] 0x5A -> 0x5B ('[')
    t[29] = '<';
    t[30] = '[';   // taken (tape[99]==0); live scan sees the new '[' at 100
    t[100] = 0x5A; // becomes '[' mid-run
    t[105] = ']';
    t[106] = '+';
    t[107] = '+';
    t[108] = '+';
    t[110] = ']';
    add("self-modified-bracket-live-scan", "bff_noheads", t,
        "28x'<' puts head0=100; '+' turns the 0x5A at 100 into '['; '<' "
        "puts head0=99 (zero); the '[' at 30 is taken and must match the "
        "']' at 110 per the LIVE tape (105 per the original tape). Grounds "
        "that cubff re-scans the live, self-modified tape on every jump");
  }
  {
    auto t = Tape({'<', '+', '+'});
    Set(t, 127, '[');
    add("inc-turns-open-into-close", "bff_noheads", t,
        "'+' twice turns the '[' at 127 (0x5B) into ']' (0x5D); the created "
        "']' executes, is taken, finds no '[' and halts the run");
  }
  {
    auto t = Tape({'<', '+'});
    Set(t, 127, 0x2A);
    add("created-instruction-executes", "bff_noheads", t,
        "'+' turns 0x2A at 127 into '+' (0x2B) ahead of the pc; the created "
        "instruction executes and increments itself to 0x2C");
  }

  // --- op accounting: commands vs comments ---
  {
    std::vector<uint8_t> t(kPairTape, 0);
    t[0] = '+';
    t[1] = 'A';   // non-command noop
    t[2] = 0;     // null comment
    t[3] = '[';   // not taken (tape[0] nonzero after '+'): still a command
    t[4] = '-';
    add("ops-exclude-comments", "bff_noheads", t,
        "cubff's returned op count excludes null and non-command bytes but "
        "includes non-taken brackets; expectedOps must be 3 ('+','[','-')");
  }

  // --- seeded-head (bff) initialization ---
  {
    std::vector<uint8_t> t(kPairTape, 0);
    t[0] = 5;    // head0 seed
    t[1] = 200;  // head1 seed -> 200 % 128 = 72
    t[2] = '+';
    t[3] = '.';
    add("seeded-heads-basic", "bff", t,
        "bff variant: head0=tape[0]%128=5, head1=tape[1]%128=72, pc=2; '+' "
        "bumps tape[5], '.' copies it cross-half into tape[72]");
  }
  add("seeded-heads-zero-seeds", "bff", Tape({0, 0, '+'}),
      "seeds 0/0: heads at 0, pc starts at 2, '+' increments tape[0]");
  {
    std::vector<uint8_t> t(kPairTape, 0);
    t[0] = 130;  // 130 % 128 = 2
    t[1] = 255;  // 255 % 128 = 127
    t[2] = '+';
    t[3] = '.';
    add("seeded-heads-mod-128", "bff", t,
        "seed bytes >=128 reduce mod 128: head0=2, head1=127; '+' bumps the "
        "'+' itself, '.' copies it into tape[127]");
  }
  {
    std::vector<uint8_t> t(kPairTape, 0);
    t[0] = 127;  // head0 on a zero cell
    t[2] = '[';
    add("seeded-heads-unmatched-open", "bff", t,
        "bff variant taken-unmatched '[': head0=127 (zero), pc=2");
  }
  {
    std::vector<uint8_t> t(kPairTape, 0);
    t[0] = 127;
    t[1] = 127;
    t[2] = '>';
    t[3] = '+';
    add("seeded-heads-wrap-forward", "bff", t,
        "head0 seeded to 127; '>' moves it to 128 which masks to 0; '+' "
        "increments tape[0] (the seed byte 127 -> 128)");
  }

  // --- pseudo-random sweeps (both variants) ---
  // Uniform random bytes: mostly comments, occasional commands.
  for (int k = 0; k < 8; k++) {
    for (const char *variant : {"bff_noheads", "bff"}) {
      std::vector<uint8_t> t(kPairTape);
      uint64_t caseSeed =
          0x1000 + 2 * k + (std::string(variant) == "bff" ? 1 : 0);
      for (size_t i = 0; i < kPairTape; i++) {
        t[i] = SplitMix64(caseSeed * kPairTape + i) & 0xFF;
      }
      add("random-uniform-" + std::to_string(k) + "-" + variant, variant, t,
          "uniform random tape, byte[i] = SplitMix64(" +
              std::to_string(caseSeed) + "*128 + i) & 0xFF");
    }
  }
  // Command-rich random tapes: ~50% command bytes, exercising loops,
  // scans, self-modification, and halts heavily.
  for (int k = 0; k < 8; k++) {
    for (const char *variant : {"bff_noheads", "bff"}) {
      std::vector<uint8_t> t(kPairTape);
      uint64_t caseSeed =
          0x2000 + 2 * k + (std::string(variant) == "bff" ? 1 : 0);
      for (size_t i = 0; i < kPairTape; i++) {
        uint64_t r = SplitMix64(caseSeed * kPairTape + i);
        t[i] = (r & 1) ? kCommands[(r >> 1) % 10]
                       : static_cast<uint8_t>((r >> 8) & 0xFF);
      }
      add("random-commandrich-" + std::to_string(k) + "-" + variant, variant,
          t,
          "command-rich random tape: r = SplitMix64(" +
              std::to_string(caseSeed) +
              "*128 + i); command r&1 ? \"[]+-.,<>{}\"[(r>>1)%10] : "
              "(r>>8)&0xFF");
    }
  }

  return cases;
}

void PrintHex(FILE *out, const std::vector<uint8_t> &bytes) {
  for (uint8_t b : bytes) fprintf(out, "%02x", b);
}

void PrintJSONString(FILE *out, const std::string &s) {
  fputc('"', out);
  for (char c : s) {
    if (c == '"' || c == '\\') fputc('\\', out);
    fputc(c, out);
  }
  fputc('"', out);
}

}  // namespace

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr,
            "usage: %s <upstream-commit-sha> <upstream-url> <build-info>\n",
            argv[0]);
    return 1;
  }
  const std::string commit = argv[1];
  const std::string url = argv[2];
  const std::string build = argv[3];

  std::vector<Case> cases = BuildCases();

  printf("{\n");
  printf("  \"formatVersion\": 1,\n");
  printf("  \"upstream\": {\n");
  printf("    \"url\": ");
  PrintJSONString(stdout, url);
  printf(",\n    \"commit\": ");
  PrintJSONString(stdout, commit);
  printf(
      ",\n    \"sourceFiles\": [\"bff.inc.h\", \"common.h\", "
      "\"common_language.h\"],\n");
  printf("    \"build\": ");
  PrintJSONString(stdout, build);
  printf("\n  },\n");
  printf("  \"generator\": {\n");
  printf(
      "    \"command\": \"Tools/cubff-grounding/generate.sh (gen_fixtures "
      "%s)\",\n",
      commit.c_str());
  printf("    \"version\": 1\n");
  printf("  },\n");
  printf("  \"observables\": \"finalTape + ops (cubff Evaluate return: "
         "executed steps minus null/non-command comment steps)\",\n");
  printf("  \"cases\": [\n");

  for (size_t c = 0; c < cases.size(); c++) {
    Case &cs = cases[c];
    if (cs.tape.size() != kPairTape) {
      fprintf(stderr, "case %s: tape is %zu bytes\n", cs.name.c_str(),
              cs.tape.size());
      return 1;
    }
    std::vector<uint8_t> final_tape = cs.tape;
    size_t ops;
    if (cs.variant == "bff") {
      ops = CubffEvalBffHeads(final_tape.data(), cs.budget);
    } else if (cs.variant == "bff_noheads") {
      ops = CubffEvalBffNoheads(final_tape.data(), cs.budget);
    } else {
      fprintf(stderr, "unknown variant %s\n", cs.variant.c_str());
      return 1;
    }

    printf("    {\n");
    printf("      \"name\": ");
    PrintJSONString(stdout, cs.name);
    printf(",\n      \"variant\": ");
    PrintJSONString(stdout, cs.variant);
    printf(",\n      \"stepBudget\": %zu,\n", cs.budget);
    printf("      \"inputTapeHex\": \"");
    PrintHex(stdout, cs.tape);
    printf("\",\n      \"expectedTapeHex\": \"");
    PrintHex(stdout, final_tape);
    printf("\",\n      \"expectedOps\": %zu,\n", ops);
    printf("      \"note\": ");
    PrintJSONString(stdout, cs.note);
    printf("\n    }%s\n", c + 1 == cases.size() ? "" : ",");
  }
  printf("  ]\n}\n");
  return 0;
}
