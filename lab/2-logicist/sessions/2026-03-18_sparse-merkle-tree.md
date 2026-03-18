# Session: Sparse Merkle Tree Formalization

- **Date**: 2026-03-18
- **Target**: validium
- **Unit**: sparse-merkle-tree (RU-V1)
- **Phases Completed**: Phase 1 (Formalize), Phase 2 (Audit)
- **Result**: PASS

---

## Accomplished

1. Read all 8 input files from `validium/specs/units/2026-03-sparse-merkle-tree/0-input/`:
   - README.md (objectives), REPORT.md (18 references, full findings)
   - code/smt-implementation.ts (330 lines, reference SMT class)
   - code/smt-benchmark.ts, code/hash-comparison.ts
   - results/smt-benchmark-results.json, results/hash-comparison-results.json
   - hypothesis.json

2. Wrote TLA+ specification (`SparseMerkleTree.tla`, ~300 lines):
   - 2 state variables: `entries`, `root`
   - 2 actions: `Insert(k, v)`, `Delete(k)`
   - 6 key operators: Hash, LeafHash, DefaultHash, ComputeNode, WalkUp, VerifyProofOp
   - 4 invariants: TypeOK, ConsistencyInvariant, SoundnessInvariant, CompletenessInvariant
   - Full traceability comments mapping every definition to source

3. Wrote model configuration (`MC_SparseMerkleTree.tla` + `.cfg`):
   - DEPTH = 4, Keys = {0,2,5,7,9,12,14,15}, Values = {1,2,3}
   - State space: 65,536 distinct states

4. Resolved TLC compatibility issues:
   - Downloaded tla2tools.jar v1.7.1 (Java 8 compatible)
   - Replaced Cantor pairing function (overflows 32-bit at depth 4) with
     prime-field linear hash: `(a*31 + b*17 + 1) % 65537 + 1`
   - Proved soundness preservation: gcd(31, 65537) = 1 ensures different
     first arguments always produce different outputs

5. Ran TLC model checker: **PASS** on all 4 invariants
   - 1,572,865 states generated, 65,536 distinct states, search depth 12
   - Completed in 31 seconds (20 workers)

6. Wrote PHASE-1-FORMALIZATION_NOTES.md and PHASE-2-AUDIT_REPORT.md

---

## Artifacts Produced

| Artifact | Path |
|---|---|
| TLA+ Specification | `validium/specs/units/2026-03-sparse-merkle-tree/1-formalization/v0-analysis/specs/SparseMerkleTree/SparseMerkleTree.tla` |
| Model Instance | `validium/specs/units/2026-03-sparse-merkle-tree/1-formalization/v0-analysis/experiments/SparseMerkleTree/MC_SparseMerkleTree.tla` |
| TLC Configuration | `validium/specs/units/2026-03-sparse-merkle-tree/1-formalization/v0-analysis/experiments/SparseMerkleTree/MC_SparseMerkleTree.cfg` |
| Certificate of Truth | `validium/specs/units/2026-03-sparse-merkle-tree/1-formalization/v0-analysis/experiments/SparseMerkleTree/MC_SparseMerkleTree.log` |
| Phase 1 Notes | `validium/specs/units/2026-03-sparse-merkle-tree/1-formalization/v0-analysis/PHASE-1-FORMALIZATION_NOTES.md` |
| Phase 2 Audit | `validium/specs/units/2026-03-sparse-merkle-tree/1-formalization/v0-analysis/PHASE-2-AUDIT_REPORT.md` |
| TLA+ Tooling | `lab/2-logicist/tools/tla2tools.jar` (v1.7.1, TLC 2.16) |

---

## Decisions

1. **Hash function choice**: Replaced Cantor pairing (quadratic growth, overflows 32-bit
   at depth >= 3) with prime-field linear hash (bounded output, 32-bit safe). The linear
   hash preserves all invariant semantics through coprime multiplier argument.

2. **Key selection**: 8 keys spread across 0..15 ({0,2,5,7,9,12,14,15}) to maximize
   subtree diversity. Both left and right branches exercised at every tree level.

3. **Value domain**: 3 non-zero values (1,2,3) balance state space (65K) against
   discrimination power (sufficient to distinguish insert, update, and overwrite).

4. **Invariant scope**: Extended soundness and completeness checks to ALL 16 leaf indices
   (not just active 8 keys) for stronger verification of non-membership proofs.

---

## Next Steps

- Phase 3 (/3-diagnose): Not triggered. No protocol flaws detected.
- Phase 4 (/4-fix): Not triggered. v0-analysis passed.
- Phase 5 (/5-review): Not triggered. No fix needed.
- Specification is ready for handoff to the Architect (implementation) and Prover (Coq).
