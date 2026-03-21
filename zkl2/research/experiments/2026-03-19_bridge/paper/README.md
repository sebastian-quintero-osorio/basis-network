# Paper Status: RU-L7 Bridge

No academic paper was generated for this experiment.

## Reason

This research unit surveys existing L1-L2 bridge designs (zkSync Era, Polygon zkEVM,
Scroll, Arbitrum) and adapts them to the Basis Network enterprise context. The primary
contribution is the escape hatch mechanism design and double-spend prevention analysis,
which are well-documented patterns in the rollup literature rather than novel research.

The experimental results -- deposit/withdrawal latency, gas costs, escape hatch timing --
are fully documented in `findings.md` and `results/benchmark_results.md`.

## Where to find the research

- `findings.md` -- Complete literature review, escape hatch design, security analysis
- `results/benchmark_results.md` -- Latency and gas benchmarks
- `code/` -- Prototype implementation (Go relayer + Solidity)

## Related papers

- BNR-2026-015 (Hub-and-Spoke) builds on the bridge for cross-enterprise messaging
- BNR-2026-012 (Production DAC) covers the data availability layer that complements the bridge
