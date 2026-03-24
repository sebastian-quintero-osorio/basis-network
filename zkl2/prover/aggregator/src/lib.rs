//! Basis Network Proof Aggregation Library
//!
//! Implements the proof aggregation pipeline formalized in ProofAggregation.tla
//! (TLC verified: 788,734 states, 209,517 distinct, all 5 safety properties satisfied).
//!
//! # Architecture
//!
//! ```text
//! Enterprise 1..N chains
//!       |
//!   [halo2-KZG Proofs]  (basis-circuit crate)
//!       |
//!   ProofPool (pool.rs)
//!       | submit / take / return
//!       v
//!   Aggregator (aggregator.rs)
//!       | aggregate / recover
//!       v
//!   RecursiveVerifier (verifier_circuit.rs)
//!       | ProtoGalaxy fold + Groth16 decide
//!       v
//!   ProofTree (tree.rs)
//!       | binary tree reduction
//!       v
//!   AggregatedProof (~128 bytes, ~220K gas on L1)
//! ```
//!
//! # Safety Properties (TLA+ verified)
//!
//! - S1 AggregationSoundness: aggregated proof valid iff ALL components valid
//! - S2 IndependencePreservation: valid proofs never permanently lost
//! - S3 OrderIndependence: same components => same validity
//! - S4 GasMonotonicity: aggregated gas < individual gas * N for N >= 2
//! - S5 SingleLocation: each proof in exactly one location (pool xor aggregation)
//!
//! # Gas Savings (from research findings)
//!
//! | N enterprises | Individual | Aggregated | Savings |
//! |---------------|------------|------------|---------|
//! | 2             | 840K       | 220K       | 3.8x   |
//! | 4             | 1.68M      | 220K       | 7.6x   |
//! | 8             | 3.36M      | 220K       | 15.3x  |
//! | 16            | 6.72M      | 220K       | 30.5x  |
//!
//! [Spec: lab/3-architect/implementation-history/prover-aggregation/specs/ProofAggregation.tla]
//! [Source: lab/3-architect/implementation-history/prover-aggregation/research/findings.md]

pub mod aggregator;
pub mod folding;
pub mod pool;
pub mod tree;
pub mod types;
pub mod verifier_circuit;

#[cfg(test)]
mod tests;
