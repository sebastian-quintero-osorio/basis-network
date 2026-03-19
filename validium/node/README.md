# Enterprise ZK Validium Node

The Enterprise ZK Validium Node service -- receives enterprise transactions, maintains
state via Sparse Merkle Trees, generates ZK proofs, and submits them to the Basis Network L1.

## Status

**R&D pipeline complete (28/28 agent executions).** All 7 modules implemented, tested,
formally specified (TLA+), and verified (Coq). Integration pending (see POST_ROADMAP_TODO.md).

## Modules

| Module | Directory | Tests |
|--------|-----------|-------|
| SparseMerkleTree (Poseidon, BN128) | `src/state/` | 52 |
| TransactionQueue + WAL | `src/queue/` | 66 |
| BatchAggregator + BatchBuilder | `src/batch/` | 45 |
| DACProtocol + Shamir SSS | `src/da/` | 67 |
| ZK Prover (snarkjs Groth16) | `src/prover/` | -- |
| L1 Submitter (ethers.js v6) | `src/submitter/` | -- |
| REST API (Fastify) | `src/api/` | -- |
| Orchestrator (state machine) | `src/orchestrator.ts` | 19 |
| Cross-Enterprise | `src/cross-enterprise/` | 19 |

## References

- [R&D Pipeline Report](../docs/R&D_PIPELINE_REPORT.md) -- Full pipeline execution summary
- [Post-Roadmap TODO](../docs/POST_ROADMAP_TODO.md) -- Integration plan
- [Validium Roadmap](../docs/ROADMAP.md) -- Research units and execution plan
- [Execution Checklist](../docs/ROADMAP_CHECKLIST.md) -- 28/28 complete

## R&D Artifacts

| Artifact | Location |
|----------|----------|
| Experiments and benchmarks | `validium/research/experiments/` |
| Foundational specs (invariants, threats) | `validium/research/foundations/` |
| TLA+ formal specifications | `validium/specs/units/` |
| Adversarial test reports | `validium/tests/adversarial/` |
| Coq verification proofs | `validium/proofs/units/` |
