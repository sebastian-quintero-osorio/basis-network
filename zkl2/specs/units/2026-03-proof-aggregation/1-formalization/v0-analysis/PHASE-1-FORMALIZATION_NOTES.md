# Phase 1: Formalization Notes -- Proof Aggregation (RU-L10)

> Unit: `zkl2/specs/units/2026-03-proof-aggregation/`
> Date: 2026-03-19
> Result: **PASS** -- All 6 invariants verified across 209,517 distinct states.

---

## 1. Research-to-Specification Mapping

| Research Concept | Source | TLA+ Element | Notes |
|------------------|--------|-------------|-------|
| Enterprise halo2-KZG proof generation | REPORT.md S3.4 | `GenerateValidProof(e)` | Per-enterprise, independent prover |
| Invalid/adversarial proof | REPORT.md S9 | `GenerateInvalidProof(e)` | Corrupted witness, wrong circuit |
| Proof submission to aggregator | REPORT.md S5 (NonInteraction) | `SubmitToPool(e, n)` | Guards enforce duplicate rejection |
| ProtoGalaxy folding | REPORT.md S3.4 | `AggregateSubset(S)` | Set-based (order-independent by construction) |
| Groth16 decider L1 verification | REPORT.md S3.4, S6.2 | `VerifyOnL1(agg)` | Deterministic: accepts valid, rejects invalid |
| Failure recovery | REPORT.md S5 (INV-AGG-2) | `RecoverFromRejection(agg)` | Returns proofs to pool after rejection |
| AggregationSoundness (INV-AGG-1) | REPORT.md S5, S8 | `AggregationSoundness` invariant | Biconditional: valid <=> all components valid |
| IndependencePreservation (INV-AGG-2) | REPORT.md S5, S8 | `IndependencePreservation` invariant | Valid proofs always accessible after submission |
| OrderIndependence (INV-AGG-3) | REPORT.md S5, S8 | `OrderIndependence` invariant | Same components => same validity |
| GasMonotonicity (INV-AGG-4) | REPORT.md S3.2, S8 | `GasMonotonicity` invariant | AggGas < BaseGas * N for N >= 2 |

## 2. State Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `proofCounter` | `[Enterprises -> 0..MaxProofsPerEnt]` | Tracks proofs generated per enterprise |
| `proofValidity` | `SUBSET ProofIds` | Intrinsic cryptographic validity (immutable once set) |
| `aggregationPool` | `SUBSET ProofIds` | Proofs available for aggregation |
| `everSubmitted` | `SUBSET ProofIds` | Monotonic tracking for IndependencePreservation |
| `aggregations` | `Set(AggRecord)` | Aggregation lifecycle records |

## 3. Actions

| Action | Guard | Effect |
|--------|-------|--------|
| `GenerateValidProof(e)` | `proofCounter[e] < Max` | Increments counter, adds to proofValidity |
| `GenerateInvalidProof(e)` | `proofCounter[e] < Max` | Increments counter only (NOT added to proofValidity) |
| `SubmitToPool(e, n)` | Generated, not in pool, not in any aggregation | Adds to pool and everSubmitted |
| `AggregateSubset(S)` | `S \subseteq pool`, `|S| >= 2` | Creates aggregation record, removes from pool |
| `VerifyOnL1(agg)` | `agg.status = "aggregated"` | Transitions to l1_verified or l1_rejected |
| `RecoverFromRejection(agg)` | `agg.status = "l1_rejected"` | Returns proofs to pool, removes aggregation |

## 4. Assumptions Made During Formalization

1. **Proof validity is immutable**: Once generated as valid or invalid, the cryptographic
   status never changes. This models the information-theoretic property that proof validity
   is intrinsic to the witness and circuit, not affected by external state.

2. **Aggregation is set-based**: ProtoGalaxy folding commutativity and associativity are
   modeled by operating on sets rather than sequences. The Folding Commutativity axiom
   justifies this abstraction.

3. **L1 verification is deterministic**: The BasisRollup.sol verifier accepts valid
   aggregated proofs and rejects invalid ones with certainty. No probabilistic
   verification or partial acceptance.

4. **Fixed gas cost model**: AggregatedGasCost is constant regardless of the number of
   component proofs. This follows from the Groth16 decider architecture where the L1
   verifier checks a single Groth16 proof (fixed cost) regardless of how many enterprise
   proofs were folded into it.

5. **Duplicate rejection is structural**: The SubmitToPool guard prevents duplicate
   submission by checking pool membership. No separate duplicate detection mechanism
   is needed.

6. **Recovery returns all proofs**: RecoverFromRejection returns ALL component proofs
   (valid and invalid) to the pool. The protocol does not pre-screen during recovery;
   invalid proofs in the pool will cause future aggregations to fail unless excluded.

## 5. Verification Results

### Configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Enterprises | `{"e1", "e2", "e3"}` | Multi-enterprise isolation and partial aggregation |
| MaxProofsPerEnt | `2` | One valid + one invalid per enterprise |
| BaseGasPerProof | `420000` | halo2-KZG individual verification cost |
| AggregatedGasCost | `220000` | Groth16 decider cost after ProtoGalaxy folding |

### Results

| Metric | Value |
|--------|-------|
| States generated | 788,734 |
| Distinct states | 209,517 |
| State graph depth | 19 |
| Max outdegree | 31 |
| Workers | 4 |
| Time | 4 seconds |
| Fingerprint collision probability | < 2.2E-8 |
| **Verdict** | **ALL INVARIANTS PASS** |

### Invariants Verified

| # | Invariant | Status | Semantics |
|---|-----------|--------|-----------|
| S1 | `TypeOK` | PASS | Type consistency across all variables |
| S2 | `AggregationSoundness` | PASS | `agg.valid <=> all components in proofValidity` |
| S3 | `IndependencePreservation` | PASS | Valid submitted proofs always accessible |
| S4 | `OrderIndependence` | PASS | Same components => same validity verdict |
| S5 | `GasMonotonicity` | PASS | `220K < 420K * N` for all N >= 2 |
| S6 | `SingleLocation` | PASS | Each proof in at most one location |

### Scenarios Covered by Exhaustive Search

| Scenario | How Modeled | Covered |
|----------|-------------|---------|
| Invalid proof at position 2 | `GenerateInvalidProof(e)` for any enterprise | Yes |
| Duplicate submission attempt | `SubmitToPool` guard blocks when `pid \in pool` | Yes |
| Partial aggregation (2 of 3) | `AggregateSubset(S)` with `|S| = 2` | Yes |
| L1 verification of aggregated proof | `VerifyOnL1(agg)` | Yes |
| Recovery after rejection | `RecoverFromRejection(agg)` | Yes |
| Mixed valid/invalid aggregation | Valid + invalid proofs in same subset | Yes |

### Reproduction Instructions

```bash
cd zkl2/specs/units/2026-03-proof-aggregation/1-formalization/v0-analysis/experiments/ProofAggregation/_build
java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_ProofAggregation -workers 4 -deadlock
```

## 6. Open Issues

1. **Deadlock in terminal states**: When all proofs are generated and some remain in the
   pool with `|pool| < 2`, no further actions are enabled. This is a natural protocol
   termination, not a bug. The `-deadlock` flag disables this check. A production
   implementation would handle this by waiting for more proofs or performing individual
   verification for orphaned proofs.

2. **Unbounded recovery cycles**: If invalid proofs are returned to the pool during
   recovery, they can cause repeated aggregation failures. The model terminates because
   TLC detects the state cycle. A production implementation should track and exclude
   known-invalid proofs after rejection.

3. **Gas model simplification**: GasMonotonicity verifies the parameter relationship
   (`AggGas < BaseGas * N`) but does not model actual gas metering on-chain. The
   property is verified to hold for the specific parameters (220K vs 420K) across
   all reachable aggregation sizes (N=2 through N=6).

## 7. Conclusion

The ProtoGalaxy folding + Groth16 decider architecture for proof aggregation has been
formally verified against 6 safety invariants across 209,517 distinct states. The
specification faithfully models the protocol described in the Scientist's research
(RU-L10), including adversarial scenarios (invalid proofs, duplicate submissions,
partial aggregation). All invariants pass without counterexamples.

The specification is ready for Phase 2 audit (integrity verification against source
materials) and subsequent downstream consumption by the Architect and Prover agents.
