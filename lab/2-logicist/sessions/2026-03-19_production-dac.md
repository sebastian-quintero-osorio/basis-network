# Session Log: Production DAC Formalization

- **Date**: 2026-03-19
- **Target**: zkl2
- **Unit**: production-dac
- **Phase**: 1 (Formalize Research)
- **Result**: PASS (all safety invariants + all liveness properties)

---

## Accomplished

Formalized the Production DAC protocol (RU-L8) as TLA+ specification `ProductionDAC.tla`, extending Validium RU-V6 `DataAvailability.tla` with Reed-Solomon erasure coding, KZG verification gate, and explicit corruption model.

### Artifacts Produced

| Artifact | Path |
|----------|------|
| TLA+ specification | `zkl2/specs/units/2026-03-production-dac/1-formalization/v0-analysis/specs/ProductionDAC/ProductionDAC.tla` |
| Model instance (7 nodes) | `zkl2/.../experiments/ProductionDAC/MC_ProductionDAC.tla` |
| Safety config (7 nodes) | `zkl2/.../experiments/ProductionDAC/MC_ProductionDAC_safety.cfg` |
| Liveness model (5 nodes) | `zkl2/.../experiments/ProductionDAC/MC_ProductionDAC_liveness.tla` |
| Liveness config (5 nodes) | `zkl2/.../experiments/ProductionDAC/MC_ProductionDAC_liveness.cfg` |
| Safety TLC log | `zkl2/.../experiments/ProductionDAC/MC_ProductionDAC_safety.log` |
| Phase 1 report | `zkl2/.../v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |

### Verification Results

**Safety (7 nodes, 2 malicious, 5-of-7 threshold):**
- 141M states generated, 16.8M distinct, depth 27
- ALL 8 INVARIANTS PASS (5 min 9 sec, 4 workers)

**Liveness (5 nodes, 2 malicious, 3-of-5 threshold):**
- 2.4M states generated, 395K distinct, depth 21
- ALL 8 INVARIANTS + 2 TEMPORAL PROPERTIES PASS (10 min 38 sec, 4 workers)
- Final temporal check on 791K states: 9 min 52 sec

## Key Decisions

1. **Explicit CorruptChunk action** instead of implicit corruption in RecoverData (RU-V6 approach). This models the temporal aspect of corruption (before vs after verification) and makes ErasureSoundness a non-trivial emergent property.

2. **SF for VerifyChunk** (not WF). The two-step gate (verify then attest) requires strong fairness on both steps because crashes intermittently disable verification, same as attestation.

3. **CorruptChunk guard: recoverState = "none"**. Post-recovery corruption is semantically irrelevant and creates a temporal mismatch with invariants that check current corruption state against past recovery sets.

4. **Split verification**: 7-node model for safety invariants, 5-node model for temporal properties. The 7-node model with liveness checking produces a state space too large for SCC analysis in reasonable time.

5. **ErasureSoundness requires |S| >= Threshold**. With sub-threshold recovery sets, the outcome is "failed" (insufficient chunks for RS decoding), not "corrupted". The commitment check only applies when RS decoding is attempted.

## Counterexamples Found

Three counterexamples discovered and resolved during formalization (documented in PHASE-1-FORMALIZATION_NOTES.md, Section 3.3). Each led to a genuine specification improvement, not an invariant weakening.

## Next Steps

1. Proceed to Phase 2 (`/2-audit`) -- verify formalization faithfully represents the source
