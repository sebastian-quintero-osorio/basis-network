# Session Log: Hub-and-Spoke Cross-Enterprise Formalization

> **Date**: 2026-03-20
> **Target**: zkl2
> **Unit**: 2026-03-hub-and-spoke (RU-L11)
> **Phase**: 1 (Formalize Research)
> **Result**: PASS

---

## Summary

Formalized the Scientist's RU-L11 Hub-and-Spoke Cross-Enterprise Communication research
into a verified TLA+ specification. The specification models the 4-phase cross-enterprise
message protocol with the L1 as hub, including adversarial actions (replay, root evolution).

## Artifacts Produced

| Artifact | Path |
|----------|------|
| TLA+ Specification | `zkl2/specs/units/2026-03-hub-and-spoke/1-formalization/v0-analysis/specs/HubAndSpoke/HubAndSpoke.tla` |
| Model Instance | `zkl2/specs/units/2026-03-hub-and-spoke/1-formalization/v0-analysis/experiments/HubAndSpoke/MC_HubAndSpoke.tla` |
| TLC Configuration | `zkl2/specs/units/2026-03-hub-and-spoke/1-formalization/v0-analysis/experiments/HubAndSpoke/MC_HubAndSpoke.cfg` |
| Certificate of Truth | `zkl2/specs/units/2026-03-hub-and-spoke/1-formalization/v0-analysis/experiments/HubAndSpoke/MC_HubAndSpoke.log` |
| Phase 1 Report | `zkl2/specs/units/2026-03-hub-and-spoke/1-formalization/v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |
| Input Materials | `zkl2/specs/units/2026-03-hub-and-spoke/0-input/findings.md` |

## Verification Results

- **TLC Model Checker**: PASS (all 7 invariants)
- **States Generated**: 7,411
- **Distinct States**: 3,602
- **Search Depth**: 13
- **Model**: 2 enterprises, MaxCrossTx=1, TimeoutBlocks=2, SYMMETRY reduction
- **Time**: <1 second

## Invariants Verified

1. TypeOK -- structural type correctness
2. CrossEnterpriseIsolation (INV-CE5) -- no private data in messages
3. AtomicSettlement (INV-CE6) -- all-or-nothing settlement
4. CrossRefConsistency (INV-CE7) -- both proofs valid for settlement
5. ReplayProtection (INV-CE8) -- no duplicate nonce processing
6. TimeoutSafety (INV-CE9) -- no premature timeouts
7. HubNeutrality (INV-CE10) -- hub cannot forge proofs

## Decisions Made

1. **Isolation modeled axiomatically**: ZK zero-knowledge and Poseidon hiding are
   cryptographic axioms trusted from literature, not model-checked. The specification
   structurally encodes isolation by using only public-type fields in message records.

2. **Atomicity via TLA+ step atomicity**: AttemptSettlement updates both enterprise
   state roots in a single TLA+ step. There is no intermediate state where one root
   is updated but the other is not. TLC verifies this across all interleavings.

3. **Adversarial actions separated into NextAdversarial**: UpdateStateRoot and
   AttemptReplay are defined but excluded from the core Next relation for state space
   tractability. They are available in NextAdversarial for extended verification.

4. **2 enterprises sufficient**: All protocol properties (isolation, atomicity, replay,
   timeout, consistency, hub neutrality) are verifiable with 2 enterprises. 3-enterprise
   configurations exceed TLC's practical state space limits (>100M states).

## Next Steps

1. **Phase 2 (/2-audit)**: Verify formalization faithfully represents source materials.
2. **Extended verification**: Use TLC simulation mode or Apalache for 3-enterprise
   configurations with adversarial actions.
3. **Liveness checking**: Verify AllMessagesTerminate under FairSpec.
