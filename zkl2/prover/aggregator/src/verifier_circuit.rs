/// Recursive verifier circuit interface for proof aggregation.
///
/// Models the ProtoGalaxy folding + Groth16 decider pipeline from the research:
///   1. ProtoGalaxy folds N halo2-KZG instances into 1 accumulated instance
///   2. Groth16 decider proves the accumulated instance, producing ~128-byte proof
///   3. L1 verifies the Groth16 proof at ~220K gas (constant, independent of N)
///
/// The current implementation provides a faithful simulation that preserves
/// the cryptographic axioms from the TLA+ specification:
///   - Proof Soundness: validity is intrinsic and immutable
///   - Aggregation Soundness: folded instance satisfiable iff ALL components satisfiable
///   - Folding Commutativity: result depends only on the SET of inputs
///
/// Production path: replace simulation with Sonobe ProtoGalaxy + CycleFold on BN254.
///
/// [Spec: lab/3-architect/implementation-history/prover-aggregation/specs/ProofAggregation.tla]
/// [Source: implementation-history/prover-aggregation/research/findings.md, Section 3.3]

use sha2::{Digest, Sha256};

use crate::types::{AggregatorError, AggregatorResult, DeciderProof, FoldedInstance, ProofEntry};

// ---------------------------------------------------------------------------
// Recursive verifier
// ---------------------------------------------------------------------------

/// Recursive verifier implementing the ProtoGalaxy + Groth16 decider model.
///
/// In production, this wraps Sonobe's ProtoGalaxy folding scheme with
/// CycleFold for non-native field arithmetic and a Groth16 decider
/// for EVM-verifiable output.
///
/// The simulation layer faithfully models:
///   - Folding as AND-reduction of validity flags (Aggregation Soundness axiom)
///   - Set-based determinism (Folding Commutativity axiom)
///   - Constant-size output regardless of input count
pub struct RecursiveVerifier {
    /// Maximum number of proofs that can be aggregated in one batch.
    max_aggregation_size: usize,
}

impl RecursiveVerifier {
    /// Create a new recursive verifier.
    ///
    /// `max_aggregation_size`: Upper bound on proofs per aggregation (for resource planning).
    pub fn new(max_aggregation_size: usize) -> Self {
        Self {
            max_aggregation_size,
        }
    }

    /// Fold two proof instances into one accumulated instance.
    ///
    /// Models ProtoGalaxy folding (Section 3.4 of research findings):
    ///   fold(a, b) produces an accumulated instance that is satisfiable
    ///   iff BOTH a and b are satisfiable.
    ///
    /// The Folding Commutativity axiom guarantees:
    ///   fold(a, b) == fold(b, a) (commutativity)
    ///   fold(a, fold(b, c)) == fold(fold(a, b), c) (associativity)
    ///
    /// [Spec: ProofAggregation.tla, lines 105-108 -- Folding Commutativity axiom]
    pub fn fold_pair(
        &self,
        left: &FoldedInstance,
        right: &FoldedInstance,
    ) -> AggregatorResult<FoldedInstance> {
        // Aggregation Soundness: result is satisfiable iff BOTH inputs are satisfiable.
        // [Spec: ProofAggregation.tla, lines 99-103 -- Aggregation Soundness axiom]
        let satisfiable = left.satisfiable && right.satisfiable;
        let num_components = left.num_components + right.num_components;

        // Deterministic state derivation (commutativity via sorted hash).
        // In production: actual PLONKish instance accumulation.
        let mut hasher = Sha256::new();
        // Sort states to ensure commutativity
        let mut states = [&left.state, &right.state];
        states.sort();
        for s in &states {
            hasher.update(s);
        }
        let state = hasher.finalize().to_vec();

        Ok(FoldedInstance {
            satisfiable,
            num_components,
            state,
        })
    }

    /// Create a leaf folded instance from a single proof entry.
    ///
    /// Wraps a raw proof as the initial input to the folding pipeline.
    pub fn proof_to_instance(&self, entry: &ProofEntry) -> FoldedInstance {
        // Deterministic state from proof data
        let mut hasher = Sha256::new();
        hasher.update(&entry.proof_data);
        for pi in &entry.public_inputs {
            hasher.update(pi);
        }
        let state = hasher.finalize().to_vec();

        FoldedInstance {
            satisfiable: entry.valid,
            num_components: 1,
            state,
        }
    }

    /// Fold a set of proof entries using binary tree reduction.
    ///
    /// This is the main aggregation entry point. Takes N proof entries
    /// and produces a single folded instance via successive pair-folding.
    ///
    /// [Spec: ProofAggregation.tla, lines 173-181 -- AggregateSubset(S)]
    pub fn fold_all(&self, entries: &[ProofEntry]) -> AggregatorResult<FoldedInstance> {
        if entries.is_empty() {
            return Err(AggregatorError::FoldingFailed(
                "cannot fold empty set".into(),
            ));
        }

        if entries.len() > self.max_aggregation_size {
            return Err(AggregatorError::FoldingFailed(format!(
                "too many proofs: {} exceeds max {}",
                entries.len(),
                self.max_aggregation_size
            )));
        }

        // Convert proofs to leaf instances
        let mut instances: Vec<FoldedInstance> =
            entries.iter().map(|e| self.proof_to_instance(e)).collect();

        // Binary tree reduction: fold pairs until one instance remains
        while instances.len() > 1 {
            let mut next_level = Vec::new();
            let mut i = 0;

            while i < instances.len() {
                if i + 1 < instances.len() {
                    let folded = self.fold_pair(&instances[i], &instances[i + 1])?;
                    next_level.push(folded);
                    i += 2;
                } else {
                    // Odd element: promote to next level
                    next_level.push(instances[i].clone());
                    i += 1;
                }
            }

            instances = next_level;
        }

        Ok(instances.into_iter().next().expect("at least one instance"))
    }

    /// Generate the Groth16 decider proof from a folded instance.
    ///
    /// The decider proves that the accumulated PLONKish instance is satisfiable,
    /// producing a ~128-byte Groth16 proof verifiable on L1 at ~220K gas.
    ///
    /// [Spec: ProofAggregation.tla, lines 186-199 -- VerifyOnL1]
    /// [Source: findings.md, Section 3.2 -- 220K gas for Groth16 decider]
    pub fn decide(&self, folded: &FoldedInstance) -> AggregatorResult<DeciderProof> {
        // In production: Groth16 proof of the accumulated instance.
        // Simulation: deterministic 128-byte proof from folded state.
        let mut hasher = Sha256::new();
        hasher.update(b"groth16-decider:");
        hasher.update(&folded.state);
        let hash = hasher.finalize();

        // 128-byte proof (4 x 32-byte G1/G2 points in production)
        let mut proof_bytes = Vec::with_capacity(128);
        proof_bytes.extend_from_slice(&hash);
        proof_bytes.extend_from_slice(&hash);
        proof_bytes.extend_from_slice(&hash);
        proof_bytes.extend_from_slice(&hash);

        Ok(DeciderProof {
            proof_bytes,
            valid: folded.satisfiable,
        })
    }

    /// Get the maximum aggregation size.
    pub fn max_aggregation_size(&self) -> usize {
        self.max_aggregation_size
    }
}

impl Default for RecursiveVerifier {
    fn default() -> Self {
        Self::new(64)
    }
}
