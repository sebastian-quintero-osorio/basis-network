# Session Log: Hub-and-Spoke Cross-Enterprise Communication (RU-L11)

- **Date:** 2026-03-20
- **Target:** zkl2
- **Experiment:** hub-and-spoke
- **Stage:** 1 (Implementation)
- **Iteration:** 1

## What Was Accomplished

### Literature Review (19 sources)

Comprehensive review of enterprise privacy systems, multi-chain aggregation, cross-chain
privacy protocols, and messaging systems. Key references:
- Rayls/Enygma (IACR 2025/1638, IEEE S&P 2024): Production hub-and-spoke for CBDCs
- Polygon AggLayer: Pessimistic proofs for cross-chain safety
- zkSync Elastic Chain: ZK Router + Gateway + shared bridge
- zkCross (IACR 2024/888), P2C2T (IACR 2024/1467): Cross-chain privacy protocols
- Avalanche ICM/AWM: Native cross-L1 messaging with BLS multi-signatures

### Architecture Design

Hub-and-spoke model with Basis Network L1 as hub:
- Enterprises are spokes (each an L2 chain with private state)
- CrossEnterpriseHub contract on L1: routing, ZK verification, atomic settlement
- CrossEnterpriseMessage protocol: commitment + ZK proof + state root + nonce
- Two-phase atomic settlement with timeout mechanism
- ProtoGalaxy proof aggregation reduces gas from >800K to 243K

### Implementation

Go reference design + Python benchmark harness:
- Hub contract simulation with full verification pipeline
- Enterprise spoke simulation with ZK proof generation
- 6 benchmark suites: latency, gas, throughput, privacy, atomic settlement, scaling
- 30 replications per scenario, statistical analysis with 95% CI

### Benchmark Results

| Criterion | Target | Measured | Status |
|-----------|--------|----------|--------|
| Cross-enterprise latency | < 30s | 10.5-16.0s | MET |
| L1 verification gas (aggregated) | < 500K | 243K | MET |
| Privacy leakage | Zero state leakage | 1 bit (existence) | MET |
| Atomic settlement | 100% | 100% (30/30) | MET |
| Throughput | > 10 msg/s | 20.5 msg/s | MET |

**Hypothesis: CONFIRMED.** All 5 success criteria met with aggregated strategy.

### Key Finding

Aggregation is REQUIRED. Sequential (813K/cross-ref) and batched pairing (860K for
8e/4cr) both exceed 500K gas target at 8 enterprises. Only ProtoGalaxy aggregation
(243K constant regardless of N) meets the target.

## Artifacts Produced

| Artifact | Path |
|----------|------|
| Findings (19 sources + benchmarks) | `zkl2/research/experiments/2026-03-19_hub-and-spoke/findings.md` |
| Go reference design | `zkl2/research/experiments/2026-03-19_hub-and-spoke/code/main.go` |
| Python benchmark | `zkl2/research/experiments/2026-03-19_hub-and-spoke/code/benchmark.py` |
| Benchmark results (JSON) | `zkl2/research/experiments/2026-03-19_hub-and-spoke/results/benchmark-results.json` |
| State file | `zkl2/research/experiments/2026-03-19_hub-and-spoke/state.json` |
| Session memory | `zkl2/research/experiments/2026-03-19_hub-and-spoke/memory/session.md` |
| Journal update | `zkl2/research/experiments/2026-03-19_hub-and-spoke/journal.md` |
| Invariants (I-40 to I-45) | `zkl2/research/foundations/zk-01-objectives-and-invariants.md` |
| Threats (T-36 to T-42) | `zkl2/research/foundations/zk-02-threat-model.md` |

## Decisions Made

1. Hub-and-spoke over mesh topology: O(N) vs O(N^2) connections, fault isolation,
   natural enterprise mapping. L1 decentralization eliminates SPoF concern.

2. ProtoGalaxy aggregation required: Sequential and batched pairing gas costs exceed
   target at N >= 8 enterprises. Only aggregation provides constant-gas scaling.

3. Two-phase atomic settlement: prepare (both proofs) then settle (atomic update).
   Timeout mechanism prevents griefing. No funds locked during prepare phase.

4. 1-bit leakage is acceptable: Information-theoretic minimum for verifiable
   cross-enterprise interaction. Same as RU-V7 baseline, same as Rayls/Enygma.

## Next Steps

1. Handoff to Logicist (checklist item 42): TLA+ formalization of hub-and-spoke protocol.
   Invariants: Isolation, CrossConsistency, AtomicSettlement.
   Model: 3 enterprises, 2 cross-enterprise transactions.
   Adversarial: break isolation, partial settlement.

2. Handoff to Architect (checklist item 43): Go implementation (protocol layer) +
   Solidity implementation (L1 hub contract). Cross-enterprise routing, atomic
   settlement, replay protection.

3. Handoff to Prover (checklist item 44): Coq verification of Isolation and
   AtomicSettlement (critical security/privacy properties).
