# Paper Status: RU-L5 BasisRollup

No academic paper was generated for this experiment.

## Reason

This research unit is primarily a survey and integration exercise of existing rollup
contract patterns (zkSync Era, Polygon zkEVM, Scroll) adapted to the Basis Network
enterprise context. The findings document established design patterns (commit-prove-execute
lifecycle, state root chaining, gas optimization) rather than novel research contributions.

The experimental results -- gas benchmarks, contract architecture comparisons -- are fully
documented in `findings.md` and `results/gas-benchmarks.md`.

## Where to find the research

- `findings.md` -- Complete literature review and design decisions
- `results/gas-benchmarks.md` -- Gas cost analysis
- `code/` -- Prototype implementation

## Related papers

- BNR-2026-008 (EVM Executor) covers the execution layer that feeds into BasisRollup
- BNR-2026-014 (Proof Aggregation) covers recursive verification that extends BasisRollup
