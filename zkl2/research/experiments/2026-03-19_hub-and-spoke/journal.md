# Journal: Hub-and-Spoke Cross-Enterprise Communication

> Target: zkl2 | Domain: enterprise-privacy | RU-L11

---

## 2026-03-19 -- Experiment Created

### Context

RU-L11 is the capstone of the zkEVM L2 pipeline. It builds on:
- RU-L10: Proof aggregation (ProtoGalaxy folding + Groth16 decider, 15.3x gas savings at N=8)
- RU-L7: Bridge design (lock-mint, escape hatch, ~5s deposit / ~21s withdrawal on Avalanche)
- All Phase 1-4 components (executor, sequencer, state DB, witness gen, rollup, DAC, PLONK)

### Key Question

How can multiple enterprise L2 chains interact with each other while maintaining complete
data isolation? The hub (L1) must verify cross-enterprise interactions without learning
the private state of any enterprise.

### Prior Art (Validium RU-V7)

The Validium MVP investigated basic cross-enterprise verification with the
CrossEnterpriseVerifier contract. That was application-specific (hash references between
enterprise state roots). RU-L11 generalizes this to arbitrary cross-enterprise transactions
with ZK privacy.

### What Would Change My Mind

- If cross-enterprise ZK proofs require revealing enterprise-internal state to a third party
- If the latency overhead of generating cross-enterprise proofs exceeds 5 minutes
- If atomic settlement requires a trusted coordinator that breaks the trust model
- If hub-and-spoke creates a single point of failure that mesh topology avoids

### Next Steps

1. Literature review (15+ sources) -- DONE
2. Published benchmarks collection -- DONE
3. Architecture design -- DONE
4. Go + Python prototype implementation -- DONE

---

## 2026-03-20 -- Stage 1 Implementation Complete

### Literature Review (19 sources)

Comprehensive review covering:
- Enterprise privacy systems: Rayls/Enygma (IACR 2025/1638, IEEE S&P 2024), Project EPIC (J.P. Morgan Kinexys 2024), AvaCloud institutional privacy
- Multi-chain aggregation: Polygon AggLayer (pessimistic proofs), zkSync Elastic Chain (shared bridge, ZK Router), SnarkPack (FC 2022), Nebra UPA
- Cross-chain privacy: zkCross (IACR 2024/888), P2C2T (IACR 2024/1467), UltraMixer (IACR 2025/1715)
- Messaging protocols: Avalanche ICM/AWM (BLS multi-sig), IBC (IEEE DAPPS 2023), LayerZero v2, Axelar, Chainlink CCIP
- Prior Basis Network: RU-V7 (cross-enterprise), RU-L10 (proof aggregation), RU-L7 (bridge)

### Architecture Design

Hub-and-spoke with L1 as hub:
- Enterprises are spokes (each an L2 chain)
- Hub contract on L1: message routing, ZK verification, atomic settlement, replay protection
- CrossEnterpriseMessage protocol: commitment + ZK proof + state root + nonce
- Two-phase atomic settlement: prepare (both proofs) -> settle (atomic state update)
- Proof aggregation: ProtoGalaxy folds all batch + cross-ref proofs -> Groth16 decider -> 243K gas

### Benchmark Results (30 replications)

**Latency** (model-based):
- Direct cross-enterprise: 10,500 ms (< 30s target, MET)
- Aggregated (N=8): 16,000 ms (< 30s target, MET)
- Atomic settlement: 15,500 ms (< 30s target, MET)

**Gas costs** (8 enterprises, 4 cross-refs):
- Sequential: 3,252,000 gas (NOT MET for 500K target)
- Batched pairing: 860,000 gas (NOT MET for 500K target)
- Aggregated (ProtoGalaxy): 243,000 gas (MET for 500K target)

**Key finding**: Aggregation is REQUIRED for multi-enterprise scenarios.
Sequential and batched pairing both exceed 500K gas at 8 enterprises.

**Privacy**: All 8 tests PASS. 1-bit leakage per interaction (existence only).
**Atomic settlement**: 100% success for valid txs; 100% failure for stale/one-sided/self-ref.
**Throughput**: 20.5 msg/s (aggregated), 31.0 msg/s (batched), 9.5 msg/s (sequential).

### Hypothesis: CONFIRMED

All 5 success criteria met with aggregated strategy.

### What Would Change My Mind

- If ProtoGalaxy folding adds >5s per step in practice (250ms modeled)
- If atomic settlement timeout enables economic griefing attacks
- If regulatory requirements mandate more than 1-bit cross-enterprise visibility
- If N > 50 enterprises causes aggregation latency to exceed 30s (currently 31.75s at N=50)

### Next Steps

1. Stage 2: Baseline with stochastic variation (random enterprise sizes, varying cross-ref densities)
2. Stage 3: Adversarial scenarios (malicious hub, compromised enterprise, replay attacks)
3. Stage 4: Ablation (remove aggregation, remove atomic settlement, vary privacy model)
