# Enterprise ZK Validium Node

This directory will contain the Enterprise ZK Validium Node service -- the core component that receives enterprise transactions, maintains state via Sparse Merkle Trees, generates ZK proofs, and submits them to the Basis Network L1.

## Status

**Planned.** Development is driven by the R&D pipeline (`lab/`).

## References

- [MVP Vision](../../docs/L2_MVP_VISION.md) -- Architecture and motivation
- [Validium Roadmap](../ROADMAP.md) -- Research units and execution plan
- [Execution Checklist](../ROADMAP_CHECKLIST.md) -- Sequential agent tasks

## R&D Pipeline Output

Research, formal specifications, and verification proofs for this component are stored alongside it:

| Artifact | Location |
|----------|----------|
| Experiments and benchmarks | `validium/research/experiments/` |
| Foundational specs (invariants, threats) | `validium/research/foundations/` |
| TLA+ formal specifications | `validium/specs/units/` |
| Adversarial test reports | `validium/tests/adversarial/` |
| Coq verification proofs | `validium/proofs/units/` |
