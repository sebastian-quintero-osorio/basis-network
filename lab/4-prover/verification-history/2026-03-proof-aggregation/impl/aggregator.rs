/// Main proof aggregation pipeline.
///
/// Orchestrates the complete aggregation lifecycle:
///   1. Proof generation tracking (GenerateValidProof / GenerateInvalidProof)
///   2. Pool submission (SubmitToPool)
///   3. Set-based aggregation via ProtoGalaxy folding (AggregateSubset)
///   4. L1 verification status (VerifyOnL1)
///   5. Recovery from rejection (RecoverFromRejection)
///
/// Enforces all 5 TLA+ safety properties as runtime assertions:
///   S1 AggregationSoundness:     agg.valid == (components subset of proofValidity)
///   S2 IndependencePreservation: valid submitted proofs always accessible
///   S3 OrderIndependence:        same components => same validity
///   S4 GasMonotonicity:          AggregatedGasCost < BaseGasPerProof * N for N >= 2
///   S5 SingleLocation:           each proof in at most one location
///
/// [Spec: lab/3-architect/implementation-history/prover-aggregation/specs/ProofAggregation.tla]

use std::collections::BTreeSet;

use crate::pool::ProofPool;
use crate::types::{
    AggregationId, AggregationRecord, AggregationStatus, AggregatorError, AggregatorResult,
    EnterpriseId, ProofEntry, ProofId, AGGREGATED_GAS_COST, BASE_GAS_PER_PROOF,
    MIN_AGGREGATION_SIZE,
};
use crate::verifier_circuit::RecursiveVerifier;

// ---------------------------------------------------------------------------
// Aggregator
// ---------------------------------------------------------------------------

/// The proof aggregation pipeline.
///
/// Manages the complete lifecycle of proof generation, pooling, aggregation,
/// L1 verification, and recovery. All state transitions correspond to TLA+
/// actions; all safety properties are enforced as runtime assertions.
pub struct Aggregator {
    /// Proof pool (TLA+ aggregationPool + everSubmitted + proofCounter).
    pool: ProofPool,

    /// Set of cryptographically valid proofs (TLA+ proofValidity).
    /// Tracks which proofs were generated as valid (immutable once set).
    proof_validity: BTreeSet<ProofId>,

    /// Active aggregation records (TLA+ aggregations).
    aggregations: Vec<AggregationRecord>,

    /// Proof entries held by aggregations (for recovery).
    held_entries: Vec<(AggregationId, Vec<ProofEntry>)>,

    /// Recursive verifier for folding and deciding.
    verifier: RecursiveVerifier,

    /// Next aggregation ID (monotonically increasing).
    next_agg_id: u64,
}

impl Aggregator {
    /// Create a new aggregator with default settings.
    /// [Spec: ProofAggregation.tla, lines 81-86 -- Init]
    pub fn new() -> Self {
        Self {
            pool: ProofPool::new(),
            proof_validity: BTreeSet::new(),
            aggregations: Vec::new(),
            held_entries: Vec::new(),
            verifier: RecursiveVerifier::default(),
            next_agg_id: 0,
        }
    }

    /// Create a new aggregator with a custom recursive verifier.
    pub fn with_verifier(verifier: RecursiveVerifier) -> Self {
        Self {
            pool: ProofPool::new(),
            proof_validity: BTreeSet::new(),
            aggregations: Vec::new(),
            held_entries: Vec::new(),
            verifier,
            next_agg_id: 0,
        }
    }

    // -----------------------------------------------------------------------
    // Action: Proof Generation
    // [Spec: ProofAggregation.tla, lines 120-135]
    // -----------------------------------------------------------------------

    /// Register generation of a valid proof by an enterprise.
    ///
    /// [Spec: ProofAggregation.tla, lines 120-126 -- GenerateValidProof(e)]
    ///   proofCounter' = [proofCounter EXCEPT ![e] = @ + 1]
    ///   proofValidity' = proofValidity ∪ {pid}
    pub fn generate_valid_proof(&mut self, enterprise: EnterpriseId) -> ProofId {
        let seq = self.pool.register_proof_generated(enterprise);
        let pid = ProofId::new(enterprise, seq);
        self.proof_validity.insert(pid);
        pid
    }

    /// Register generation of an invalid proof by an enterprise.
    ///
    /// [Spec: ProofAggregation.tla, lines 132-135 -- GenerateInvalidProof(e)]
    ///   proofCounter' = [proofCounter EXCEPT ![e] = @ + 1]
    ///   (proofValidity unchanged -- proof NOT added to validity set)
    pub fn generate_invalid_proof(&mut self, enterprise: EnterpriseId) -> ProofId {
        let seq = self.pool.register_proof_generated(enterprise);
        ProofId::new(enterprise, seq)
    }

    // -----------------------------------------------------------------------
    // Action: Pool Submission
    // [Spec: ProofAggregation.tla, lines 148-155 -- SubmitToPool(e, n)]
    // -----------------------------------------------------------------------

    /// Submit a proof to the aggregation pool.
    ///
    /// The proof entry must have an ID matching a previously generated proof.
    /// Duplicate submissions are rejected (TLA+ guard: pid ∉ aggregationPool).
    pub fn submit_proof(&mut self, entry: ProofEntry) -> AggregatorResult<()> {
        self.pool.submit(entry)
    }

    // -----------------------------------------------------------------------
    // Action: Aggregation
    // [Spec: ProofAggregation.tla, lines 173-181 -- AggregateSubset(S)]
    // -----------------------------------------------------------------------

    /// Aggregate a subset of proofs from the pool.
    ///
    /// Takes a set of proof IDs (must all be in the pool), removes them from
    /// the pool, folds them via the recursive verifier, and creates an
    /// aggregation record.
    ///
    /// [Spec: ProofAggregation.tla, lines 173-181]:
    ///   S ⊆ aggregationPool
    ///   Cardinality(S) >= 2
    ///   allValid == (S ⊆ proofValidity)
    ///   aggregations' = aggregations ∪ {[components |-> S, valid |-> allValid, status |-> "aggregated"]}
    ///   aggregationPool' = aggregationPool \ S
    pub fn aggregate(&mut self, proof_ids: BTreeSet<ProofId>) -> AggregatorResult<AggregationId> {
        // Guard: at least MIN_AGGREGATION_SIZE proofs
        if proof_ids.len() < MIN_AGGREGATION_SIZE {
            return Err(AggregatorError::InsufficientProofs(proof_ids.len()));
        }

        // Allocate aggregation ID
        let agg_id = AggregationId(self.next_agg_id);
        self.next_agg_id += 1;

        // Take proofs from pool (enforces S ⊆ aggregationPool)
        let entries = self.pool.take_subset(&proof_ids, agg_id)?;

        // Compute validity: allValid == (S ⊆ proofValidity)
        let all_valid = proof_ids
            .iter()
            .all(|pid| self.proof_validity.contains(pid));

        // Fold proofs via recursive verifier
        let folded = self.verifier.fold_all(&entries)?;

        // Generate decider proof
        let decider = self.verifier.decide(&folded)?;

        // Create aggregation record
        let record = AggregationRecord {
            id: agg_id,
            components: proof_ids,
            valid: all_valid,
            status: AggregationStatus::Aggregated,
            aggregated_proof: Some(decider.proof_bytes),
        };

        self.aggregations.push(record);
        self.held_entries.push((agg_id, entries));

        // Assert safety invariants after state transition
        self.assert_aggregation_soundness()?;
        self.assert_single_location()?;

        Ok(agg_id)
    }

    // -----------------------------------------------------------------------
    // Action: L1 Verification
    // [Spec: ProofAggregation.tla, lines 190-199 -- VerifyOnL1(agg)]
    // -----------------------------------------------------------------------

    /// Mark an aggregation as verified by L1.
    ///
    /// [Spec: ProofAggregation.tla, lines 190-199]:
    ///   agg.status = "aggregated"
    ///   newStatus == IF agg.valid THEN "l1_verified" ELSE "l1_rejected"
    pub fn mark_l1_verified(&mut self, agg_id: AggregationId) -> AggregatorResult<()> {
        let record = self
            .aggregations
            .iter_mut()
            .find(|a| a.id == agg_id)
            .ok_or(AggregatorError::AggregationNotFound(agg_id))?;

        if record.status != AggregationStatus::Aggregated {
            return Err(AggregatorError::InvalidAggregationStatus(
                agg_id,
                record.status,
                AggregationStatus::Aggregated,
            ));
        }

        // L1 verifier is deterministic: accepts valid, rejects invalid
        if record.valid {
            record.status = AggregationStatus::L1Verified;
            // Finalize: proofs are consumed (no longer tracked as in-aggregation)
            self.pool.finalize_aggregation(agg_id);
        } else {
            record.status = AggregationStatus::L1Rejected;
        }

        Ok(())
    }

    /// Mark an aggregation as rejected by L1.
    ///
    /// Convenience method for explicitly marking rejection (same as verify
    /// with invalid proof, but allows external rejection signaling).
    pub fn mark_l1_rejected(&mut self, agg_id: AggregationId) -> AggregatorResult<()> {
        let record = self
            .aggregations
            .iter_mut()
            .find(|a| a.id == agg_id)
            .ok_or(AggregatorError::AggregationNotFound(agg_id))?;

        if record.status != AggregationStatus::Aggregated {
            return Err(AggregatorError::InvalidAggregationStatus(
                agg_id,
                record.status,
                AggregationStatus::Aggregated,
            ));
        }

        record.status = AggregationStatus::L1Rejected;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Action: Recovery from Rejection
    // [Spec: ProofAggregation.tla, lines 213-218 -- RecoverFromRejection(agg)]
    // -----------------------------------------------------------------------

    /// Recover proofs from a rejected aggregation back to the pool.
    ///
    /// [Spec: ProofAggregation.tla, lines 213-218]:
    ///   agg.status = "l1_rejected"
    ///   aggregationPool' = aggregationPool ∪ agg.components
    ///   aggregations' = aggregations \ {agg}
    ///
    /// This is the operational mechanism for IndependencePreservation (S2):
    /// valid proofs are recovered and can be re-aggregated without the
    /// offending invalid proof.
    pub fn recover(&mut self, agg_id: AggregationId) -> AggregatorResult<()> {
        // Find and validate the aggregation
        let record_idx = self
            .aggregations
            .iter()
            .position(|a| a.id == agg_id)
            .ok_or(AggregatorError::AggregationNotFound(agg_id))?;

        if self.aggregations[record_idx].status != AggregationStatus::L1Rejected {
            return Err(AggregatorError::InvalidAggregationStatus(
                agg_id,
                self.aggregations[record_idx].status,
                AggregationStatus::L1Rejected,
            ));
        }

        // Find held entries for this aggregation
        let held_idx = self
            .held_entries
            .iter()
            .position(|(id, _)| *id == agg_id)
            .ok_or(AggregatorError::AggregationNotFound(agg_id))?;

        let (_, entries) = self.held_entries.remove(held_idx);

        // Return proofs to pool
        self.pool.return_to_pool(entries, agg_id)?;

        // Remove the aggregation record
        self.aggregations.remove(record_idx);

        // Assert invariants after recovery
        self.assert_independence_preservation()?;
        self.assert_single_location()?;

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Safety property assertions
    // [Spec: ProofAggregation.tla, lines 236-313]
    // -----------------------------------------------------------------------

    /// S1: AggregationSoundness
    ///
    /// For all aggregation records:
    ///   agg.valid == (agg.components ⊆ proofValidity)
    ///
    /// [Spec: ProofAggregation.tla, lines 248-250]
    pub fn assert_aggregation_soundness(&self) -> AggregatorResult<()> {
        for agg in &self.aggregations {
            let components_all_valid = agg
                .components
                .iter()
                .all(|pid| self.proof_validity.contains(pid));

            if agg.valid != components_all_valid {
                return Err(AggregatorError::InvariantViolation(format!(
                    "S1 AggregationSoundness: aggregation {:?} has valid={} but components_all_valid={}",
                    agg.id, agg.valid, components_all_valid
                )));
            }
        }
        Ok(())
    }

    /// S2: IndependencePreservation
    ///
    /// For all ever-submitted valid proofs:
    ///   pid in proofValidity =>
    ///     pid in aggregationPool OR exists agg: pid in agg.components
    ///
    /// [Spec: ProofAggregation.tla, lines 262-266]
    pub fn assert_independence_preservation(&self) -> AggregatorResult<()> {
        for pid in self.pool.ever_submitted_ids() {
            if !self.proof_validity.contains(pid) {
                continue; // Only check valid proofs
            }

            let in_pool = self.pool.contains(pid);
            let in_agg = self
                .aggregations
                .iter()
                .any(|agg| agg.components.contains(pid));

            if !in_pool && !in_agg {
                return Err(AggregatorError::InvariantViolation(format!(
                    "S2 IndependencePreservation: valid proof {:?} is neither in pool nor in any aggregation",
                    pid
                )));
            }
        }
        Ok(())
    }

    /// S3: OrderIndependence
    ///
    /// For all pairs of aggregations with the same components:
    ///   a1.components == a2.components => a1.valid == a2.valid
    ///
    /// [Spec: ProofAggregation.tla, lines 279-281]
    pub fn assert_order_independence(&self) -> AggregatorResult<()> {
        for (i, a1) in self.aggregations.iter().enumerate() {
            for a2 in self.aggregations.iter().skip(i + 1) {
                if a1.components == a2.components && a1.valid != a2.valid {
                    return Err(AggregatorError::InvariantViolation(format!(
                        "S3 OrderIndependence: aggregations {:?} and {:?} have same components but different validity ({} vs {})",
                        a1.id, a2.id, a1.valid, a2.valid
                    )));
                }
            }
        }
        Ok(())
    }

    /// S4: GasMonotonicity
    ///
    /// For all aggregations:
    ///   AggregatedGasCost < BaseGasPerProof * Cardinality(agg.components)
    ///
    /// [Spec: ProofAggregation.tla, lines 296-298]
    pub fn assert_gas_monotonicity(&self) -> AggregatorResult<()> {
        for agg in &self.aggregations {
            let n = agg.components.len() as u64;
            let individual_cost = BASE_GAS_PER_PROOF * n;

            if AGGREGATED_GAS_COST >= individual_cost {
                return Err(AggregatorError::InvariantViolation(format!(
                    "S4 GasMonotonicity: aggregated cost {}K >= individual cost {}K for N={}",
                    AGGREGATED_GAS_COST / 1000,
                    individual_cost / 1000,
                    n
                )));
            }
        }
        Ok(())
    }

    /// S5: SingleLocation
    ///
    /// Each proof is in at most one location: pool or one aggregation.
    ///
    /// [Spec: ProofAggregation.tla, lines 307-313]
    pub fn assert_single_location(&self) -> AggregatorResult<()> {
        self.pool.assert_single_location(&self.aggregations)
    }

    /// Assert ALL safety invariants (S1-S5).
    ///
    /// Call after any state transition to verify the system remains consistent.
    pub fn assert_all_invariants(&self) -> AggregatorResult<()> {
        self.assert_aggregation_soundness()?;
        self.assert_independence_preservation()?;
        self.assert_order_independence()?;
        self.assert_gas_monotonicity()?;
        self.assert_single_location()?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------------

    /// Get the number of proofs in the pool.
    pub fn pool_size(&self) -> usize {
        self.pool.pool_size()
    }

    /// Get the number of active aggregations.
    pub fn aggregation_count(&self) -> usize {
        self.aggregations.len()
    }

    /// Get a reference to an aggregation record by ID.
    pub fn get_aggregation(&self, agg_id: AggregationId) -> Option<&AggregationRecord> {
        self.aggregations.iter().find(|a| a.id == agg_id)
    }

    /// Get all aggregation records.
    pub fn aggregations(&self) -> &[AggregationRecord] {
        &self.aggregations
    }

    /// Get the proof pool IDs.
    pub fn pool_ids(&self) -> BTreeSet<ProofId> {
        self.pool.pool_ids()
    }

    /// Get a reference to the pool.
    pub fn pool(&self) -> &ProofPool {
        &self.pool
    }

    /// Check if a proof is valid (in the proofValidity set).
    pub fn is_proof_valid(&self, pid: &ProofId) -> bool {
        self.proof_validity.contains(pid)
    }

    /// Compute amortized gas cost per enterprise for N aggregated proofs.
    ///
    /// [Source: findings.md, Section 3.2 -- Per-Enterprise Amortized Gas]
    pub fn gas_per_enterprise(n: usize) -> u64 {
        if n == 0 {
            return 0;
        }
        AGGREGATED_GAS_COST / (n as u64)
    }

    /// Compute gas savings factor for N aggregated proofs.
    ///
    /// Returns (individual_cost, aggregated_cost, savings_factor).
    pub fn gas_savings(n: usize) -> (u64, u64, f64) {
        let individual = BASE_GAS_PER_PROOF * (n as u64);
        let aggregated = AGGREGATED_GAS_COST;
        let factor = if aggregated > 0 {
            individual as f64 / aggregated as f64
        } else {
            0.0
        };
        (individual, aggregated, factor)
    }
}

impl Default for Aggregator {
    fn default() -> Self {
        Self::new()
    }
}
