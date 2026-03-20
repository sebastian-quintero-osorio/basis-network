# Adversarial Report: Proof Aggregation (RU-L10)

> Target: zkl2 | Unit: 2026-03-proof-aggregation | Date: 2026-03-19

---

## 1. Summary

Adversarial testing of the proof aggregation pipeline covering both the Rust
aggregation library (`basis-aggregator`) and the on-chain verification contract
(`BasisAggregator.sol`). Testing focused on violating the 5 TLA+ safety properties
and exploiting the aggregation lifecycle.

**Verdict: NO VIOLATIONS FOUND**

All 34 Rust tests and 27 Solidity tests pass. All 5 TLA+ safety properties hold
under adversarial conditions.

---

## 2. Attack Catalog

### 2.1 Rust Aggregation Pipeline (34 tests)

| # | Attack Vector | Target Property | Result | Test |
|---|--------------|----------------|--------|------|
| 1 | Aggregate 2 valid proofs | Baseline | PASS | `aggregate_2_proofs` |
| 2 | Aggregate 4 valid proofs | Baseline | PASS | `aggregate_4_proofs` |
| 3 | Aggregate 8 valid proofs | Baseline | PASS | `aggregate_8_proofs` |
| 4 | Aggregate single proof | S4 boundary | REJECTED (correct) | `aggregate_insufficient_proofs_rejected` |
| 5 | All valid proofs produce valid aggregation | S1 forward | PASS | `s1_all_valid_proofs_produce_valid_aggregation` |
| 6 | Invalid proof in middle position (pos 2/3) | S1 backward | DETECTED | `s1_invalid_proof_in_middle_causes_rejection` |
| 7 | Single invalid in 8 proofs (pos 5/8) | S1 backward | DETECTED | `s1_single_invalid_in_8_causes_rejection` |
| 8 | Recover valid proofs after rejection | S2 | PRESERVED | `s2_valid_proofs_recovered_after_rejection` |
| 9 | Re-aggregate recovered proofs without invalid | S2 | PASS | `s2_recovered_proofs_can_be_reaggregated` |
| 10 | Same components produce same validity | S3 | DETERMINISTIC | `s3_same_components_same_validity` |
| 11 | Gas decreases with N for N=2..16 | S4 | MONOTONIC | `s4_gas_decreases_with_n` |
| 12 | Gas savings match research (3.8x/7.6x/15.3x/30.5x) | S4 | CONFIRMED | `s4_gas_savings_match_research` |
| 13 | Gas invariant holds after aggregation | S4 | PASS | `s4_invariant_holds_after_aggregation` |
| 14 | Proof not in pool and aggregation simultaneously | S5 | ENFORCED | `s5_proof_not_in_pool_and_aggregation` |
| 15 | Recovered proofs only in pool | S5 | ENFORCED | `s5_recovered_proofs_only_in_pool` |
| 16 | Duplicate proof submission | Pool guard | REJECTED | `pool_duplicate_rejection` |
| 17 | Submit proof before generation | Pool guard | REJECTED | `pool_sequence_validation` |
| 18 | Multiple proofs per enterprise | Pool | PASS | `pool_multiple_proofs_per_enterprise` |
| 19 | Binary tree with 2 leaves | Tree | CORRECT | `tree_2_leaves` |
| 20 | Binary tree with 8 leaves (depth=3) | Tree | CORRECT | `tree_8_leaves_depth_3` |
| 21 | Odd-count tree (5 leaves) | Tree | CORRECT | `tree_odd_count_promotes_unpaired` |
| 22 | Invalid leaf propagates to root | Tree S1 | PROPAGATED | `tree_invalid_leaf_propagates` |
| 23 | Fold pair both valid | Verifier | VALID | `verifier_fold_pair_both_valid` |
| 24 | Fold pair one invalid | Verifier | INVALID | `verifier_fold_pair_one_invalid` |
| 25 | Fold commutativity | Verifier S3 | COMMUTATIVE | `verifier_fold_commutative` |
| 26 | Decider valid proof | Verifier | 128 bytes | `verifier_decider_valid` |
| 27 | Decider invalid proof | Verifier | INVALID | `verifier_decider_invalid` |
| 28 | E2E: generate -> aggregate -> verify | Pipeline | PASS | `e2e_generate_aggregate_verify` |
| 29 | E2E: generate -> aggregate -> reject -> recover -> re-aggregate | Pipeline | PASS | `e2e_generate_aggregate_reject_recover_reaggregate` |
| 30 | Partial aggregation (4 of 8) | Pipeline | PASS | `e2e_partial_aggregation` |
| 31 | Multiple independent aggregations | Pipeline | PASS | `e2e_multiple_aggregations` |
| 32 | Aggregate with non-existent proof | Error | REJECTED | `error_aggregate_proof_not_in_pool` |
| 33 | Double-verify same aggregation | Error | REJECTED | `error_verify_non_aggregated` |
| 34 | Recover non-rejected aggregation | Error | REJECTED | `error_recover_non_rejected` |

### 2.2 Solidity Contract (27 tests)

| # | Attack Vector | Target Property | Result | Test |
|---|--------------|----------------|--------|------|
| 1 | Valid 2-enterprise aggregated proof | S1 | VERIFIED | `S1: should accept valid aggregated proof for 2 enterprises` |
| 2 | Valid 4-enterprise aggregated proof | S1 | VERIFIED | `S1: should accept valid aggregated proof for 4 enterprises` |
| 3 | Invalid aggregated proof | S1 | REJECTED | `S1: should reject invalid aggregated proof` |
| 4 | Unsorted enterprise addresses | S3 | REJECTED | `S3: should reject unsorted enterprise addresses` |
| 5 | Duplicate enterprise addresses | S3 | REJECTED | `S3: should reject duplicate enterprise addresses` |
| 6 | Canonically sorted enterprises | S3 | PASS | `S3: should produce same result for canonically sorted enterprises` |
| 7 | Gas N=2 (110K per enterprise) | S4 | CORRECT | `S4: should report correct gas per enterprise for N=2` |
| 8 | Gas N=4 (55K per enterprise) | S4 | CORRECT | `S4: should report correct gas per enterprise for N=4` |
| 9 | Gas N=8 (27.5K per enterprise) | S4 | CORRECT | `S4: should report correct gas per enterprise for N=8` |
| 10 | Monotonic gas decrease N=2..16 | S4 | MONOTONIC | `S4: should show monotonically decreasing cost` |
| 11 | Per-enterprise gas tracking | Accounting | CORRECT | `Gas: should track per-enterprise gas on successful verification` |
| 12 | No gas charge on rejection | Accounting | CORRECT | `Gas: should not charge gas on rejected verification` |
| 13 | Cumulative gas accounting | Accounting | CORRECT | `Gas: should accumulate gas across multiple aggregations` |
| 14 | Global counter increment | Accounting | CORRECT | `Gas: should increment global counters on verified aggregation` |
| 15 | < MIN_AGGREGATION_SIZE enterprises | Validation | REJECTED | `Input: should reject less than MIN_AGGREGATION_SIZE enterprises` |
| 16 | Mismatched array lengths | Validation | REJECTED | `Input: should reject mismatched enterprise/batch arrays` |
| 17 | Missing verifying key | Validation | REJECTED | `Input: should reject when verifying key not set` |
| 18 | AggregationSubmitted event | Events | EMITTED | `Events: should emit AggregationSubmitted and AggregationVerified` |
| 19 | EnterpriseProofVerified event | Events | EMITTED | `Events: should emit EnterpriseProofVerified for each enterprise` |
| 20 | Component enterprises stored | Data | CORRECT | `Component: should store and return component enterprises` |
| 21 | Component batch hashes stored | Data | CORRECT | `Component: should store and return component batch hashes` |
| 22 | Admin-only setDeciderKey | Access | ENFORCED | `Access: should allow only admin to set decider key` |
| 23 | Double key set prevention | Access | REJECTED | `Access: should prevent setting decider key twice` |
| 24 | Initialization admin | Init | CORRECT | `Init: should set admin correctly` |
| 25 | Initialization zeroes | Init | CORRECT | `Init: should start with zero aggregations` |
| 26 | Gas constants correct | Init | CORRECT | `Init: should have correct gas constants` |
| 27 | Sequential aggregation IDs | Lifecycle | CORRECT | `ID: should assign sequential aggregation IDs` |

---

## 3. Findings

### 3.1 CRITICAL

None.

### 3.2 MODERATE

None.

### 3.3 LOW

None.

### 3.4 INFO

**INFO-1**: The recursive verifier circuit is currently a simulation layer that models
ProtoGalaxy folding faithfully (Aggregation Soundness and Folding Commutativity axioms)
but does not perform actual cryptographic folding. Production deployment requires
integration with Sonobe or equivalent ProtoGalaxy + CycleFold library.

**INFO-2**: The Groth16 decider produces deterministic 128-byte mock proofs. Production
deployment requires a one-time trusted setup ceremony for the decider circuit.

---

## 4. Pipeline Feedback

| Finding | Route | Action |
|---------|-------|--------|
| ProtoGalaxy simulation vs production | Phase 3 (Architect) | Integrate Sonobe when stable |
| Groth16 decider trusted setup | Phase 1 (Scientist) | Evaluate ceremony logistics |

No findings require spec refinement (Phase 2) or new research threads.

---

## 5. Test Inventory

| Suite | Tests | Pass | Fail |
|-------|-------|------|------|
| Rust: basis-aggregator | 34 | 34 | 0 |
| Solidity: BasisAggregator | 27 | 27 | 0 |
| **Total** | **61** | **61** | **0** |

---

## 6. Verdict

**NO VIOLATIONS FOUND**

All 5 TLA+ safety properties (S1-S5) hold under adversarial conditions across
both the Rust implementation and Solidity contract. The aggregation pipeline
correctly rejects invalid proofs, preserves valid proof independence, enforces
single-location constraints, and provides gas savings matching research predictions.
