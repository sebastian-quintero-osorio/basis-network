//! Comprehensive test suite for the proof aggregation pipeline.
//!
//! Tests organized by TLA+ safety property and aggregation scenario:
//!   1. Basic aggregation (2, 4, 8 proofs)
//!   2. S1: AggregationSoundness (invalid proof detection)
//!   3. S2: IndependencePreservation (recovery after rejection)
//!   4. S3: OrderIndependence (deterministic results)
//!   5. S4: GasMonotonicity (cost reduction verification)
//!   6. S5: SingleLocation (no double-counting)
//!   7. Pool management (duplicate rejection, sequence validation)
//!   8. Tree structure (topology, depth, pairing)
//!   9. E2E pipeline (generate -> aggregate -> verify -> recover)
//!
//! [Spec: lab/3-architect/implementation-history/prover-aggregation/specs/ProofAggregation.tla]

use std::collections::BTreeSet;

use crate::aggregator::Aggregator;
use crate::tree::ProofTree;
use crate::types::*;
use crate::verifier_circuit::RecursiveVerifier;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Create a test proof entry with given validity.
fn make_proof(enterprise: u64, sequence: u64, valid: bool) -> ProofEntry {
    let eid = EnterpriseId::from_u64(enterprise);
    let pid = ProofId::new(eid, sequence);
    ProofEntry {
        id: pid,
        proof_data: vec![enterprise as u8; 64],
        public_inputs: vec![[sequence as u8; 32]],
        valid,
    }
}

/// Create an aggregator with N enterprises, each having one valid proof submitted.
fn setup_aggregator(n: usize) -> (Aggregator, Vec<ProofId>) {
    let mut agg = Aggregator::new();
    let mut pids = Vec::new();

    for i in 1..=n {
        let pid = agg.generate_valid_proof(EnterpriseId::from_u64(i as u64));
        let entry = make_proof(i as u64, pid.sequence, true);
        agg.submit_proof(entry).unwrap();
        pids.push(pid);
    }

    (agg, pids)
}

// ===========================================================================
// 1. Basic Aggregation
// ===========================================================================

#[test]
fn aggregate_2_proofs() {
    let (mut agg, pids) = setup_aggregator(2);
    let set: BTreeSet<ProofId> = pids.into_iter().collect();

    let agg_id = agg.aggregate(set).unwrap();
    let record = agg.get_aggregation(agg_id).unwrap();

    assert!(record.valid);
    assert_eq!(record.status, AggregationStatus::Aggregated);
    assert_eq!(record.components.len(), 2);
    assert!(record.aggregated_proof.is_some());
    agg.assert_all_invariants().unwrap();
}

#[test]
fn aggregate_4_proofs() {
    let (mut agg, pids) = setup_aggregator(4);
    let set: BTreeSet<ProofId> = pids.into_iter().collect();

    let agg_id = agg.aggregate(set).unwrap();
    let record = agg.get_aggregation(agg_id).unwrap();

    assert!(record.valid);
    assert_eq!(record.components.len(), 4);
    agg.assert_all_invariants().unwrap();
}

#[test]
fn aggregate_8_proofs() {
    let (mut agg, pids) = setup_aggregator(8);
    let set: BTreeSet<ProofId> = pids.into_iter().collect();

    let agg_id = agg.aggregate(set).unwrap();
    let record = agg.get_aggregation(agg_id).unwrap();

    assert!(record.valid);
    assert_eq!(record.components.len(), 8);
    agg.assert_all_invariants().unwrap();
}

#[test]
fn aggregate_insufficient_proofs_rejected() {
    let (mut agg, pids) = setup_aggregator(1);
    let set: BTreeSet<ProofId> = pids.into_iter().collect();

    let err = agg.aggregate(set).unwrap_err();
    assert!(matches!(err, AggregatorError::InsufficientProofs(1)));
}

// ===========================================================================
// 2. S1: AggregationSoundness
// ===========================================================================

#[test]
fn s1_all_valid_proofs_produce_valid_aggregation() {
    let (mut agg, pids) = setup_aggregator(4);
    let set: BTreeSet<ProofId> = pids.into_iter().collect();

    let agg_id = agg.aggregate(set).unwrap();
    let record = agg.get_aggregation(agg_id).unwrap();

    // Forward direction: all valid => aggregation valid
    assert!(record.valid);
    agg.assert_aggregation_soundness().unwrap();
}

#[test]
fn s1_invalid_proof_in_middle_causes_rejection() {
    let mut agg = Aggregator::new();

    // Enterprise 1: valid proof
    let pid1 = agg.generate_valid_proof(EnterpriseId::from_u64(1));
    agg.submit_proof(make_proof(1, 1, true)).unwrap();

    // Enterprise 2: INVALID proof (corrupted witness)
    let pid2 = agg.generate_invalid_proof(EnterpriseId::from_u64(2));
    agg.submit_proof(make_proof(2, 1, false)).unwrap();

    // Enterprise 3: valid proof
    let pid3 = agg.generate_valid_proof(EnterpriseId::from_u64(3));
    agg.submit_proof(make_proof(3, 1, true)).unwrap();

    let set: BTreeSet<ProofId> = [pid1, pid2, pid3].into_iter().collect();
    let agg_id = agg.aggregate(set).unwrap();
    let record = agg.get_aggregation(agg_id).unwrap();

    // Backward direction: aggregation invalid because pid2 is invalid
    assert!(!record.valid);
    agg.assert_aggregation_soundness().unwrap();
}

#[test]
fn s1_single_invalid_in_8_causes_rejection() {
    let mut agg = Aggregator::new();
    let mut pids = Vec::new();

    for i in 1..=8 {
        if i == 5 {
            // Enterprise 5: invalid
            let pid = agg.generate_invalid_proof(EnterpriseId::from_u64(i));
            agg.submit_proof(make_proof(i, 1, false)).unwrap();
            pids.push(pid);
        } else {
            let pid = agg.generate_valid_proof(EnterpriseId::from_u64(i));
            agg.submit_proof(make_proof(i, 1, true)).unwrap();
            pids.push(pid);
        }
    }

    let set: BTreeSet<ProofId> = pids.into_iter().collect();
    let agg_id = agg.aggregate(set).unwrap();
    let record = agg.get_aggregation(agg_id).unwrap();

    assert!(!record.valid, "single invalid proof must invalidate entire aggregation");
    agg.assert_aggregation_soundness().unwrap();
}

// ===========================================================================
// 3. S2: IndependencePreservation
// ===========================================================================

#[test]
fn s2_valid_proofs_recovered_after_rejection() {
    let mut agg = Aggregator::new();

    // Enterprise 1: valid
    let pid1 = agg.generate_valid_proof(EnterpriseId::from_u64(1));
    agg.submit_proof(make_proof(1, 1, true)).unwrap();

    // Enterprise 2: invalid
    let pid2 = agg.generate_invalid_proof(EnterpriseId::from_u64(2));
    agg.submit_proof(make_proof(2, 1, false)).unwrap();

    // Aggregate both
    let set: BTreeSet<ProofId> = [pid1, pid2].into_iter().collect();
    let agg_id = agg.aggregate(set).unwrap();

    // Verify on L1 (will reject due to invalid pid2)
    agg.mark_l1_verified(agg_id).unwrap();
    let record = agg.get_aggregation(agg_id).unwrap();
    assert_eq!(record.status, AggregationStatus::L1Rejected);

    // Recover: return proofs to pool
    agg.recover(agg_id).unwrap();

    // pid1 (valid) should be back in the pool
    assert!(agg.pool().contains(&pid1), "valid proof must be recovered to pool");
    // pid2 (invalid) should also be back (for potential re-inspection)
    assert!(agg.pool().contains(&pid2));

    agg.assert_independence_preservation().unwrap();
}

#[test]
fn s2_recovered_proofs_can_be_reaggregated() {
    let mut agg = Aggregator::new();

    let pid1 = agg.generate_valid_proof(EnterpriseId::from_u64(1));
    agg.submit_proof(make_proof(1, 1, true)).unwrap();

    let pid2 = agg.generate_invalid_proof(EnterpriseId::from_u64(2));
    agg.submit_proof(make_proof(2, 1, false)).unwrap();

    let pid3 = agg.generate_valid_proof(EnterpriseId::from_u64(3));
    agg.submit_proof(make_proof(3, 1, true)).unwrap();

    // First aggregation (includes invalid pid2)
    let set1: BTreeSet<ProofId> = [pid1, pid2, pid3].into_iter().collect();
    let agg_id1 = agg.aggregate(set1).unwrap();
    agg.mark_l1_verified(agg_id1).unwrap();
    assert_eq!(
        agg.get_aggregation(agg_id1).unwrap().status,
        AggregationStatus::L1Rejected
    );

    // Recover
    agg.recover(agg_id1).unwrap();

    // Re-aggregate without the invalid proof
    let set2: BTreeSet<ProofId> = [pid1, pid3].into_iter().collect();
    let agg_id2 = agg.aggregate(set2).unwrap();
    let record = agg.get_aggregation(agg_id2).unwrap();

    assert!(record.valid, "re-aggregation without invalid proof should be valid");
    agg.assert_all_invariants().unwrap();
}

// ===========================================================================
// 4. S3: OrderIndependence
// ===========================================================================

#[test]
fn s3_same_components_same_validity() {
    // Create two separate aggregators with same proofs in different order
    let mut agg1 = Aggregator::new();
    let mut agg2 = Aggregator::new();

    // Setup identical state in both
    for agg in [&mut agg1, &mut agg2] {
        for i in 1..=4 {
            agg.generate_valid_proof(EnterpriseId::from_u64(i));
            agg.submit_proof(make_proof(i, 1, true)).unwrap();
        }
    }

    // Same set of IDs (BTreeSet ensures canonical order)
    let set: BTreeSet<ProofId> = (1..=4)
        .map(|i| ProofId::new(EnterpriseId::from_u64(i), 1))
        .collect();

    let id1 = agg1.aggregate(set.clone()).unwrap();
    let id2 = agg2.aggregate(set).unwrap();

    let r1 = agg1.get_aggregation(id1).unwrap();
    let r2 = agg2.get_aggregation(id2).unwrap();

    assert_eq!(r1.valid, r2.valid);
    assert_eq!(r1.components, r2.components);
}

// ===========================================================================
// 5. S4: GasMonotonicity
// ===========================================================================

#[test]
fn s4_gas_decreases_with_n() {
    for n in 2..=16 {
        let (individual, aggregated, factor) = Aggregator::gas_savings(n);
        assert!(
            aggregated < individual,
            "N={}: aggregated {}K must be < individual {}K",
            n,
            aggregated / 1000,
            individual / 1000
        );
        assert!(factor > 1.0, "N={}: savings factor {} must be > 1.0", n, factor);
    }
}

#[test]
fn s4_gas_savings_match_research() {
    // Verify against findings.md Section 3.2
    let (_, _, f2) = Aggregator::gas_savings(2);
    let (_, _, f4) = Aggregator::gas_savings(4);
    let (_, _, f8) = Aggregator::gas_savings(8);
    let (_, _, f16) = Aggregator::gas_savings(16);

    // 3.8x, 7.6x, 15.3x, 30.5x (approximately)
    assert!((f2 - 3.8).abs() < 0.2, "N=2: expected ~3.8x, got {:.1}x", f2);
    assert!((f4 - 7.6).abs() < 0.2, "N=4: expected ~7.6x, got {:.1}x", f4);
    assert!((f8 - 15.3).abs() < 0.5, "N=8: expected ~15.3x, got {:.1}x", f8);
    assert!((f16 - 30.5).abs() < 1.0, "N=16: expected ~30.5x, got {:.1}x", f16);
}

#[test]
fn s4_invariant_holds_after_aggregation() {
    let (mut agg, pids) = setup_aggregator(8);
    let set: BTreeSet<ProofId> = pids.into_iter().collect();
    agg.aggregate(set).unwrap();

    agg.assert_gas_monotonicity().unwrap();
}

// ===========================================================================
// 6. S5: SingleLocation
// ===========================================================================

#[test]
fn s5_proof_not_in_pool_and_aggregation() {
    let (mut agg, pids) = setup_aggregator(4);
    let set: BTreeSet<ProofId> = pids.iter().copied().collect();

    agg.aggregate(set).unwrap();

    // Proofs should not be in pool anymore
    for pid in &pids {
        assert!(
            !agg.pool().contains(pid),
            "proof {:?} should not be in pool after aggregation",
            pid
        );
    }

    agg.assert_single_location().unwrap();
}

#[test]
fn s5_recovered_proofs_only_in_pool() {
    let mut agg = Aggregator::new();

    let pid1 = agg.generate_valid_proof(EnterpriseId::from_u64(1));
    agg.submit_proof(make_proof(1, 1, true)).unwrap();
    let pid2 = agg.generate_invalid_proof(EnterpriseId::from_u64(2));
    agg.submit_proof(make_proof(2, 1, false)).unwrap();

    let set: BTreeSet<ProofId> = [pid1, pid2].into_iter().collect();
    let agg_id = agg.aggregate(set).unwrap();
    agg.mark_l1_verified(agg_id).unwrap();
    agg.recover(agg_id).unwrap();

    // After recovery, proofs should only be in pool, not in any aggregation
    assert!(agg.pool().contains(&pid1));
    assert!(agg.pool().contains(&pid2));
    assert_eq!(agg.aggregation_count(), 0);

    agg.assert_single_location().unwrap();
}

// ===========================================================================
// 7. Pool Management
// ===========================================================================

#[test]
fn pool_duplicate_rejection() {
    let mut agg = Aggregator::new();
    let eid = EnterpriseId::from_u64(1);

    agg.generate_valid_proof(eid);
    agg.submit_proof(make_proof(1, 1, true)).unwrap();

    // Attempt duplicate submission
    let err = agg.submit_proof(make_proof(1, 1, true)).unwrap_err();
    assert!(matches!(err, AggregatorError::DuplicateProof(_)));
}

#[test]
fn pool_sequence_validation() {
    let mut agg = Aggregator::new();
    let eid = EnterpriseId::from_u64(1);

    // Attempt to submit proof without generating first
    let entry = make_proof(1, 1, true);
    let err = agg.submit_proof(entry).unwrap_err();
    assert!(matches!(err, AggregatorError::SequenceExceedsCounter { .. }));

    // Generate and then submit works
    agg.generate_valid_proof(eid);
    agg.submit_proof(make_proof(1, 1, true)).unwrap();
}

#[test]
fn pool_multiple_proofs_per_enterprise() {
    let mut agg = Aggregator::new();
    let eid = EnterpriseId::from_u64(1);

    // Generate and submit 3 proofs from same enterprise
    for _ in 0..3 {
        agg.generate_valid_proof(eid);
    }

    agg.submit_proof(make_proof(1, 1, true)).unwrap();
    agg.submit_proof(make_proof(1, 2, true)).unwrap();
    agg.submit_proof(make_proof(1, 3, true)).unwrap();

    assert_eq!(agg.pool_size(), 3);
}

// ===========================================================================
// 8. Tree Structure
// ===========================================================================

#[test]
fn tree_2_leaves() {
    let pids: BTreeSet<ProofId> = (1..=2)
        .map(|i| ProofId::new(EnterpriseId::from_u64(i), 1))
        .collect();

    let tree = ProofTree::from_proofs(&pids, &|_| true);

    assert_eq!(tree.num_leaves(), 2);
    assert_eq!(tree.depth(), 1);
    assert!(tree.is_valid());
}

#[test]
fn tree_8_leaves_depth_3() {
    let pids: BTreeSet<ProofId> = (1..=8)
        .map(|i| ProofId::new(EnterpriseId::from_u64(i), 1))
        .collect();

    let tree = ProofTree::from_proofs(&pids, &|_| true);

    assert_eq!(tree.num_leaves(), 8);
    assert_eq!(tree.depth(), 3); // log2(8) = 3
    assert!(tree.is_valid());
}

#[test]
fn tree_odd_count_promotes_unpaired() {
    let pids: BTreeSet<ProofId> = (1..=5)
        .map(|i| ProofId::new(EnterpriseId::from_u64(i), 1))
        .collect();

    let tree = ProofTree::from_proofs(&pids, &|_| true);

    assert_eq!(tree.num_leaves(), 5);
    assert!(tree.is_valid());
}

#[test]
fn tree_invalid_leaf_propagates() {
    let invalid_pid = ProofId::new(EnterpriseId::from_u64(3), 1);
    let pids: BTreeSet<ProofId> = (1..=4)
        .map(|i| ProofId::new(EnterpriseId::from_u64(i), 1))
        .collect();

    let tree = ProofTree::from_proofs(&pids, &|pid| *pid != invalid_pid);

    assert!(!tree.is_valid(), "tree with one invalid leaf must be invalid at root");
}

// ===========================================================================
// 9. Verifier Circuit
// ===========================================================================

#[test]
fn verifier_fold_pair_both_valid() {
    let rv = RecursiveVerifier::default();

    let e1 = make_proof(1, 1, true);
    let e2 = make_proof(2, 1, true);

    let i1 = rv.proof_to_instance(&e1);
    let i2 = rv.proof_to_instance(&e2);

    let folded = rv.fold_pair(&i1, &i2).unwrap();
    assert!(folded.satisfiable);
    assert_eq!(folded.num_components, 2);
}

#[test]
fn verifier_fold_pair_one_invalid() {
    let rv = RecursiveVerifier::default();

    let e1 = make_proof(1, 1, true);
    let e2 = make_proof(2, 1, false);

    let i1 = rv.proof_to_instance(&e1);
    let i2 = rv.proof_to_instance(&e2);

    let folded = rv.fold_pair(&i1, &i2).unwrap();
    assert!(!folded.satisfiable);
}

#[test]
fn verifier_fold_commutative() {
    let rv = RecursiveVerifier::default();

    let e1 = make_proof(1, 1, true);
    let e2 = make_proof(2, 1, true);

    let i1 = rv.proof_to_instance(&e1);
    let i2 = rv.proof_to_instance(&e2);

    let f_ab = rv.fold_pair(&i1, &i2).unwrap();
    let f_ba = rv.fold_pair(&i2, &i1).unwrap();

    // Commutativity: fold(a, b) == fold(b, a)
    assert_eq!(f_ab.satisfiable, f_ba.satisfiable);
    assert_eq!(f_ab.state, f_ba.state, "folding must be commutative");
}

#[test]
fn verifier_decider_valid() {
    let rv = RecursiveVerifier::default();
    let entries: Vec<ProofEntry> = (1..=4).map(|i| make_proof(i, 1, true)).collect();

    let folded = rv.fold_all(&entries).unwrap();
    let decider = rv.decide(&folded).unwrap();

    assert!(decider.valid);
    assert_eq!(decider.proof_bytes.len(), 128);
}

#[test]
fn verifier_decider_invalid() {
    let rv = RecursiveVerifier::default();
    let entries = vec![make_proof(1, 1, true), make_proof(2, 1, false)];

    let folded = rv.fold_all(&entries).unwrap();
    let decider = rv.decide(&folded).unwrap();

    assert!(!decider.valid);
}

// ===========================================================================
// 10. E2E Pipeline
// ===========================================================================

#[test]
fn e2e_generate_aggregate_verify() {
    let mut agg = Aggregator::new();

    // Generate proofs from 4 enterprises
    for i in 1..=4 {
        agg.generate_valid_proof(EnterpriseId::from_u64(i));
        agg.submit_proof(make_proof(i, 1, true)).unwrap();
    }

    // Aggregate
    let set: BTreeSet<ProofId> = (1..=4)
        .map(|i| ProofId::new(EnterpriseId::from_u64(i), 1))
        .collect();
    let agg_id = agg.aggregate(set).unwrap();

    // Verify on L1
    agg.mark_l1_verified(agg_id).unwrap();

    let record = agg.get_aggregation(agg_id).unwrap();
    assert_eq!(record.status, AggregationStatus::L1Verified);
    assert!(record.valid);

    agg.assert_all_invariants().unwrap();
}

#[test]
fn e2e_generate_aggregate_reject_recover_reaggregate() {
    let mut agg = Aggregator::new();

    // Enterprise 1-3: valid, Enterprise 4: invalid
    for i in 1..=3 {
        agg.generate_valid_proof(EnterpriseId::from_u64(i));
        agg.submit_proof(make_proof(i, 1, true)).unwrap();
    }
    agg.generate_invalid_proof(EnterpriseId::from_u64(4));
    agg.submit_proof(make_proof(4, 1, false)).unwrap();

    // First aggregation (includes invalid)
    let set1: BTreeSet<ProofId> = (1..=4)
        .map(|i| ProofId::new(EnterpriseId::from_u64(i), 1))
        .collect();
    let agg_id1 = agg.aggregate(set1).unwrap();

    // L1 rejects (because enterprise 4's proof is invalid)
    agg.mark_l1_verified(agg_id1).unwrap();
    assert_eq!(
        agg.get_aggregation(agg_id1).unwrap().status,
        AggregationStatus::L1Rejected
    );

    // Recover proofs
    agg.recover(agg_id1).unwrap();
    assert_eq!(agg.pool_size(), 4);

    // Re-aggregate without the invalid proof
    let set2: BTreeSet<ProofId> = (1..=3)
        .map(|i| ProofId::new(EnterpriseId::from_u64(i), 1))
        .collect();
    let agg_id2 = agg.aggregate(set2).unwrap();

    // L1 verifies successfully
    agg.mark_l1_verified(agg_id2).unwrap();
    assert_eq!(
        agg.get_aggregation(agg_id2).unwrap().status,
        AggregationStatus::L1Verified
    );
    assert!(agg.get_aggregation(agg_id2).unwrap().valid);

    agg.assert_all_invariants().unwrap();
}

#[test]
fn e2e_partial_aggregation() {
    let (mut agg, pids) = setup_aggregator(8);

    // Aggregate only first 4 of 8
    let subset: BTreeSet<ProofId> = pids[..4].iter().copied().collect();
    let agg_id = agg.aggregate(subset).unwrap();

    // Remaining 4 should still be in pool
    assert_eq!(agg.pool_size(), 4);
    for pid in &pids[4..] {
        assert!(agg.pool().contains(pid));
    }

    let record = agg.get_aggregation(agg_id).unwrap();
    assert!(record.valid);
    assert_eq!(record.components.len(), 4);

    agg.assert_all_invariants().unwrap();
}

#[test]
fn e2e_multiple_aggregations() {
    let (mut agg, pids) = setup_aggregator(8);

    // Aggregate in two groups of 4
    let set1: BTreeSet<ProofId> = pids[..4].iter().copied().collect();
    let set2: BTreeSet<ProofId> = pids[4..].iter().copied().collect();

    let id1 = agg.aggregate(set1).unwrap();
    let id2 = agg.aggregate(set2).unwrap();

    assert!(agg.get_aggregation(id1).unwrap().valid);
    assert!(agg.get_aggregation(id2).unwrap().valid);
    assert_eq!(agg.aggregation_count(), 2);
    assert_eq!(agg.pool_size(), 0);

    agg.assert_all_invariants().unwrap();
}

// ===========================================================================
// 11. Error cases
// ===========================================================================

#[test]
fn error_aggregate_proof_not_in_pool() {
    let mut agg = Aggregator::new();

    let pid1 = agg.generate_valid_proof(EnterpriseId::from_u64(1));
    agg.submit_proof(make_proof(1, 1, true)).unwrap();

    // Try to aggregate with a non-existent proof
    let fake_pid = ProofId::new(EnterpriseId::from_u64(99), 1);
    let set: BTreeSet<ProofId> = [pid1, fake_pid].into_iter().collect();

    let err = agg.aggregate(set).unwrap_err();
    assert!(matches!(err, AggregatorError::ProofNotInPool(_)));
}

#[test]
fn error_verify_non_aggregated() {
    let (mut agg, pids) = setup_aggregator(2);
    let set: BTreeSet<ProofId> = pids.into_iter().collect();
    let agg_id = agg.aggregate(set).unwrap();

    // Verify once
    agg.mark_l1_verified(agg_id).unwrap();

    // Try to verify again
    let err = agg.mark_l1_verified(agg_id).unwrap_err();
    assert!(matches!(
        err,
        AggregatorError::InvalidAggregationStatus(_, _, _)
    ));
}

#[test]
fn error_recover_non_rejected() {
    let (mut agg, pids) = setup_aggregator(2);
    let set: BTreeSet<ProofId> = pids.into_iter().collect();
    let agg_id = agg.aggregate(set).unwrap();

    // Try to recover before rejection
    let err = agg.recover(agg_id).unwrap_err();
    assert!(matches!(
        err,
        AggregatorError::InvalidAggregationStatus(_, _, _)
    ));
}
