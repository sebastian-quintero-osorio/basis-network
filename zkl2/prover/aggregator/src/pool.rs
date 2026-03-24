//! Proof pool management for the aggregation pipeline.
//!
//! Maps TLA+ variables to Rust state:
//!   aggregationPool  ->  ProofPool.pool (HashMap<ProofId, ProofEntry>)
//!   everSubmitted     ->  ProofPool.ever_submitted (HashSet<ProofId>)
//!   proofCounter      ->  ProofPool.proof_counters (HashMap<EnterpriseId, u64>)
//!
//! Enforces TLA+ guards:
//!   SubmitToPool(e, n):
//!     - n >= 1 (sequence starts at 1)
//!     - n <= proofCounter[e] (proof must be generated)
//!     - <<e, n>> not in aggregationPool (duplicate rejection)
//!     - <<e, n>> not in any aggregation (single-location)
//!
//! [Spec: lab/3-architect/implementation-history/prover-aggregation/specs/ProofAggregation.tla]

use std::collections::{BTreeSet, HashMap, HashSet};

use crate::types::{
    AggregationId, AggregationRecord, AggregatorError, AggregatorResult, EnterpriseId, ProofEntry,
    ProofId,
};

// ---------------------------------------------------------------------------
// ProofPool
// ---------------------------------------------------------------------------

/// Manages the set of proofs available for aggregation.
///
/// Corresponds to TLA+ variables `aggregationPool` and `everSubmitted`.
/// Enforces single-location invariant (S5) and duplicate rejection.
pub struct ProofPool {
    /// Proofs currently available for aggregation.
    /// [Spec: ProofAggregation.tla, line 37 -- aggregationPool]
    pool: HashMap<ProofId, ProofEntry>,

    /// Monotonic set of all proofs ever submitted (never shrinks).
    /// [Spec: ProofAggregation.tla, line 38 -- everSubmitted]
    ever_submitted: HashSet<ProofId>,

    /// Number of proofs generated per enterprise.
    /// [Spec: ProofAggregation.tla, line 35 -- proofCounter]
    proof_counters: HashMap<EnterpriseId, u64>,

    /// Tracks which proofs are currently held by aggregation records.
    /// Used for SingleLocation enforcement without requiring access to aggregations.
    in_aggregation: HashMap<ProofId, AggregationId>,
}

impl ProofPool {
    /// Create an empty proof pool.
    /// [Spec: ProofAggregation.tla, lines 81-86 -- Init]
    pub fn new() -> Self {
        Self {
            pool: HashMap::new(),
            ever_submitted: HashSet::new(),
            proof_counters: HashMap::new(),
            in_aggregation: HashMap::new(),
        }
    }

    /// Register a proof generation event (increments the enterprise counter).
    ///
    /// Must be called before submitting the proof to the pool.
    /// Models TLA+ `GenerateValidProof(e)` / `GenerateInvalidProof(e)`:
    ///   proofCounter' = [proofCounter EXCEPT ![e] = @ + 1]
    pub fn register_proof_generated(&mut self, enterprise: EnterpriseId) -> u64 {
        let counter = self.proof_counters.entry(enterprise).or_insert(0);
        *counter += 1;
        *counter
    }

    /// Submit a proof to the aggregation pool.
    ///
    /// [Spec: ProofAggregation.tla, lines 148-155 -- SubmitToPool(e, n)]
    /// Guards:
    ///   1. n >= 1 (sequence starts at 1)
    ///   2. n <= proofCounter[e] (proof must be generated)
    ///   3. Not already in pool (duplicate rejection)
    ///   4. Not currently in any aggregation (single-location)
    pub fn submit(&mut self, entry: ProofEntry) -> AggregatorResult<()> {
        let pid = entry.id;

        // Guard 1: sequence >= 1 (structural: ProofId.sequence is u64, but we check > 0)
        if pid.sequence == 0 {
            return Err(AggregatorError::SequenceExceedsCounter {
                enterprise: pid.enterprise,
                sequence: pid.sequence,
                counter: 0,
            });
        }

        // Guard 2: proof must have been generated
        let counter = self
            .proof_counters
            .get(&pid.enterprise)
            .copied()
            .unwrap_or(0);
        if pid.sequence > counter {
            return Err(AggregatorError::SequenceExceedsCounter {
                enterprise: pid.enterprise,
                sequence: pid.sequence,
                counter,
            });
        }

        // Guard 3: not already in pool (duplicate rejection)
        if self.pool.contains_key(&pid) {
            return Err(AggregatorError::DuplicateProof(pid));
        }

        // Guard 4: not in any aggregation (single-location)
        if let Some(agg_id) = self.in_aggregation.get(&pid) {
            return Err(AggregatorError::ProofInAggregation(pid, *agg_id));
        }

        // Submit: add to pool and ever_submitted
        self.pool.insert(pid, entry);
        self.ever_submitted.insert(pid);

        Ok(())
    }

    /// Take a subset of proofs from the pool for aggregation.
    ///
    /// Removes the proofs from the pool and marks them as in-aggregation.
    /// Models the pool side of TLA+ `AggregateSubset(S)`:
    ///   aggregationPool' = aggregationPool \ S
    ///
    /// Returns the proof entries in deterministic order (by ProofId).
    pub fn take_subset(
        &mut self,
        ids: &BTreeSet<ProofId>,
        agg_id: AggregationId,
    ) -> AggregatorResult<Vec<ProofEntry>> {
        // Verify all requested proofs are in the pool
        for pid in ids {
            if !self.pool.contains_key(pid) {
                return Err(AggregatorError::ProofNotInPool(*pid));
            }
        }

        // Remove from pool and mark as in-aggregation
        let mut entries = Vec::with_capacity(ids.len());
        for pid in ids {
            let entry = self.pool.remove(pid).expect("checked above");
            self.in_aggregation.insert(*pid, agg_id);
            entries.push(entry);
        }

        Ok(entries)
    }

    /// Return proofs to the pool after a rejected aggregation is recovered.
    ///
    /// Models TLA+ `RecoverFromRejection(agg)`:
    ///   aggregationPool' = aggregationPool ∪ agg.components
    pub fn return_to_pool(
        &mut self,
        entries: Vec<ProofEntry>,
        agg_id: AggregationId,
    ) -> AggregatorResult<()> {
        for entry in entries {
            let pid = entry.id;
            // Remove from in_aggregation tracking
            self.in_aggregation.remove(&pid);
            // Return to pool
            self.pool.insert(pid, entry);
        }

        // Also clean up any remaining in_aggregation entries for this agg_id
        self.in_aggregation.retain(|_, id| *id != agg_id);

        Ok(())
    }

    /// Remove aggregation tracking for verified proofs (they are consumed).
    pub fn finalize_aggregation(&mut self, agg_id: AggregationId) {
        self.in_aggregation.retain(|_, id| *id != agg_id);
    }

    /// Check if a proof is in the pool.
    pub fn contains(&self, pid: &ProofId) -> bool {
        self.pool.contains_key(pid)
    }

    /// Check if a proof was ever submitted.
    pub fn was_submitted(&self, pid: &ProofId) -> bool {
        self.ever_submitted.contains(pid)
    }

    /// Check if a proof is currently in an aggregation.
    pub fn is_in_aggregation(&self, pid: &ProofId) -> Option<AggregationId> {
        self.in_aggregation.get(pid).copied()
    }

    /// Get the current proof counter for an enterprise.
    pub fn proof_counter(&self, enterprise: &EnterpriseId) -> u64 {
        self.proof_counters.get(enterprise).copied().unwrap_or(0)
    }

    /// Get the number of proofs currently in the pool.
    pub fn pool_size(&self) -> usize {
        self.pool.len()
    }

    /// Get all proof IDs currently in the pool.
    pub fn pool_ids(&self) -> BTreeSet<ProofId> {
        self.pool.keys().copied().collect()
    }

    /// Get a reference to a proof entry by ID.
    pub fn get(&self, pid: &ProofId) -> Option<&ProofEntry> {
        self.pool.get(pid)
    }

    /// Get all proof entries for a given set of IDs (cloned, for recovery).
    pub fn get_entries_by_ids(&self, ids: &BTreeSet<ProofId>) -> Vec<ProofEntry> {
        ids.iter()
            .filter_map(|pid| self.pool.get(pid).cloned())
            .collect()
    }

    /// Get the set of all ever-submitted proof IDs.
    pub fn ever_submitted_ids(&self) -> &HashSet<ProofId> {
        &self.ever_submitted
    }

    /// Assert S5: SingleLocation invariant.
    ///
    /// Each proof must be in at most one location: either in the pool
    /// OR in exactly one aggregation record. Never both.
    ///
    /// [Spec: ProofAggregation.tla, lines 307-313 -- SingleLocation]
    pub fn assert_single_location(
        &self,
        aggregations: &[AggregationRecord],
    ) -> AggregatorResult<()> {
        for pid in self.ever_submitted.iter() {
            let in_pool = self.pool.contains_key(pid);
            let agg_count = aggregations
                .iter()
                .filter(|agg| agg.components.contains(pid))
                .count();

            // If in pool, not in any aggregation
            if in_pool && agg_count > 0 {
                return Err(AggregatorError::InvariantViolation(format!(
                    "S5 SingleLocation: proof {:?} is in pool AND in {} aggregation(s)",
                    pid, agg_count
                )));
            }

            // In at most one aggregation
            if agg_count > 1 {
                return Err(AggregatorError::InvariantViolation(format!(
                    "S5 SingleLocation: proof {:?} is in {} aggregations (max 1)",
                    pid, agg_count
                )));
            }
        }

        Ok(())
    }
}

impl Default for ProofPool {
    fn default() -> Self {
        Self::new()
    }
}
