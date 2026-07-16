# Turing Gas — BFF Metal

A realtime macOS implementation and zoomable visualization of the BFF computational-life experiment described in [*Computational Life: How Well-formed, Self-replicating Programs Emerge from Simple Interaction*](https://arxiv.org/abs/2406.19108).

The simulation uses Swift and Metal to run a large population of interacting, self-modifying BFF programs on Apple silicon. At macro scale, the visualization shows aggregate entropy and activity; at close range, it exposes individual program bytes and instructions.

## Status

The CPU oracle (`BFFOracle` library, `bff-oracle` CLI, golden fixtures) is implemented and grounded against cubff. The normative dynamic-scan Metal evaluator and its host-side GPU fixture parity runner (`BFFMetal`, `bff-metal-parity`) are implemented — see [Docs/GPUFixtureParity.md](Docs/GPUFixtureParity.md) for what is and is not validated. A deterministic small-soup epoch loop around that evaluator — mutation, Fisher–Yates pairing, GPU dispatch, scatter, per-epoch counters, per-program activity/entropy metrics, and a sampled CPU-shadow comparison — is implemented with a headless runner (`bff-metal-soup`); see [Docs/MetalSoupSlice.md](Docs/MetalSoupSlice.md). The macOS app (`SoupScope`) exists as a placeholder scaffold; the renderer is not implemented.

## Building

Everything is one Swift package with no external dependencies (Swift 6 toolchain required).

```sh
swift test                 # all tests — runs on macOS and Linux
swift run bff-oracle       # headless CPU oracle CLI
swift run bff-metal-parity # macOS only: GPU fixture parity (exits 2 elsewhere)
swift run bff-metal-soup   # macOS only: headless small-soup epoch runner (exits 2 elsewhere)
swift run SoupScope        # macOS only: opens the static placeholder window
```

On non-macOS platforms `SoupScope` builds as a stub executable that prints its wiring line, so `swift build`/`swift test` cover the whole package on Linux CI.

## References

- Blaise Agüera y Arcas et al., [*Computational Life*](https://arxiv.org/abs/2406.19108)
- Authors' reference implementation: [`paradigms-of-intelligence/cubff`](https://github.com/paradigms-of-intelligence/cubff)

## License

MIT
