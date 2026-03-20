# Phase 1: Formalization Notes -- PLONK Migration (RU-L9)

> **Unit**: plonk-migration
> **Target**: zkl2
> **Date**: 2026-03-19
> **Result**: PASS (all 9 invariants hold)

---

## 1. Research-to-Specification Mapping

| Source Material | TLA+ Element | Mapping |
|----------------|-------------|---------|
| REPORT.md Section 4.1 -- Existing Groth16 Infrastructure | `Init` state | System starts in `groth16_only` with `activeVerifiers = {"groth16"}` |
| REPORT.md Section 4.3 -- Phase 1: Dual Verification | `StartDualVerification` | Transition to `dual` phase, both verifiers active |
| REPORT.md Section 4.3 -- Phase 2: PLONK-Only | `CutoverToPlonkOnly` | Transition to `plonk_only` with empty-queue guard |
| REPORT.md Section 4.3 -- BasisRollup.sol router pattern | `VerifyBatch` | Routes verification based on `batch.proofSystem \in activeVerifiers` |
| REPORT.md Section 6.2 -- What Would Change Our Mind | `DetectFailure` | Models critical failure detection during dual phase |
| REPORT.md Section 8 -- Soundness preservation | `Soundness` invariant | Every verified batch has valid=TRUE proof record |
| REPORT.md Section 8 -- Migration safety | `MigrationSafety` invariant | Every submitted seqNo exists in queue or registry |
| REPORT.md Section 8 -- Backward compatibility | `BackwardCompatibility` invariant | Groth16 proofs accepted in phases where Groth16 is active |
| User requirement -- Rollback | `RollbackMigration`, `CompleteRollback` | Revert to groth16_only on failure detection |

## 2. Proof System Axioms

The specification axiomatizes three properties of the underlying cryptographic systems:

| Axiom | TLA+ Modeling | Verification Level |
|-------|--------------|-------------------|
| **Soundness** | `batch.proofSystem \in activeVerifiers => valid=TRUE` (by `VerifyBatch` construction) | State-machine level; cryptographic soundness assumed |
| **Completeness** | Same as soundness -- active verifiers accept correct proofs | State-machine level; cryptographic completeness assumed |
| **Zero-Knowledge** | Not modeled -- property of BN254 pairing construction | Cryptographic protocol level (outside TLA+ scope) |

The key insight: at the state-machine level, soundness and completeness are symmetric.
A verifier either accepts (if its proof system is active) or rejects (if not). The
cryptographic guarantee that "accept means correct" and "correct means accept" is
assumed as an axiom and delegated to the Prover agent for Coq verification.

## 3. Assumptions

1. **Single verification per batch**: Each batch is verified exactly once (FIFO queue).
   In practice, a rejected batch could be resubmitted with a different proof system.
   This is modeled as a new batch (new seqNo), not a re-verification.

2. **Atomic phase transitions**: Phase changes are instantaneous. In the real system,
   a governance transaction on L1 triggers the phase change. We model this as a single
   atomic step, which is conservative (the real system may have a brief period where
   the transaction is pending).

3. **No concurrent verification**: Each enterprise's queue is processed sequentially.
   The real BasisRollup.sol processes batches in submission order per enterprise.

4. **Proof generation is external**: The TLA+ model does not model proof generation.
   We assume any submitted batch has a corresponding proof. The `proofSystem` field
   determines which verifier handles it.

5. **Rollback is manual**: `DetectFailure` and `RollbackMigration` are separate actions.
   Detection may happen automatically (e.g., gas monitor), but rollback requires
   governance action. We model both as non-deterministic actions.

## 4. Design Decisions During Formalization

### 4.1 Phase-Stamped Proof Records

**Decision**: Added `phase` field to `ProofRecord` to record the migration phase at
verification time.

**Rationale**: Without phase stamps, the `Completeness` invariant fails. Consider:
a PLONK batch verified during `groth16_only` (rejected, valid=FALSE). After
`StartDualVerification`, "plonk" enters `activeVerifiers`. The invariant
`r.batch.proofSystem \in activeVerifiers => r.valid = TRUE` now evaluates the
historical record against the CURRENT activeVerifiers, producing a false violation.

The phase stamp resolves this temporal ambiguity by evaluating each record against
the verifiers that were active at its verification time via `VerifiersForPhase(r.phase)`.

### 4.2 Open Submission (Any Proof System)

**Decision**: `SubmitBatch` allows `ps \in ProofSystems` (not restricted to `activeVerifiers`).

**Rationale**: Models the realistic scenario where an enterprise's prover is not
synchronized with the network's migration state. A stale Groth16 prover may submit
after cutover to PLONK-only. The system handles this gracefully: the batch is submitted
(enters queue), verified (rejected with valid=FALSE), and recorded in the registry.
No batch is lost; no crash occurs.

### 4.3 Empty-Queue Cutover Guard

**Decision**: `CutoverToPlonkOnly` requires `\A e \in Enterprises: batchQueue[e] = << >>`.

**Rationale**: This is the structural guarantee of `MigrationSafety`. Without this guard,
a Groth16 batch in-flight during cutover would be stranded: submitted under dual phase
(both verifiers active) but verified under plonk_only (only PLONK active). The empty-queue
guard ensures all batches are processed before the Groth16 verifier is deactivated.

### 4.4 Rollback Blocks New Submissions

**Decision**: `SubmitBatch` is disabled during rollback phase (`migrationPhase /= "rollback"`).

**Rationale**: During rollback, the system is draining existing queues. Accepting new
submissions could prevent the queue from emptying, blocking `CompleteRollback`. This
is a conservative design choice that prioritizes reaching a stable state.

## 5. Verification Results

### Configuration

| Parameter | Value |
|-----------|-------|
| Enterprises | {"e1", "e2", "e3"} |
| MaxBatches | 2 |
| ProofSystems | {"groth16", "plonk"} |
| MaxMigrationSteps | 2 |
| Workers | 4 |

### Results

| Metric | Value |
|--------|-------|
| States generated | 9,117,756 |
| Distinct states | 3,985,171 |
| State graph depth | 22 |
| Time | 37 seconds |
| Result | **PASS** (no violations) |
| Fingerprint collision probability | < 1.1 x 10^-6 |

### Invariants Verified

| # | Invariant | Description | Result |
|---|-----------|-------------|--------|
| S1 | TypeOK | Type correctness of all variables | PASS |
| S2 | MigrationSafety | No batch lost during migration | PASS |
| S3 | BackwardCompatibility | Groth16 accepted in groth16_only/dual phases | PASS |
| S4 | Soundness | No false positives in verifiedBatches | PASS |
| S5 | Completeness | Active-verifier proofs always accepted | PASS |
| S6 | NoGroth16AfterCutover | Groth16 rejected in plonk_only phase | PASS |
| S7 | PhaseConsistency | activeVerifiers matches migrationPhase | PASS |
| S8 | RollbackOnlyOnFailure | Rollback requires failure detection | PASS |
| S9 | NoBatchLossDuringRollback | No batch lost during rollback drain | PASS |

### Reproduction

```bash
cd zkl2/specs/units/2026-03-plonk-migration/1-formalization/v0-analysis/experiments/PlonkMigration/_build
java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_PlonkMigration -workers 4 -deadlock
```

## 6. Scaling Analysis

| Configuration | States Generated | Distinct States | Time | Result |
|--------------|-----------------|----------------|------|--------|
| 2 enterprises, 2 batches, steps=2 | 111,270 | 57,877 | 1s | PASS |
| 3 enterprises, 2 batches, steps=2 | 9,117,756 | 3,985,171 | 37s | PASS |
| 3 enterprises, 4 batches, steps=3 | 183M+ (10 min, incomplete) | -- | -- | Intractable |

The state space grows exponentially with MaxBatches due to queue permutations and
registry cardinality. The 3-enterprise/2-batch configuration provides sufficient
coverage: it exercises all phase transitions, cross-enterprise isolation, mixed-type
queues, and the full rollback path within 37 seconds.

## 7. Open Issues

1. **Liveness properties not model-checked**: `DualPeriodTermination` and
   `BatchEventualVerification` require fairness constraints and are defined as
   temporal properties. TLC can check these but requires `PROPERTY` declarations
   in the .cfg with appropriate fairness. Not blocking for Phase 2 but should be
   verified if liveness guarantees are critical for the implementation.

2. **No re-migration after rollback**: The current spec allows `groth16_only -> dual -> rollback -> groth16_only`, but does not model a second migration attempt after rollback.
   The state machine returns to `groth16_only` and could re-enter `dual`, but
   batchCounter does not reset, limiting the total batches. For the 2-batch model this
   means limited re-migration capacity. Acceptable for specification purposes.

3. **Governance model not specified**: Phase transitions (StartDualVerification,
   CutoverToPlonkOnly, RollbackMigration) are non-deterministic actions. The real
   system requires governance authority (multisig, timelock). This is an implementation
   concern, not a protocol concern.

---

## Next Phase

**Phase 2: Audit** (`/2-audit`) -- Verify that the formalization faithfully represents
the source research materials without hallucination or omission.
