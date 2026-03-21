---- MODULE ProofAggregation ----

EXTENDS Integers, FiniteSets, TLC

\* ============================================================================
\*                          CONSTANTS
\* ============================================================================

CONSTANTS
    Enterprises,         \* Set of registered enterprises on the network
    MaxProofsPerEnt,     \* Maximum proofs each enterprise can generate per epoch
    BaseGasPerProof,     \* L1 gas cost for individual proof verification (420K for halo2-KZG)
    AggregatedGasCost    \* L1 gas cost for aggregated proof verification (220K for Groth16 decider)

\* ============================================================================
\*                     DERIVED CONSTANTS
\* ============================================================================

\* [Source: 0-input/REPORT.md, Section 3.4 -- Architecture Design]
\* Unique proof identifier: (enterprise, sequence_number).
\* Each enterprise generates proofs sequentially numbered 1..MaxProofsPerEnt.
ProofIds == Enterprises \X (1..MaxProofsPerEnt)

\* Lifecycle states for an aggregated proof record.
\*   aggregated:   folding complete, awaiting L1 submission
\*   l1_verified:  L1 accepted the aggregated proof
\*   l1_rejected:  L1 rejected the aggregated proof (invalid component)
AggStatuses == {"aggregated", "l1_verified", "l1_rejected"}

\* ============================================================================
\*                          VARIABLES
\* ============================================================================

VARIABLES
    proofCounter,      \* [Enterprises -> 0..MaxProofsPerEnt] -- proofs generated per enterprise
    proofValidity,     \* SUBSET ProofIds -- set of cryptographically valid proofs
    aggregationPool,   \* SUBSET ProofIds -- proofs submitted and available for aggregation
    everSubmitted,     \* SUBSET ProofIds -- proofs ever submitted to the pool (monotonic)
    aggregations       \* Set of aggregation records (see AggRecord domain below)

vars == << proofCounter, proofValidity, aggregationPool, everSubmitted, aggregations >>

\* ============================================================================
\*                     DOMAIN DEFINITIONS
\* ============================================================================

\* An aggregation record captures the result of folding a set of proofs.
\*   components: the set of proof IDs that were folded together
\*   valid:      TRUE iff all component proofs are cryptographically valid
\*   status:     lifecycle state (aggregated -> l1_verified | l1_rejected)
\*
\* [Source: 0-input/REPORT.md, Section 3.4 -- ProtoGalaxy Folding Layer]
\* The components field is a SET, not a sequence. This structural choice
\* enforces OrderIndependence: the folding result depends only on set
\* membership, never on the presentation order.

\* ============================================================================
\*                     TYPE INVARIANT
\* ============================================================================

TypeOK ==
    /\ \A e \in Enterprises: proofCounter[e] \in 0..MaxProofsPerEnt
    /\ proofValidity \subseteq ProofIds
    /\ aggregationPool \subseteq ProofIds
    /\ everSubmitted \subseteq ProofIds
    /\ aggregationPool \subseteq everSubmitted
    /\ \A agg \in aggregations:
        /\ agg.components \subseteq ProofIds
        /\ agg.components /= {}
        /\ Cardinality(agg.components) >= 2
        /\ agg.valid \in BOOLEAN
        /\ agg.status \in AggStatuses

\* ============================================================================
\*                     INITIAL STATE
\* ============================================================================

\* [Source: 0-input/REPORT.md, Section 3.4 -- Architecture Design]
\* System starts with no proofs generated, empty pool, no aggregations.
\* Each enterprise has its own independent prover (NonInteraction axiom).
Init ==
    /\ proofCounter = [e \in Enterprises |-> 0]
    /\ proofValidity = {}
    /\ aggregationPool = {}
    /\ everSubmitted = {}
    /\ aggregations = {}

\* ============================================================================
\*                     CRYPTOGRAPHIC AXIOMS
\* ============================================================================

\* [Source: 0-input/REPORT.md, Section 5 -- Key Invariants Discovered]
\*
\* AXIOM (Proof Soundness): Each enterprise's halo2-KZG proof is either
\*   cryptographically valid (correct witness, correct circuit) or invalid
\*   (corrupted witness, wrong circuit). Validity is intrinsic and immutable:
\*   determined at generation time, never altered by aggregation or verification.
\*
\* AXIOM (Aggregation Soundness): ProtoGalaxy folding preserves soundness.
\*   The folded instance is satisfiable iff ALL component instances are
\*   satisfiable. The Groth16 decider then proves the folded instance,
\*   producing a proof valid iff the folded instance is satisfiable.
\*   [Source: 0-input/REPORT.md, Section 5 -- INV-AGG-1]
\*
\* AXIOM (Folding Commutativity): ProtoGalaxy folding is commutative and
\*   associative. fold(a, fold(b, c)) = fold(fold(a, b), c) = fold(b, fold(a, c)).
\*   The final folded instance depends only on the SET of inputs, not order.
\*   [Source: 0-input/REPORT.md, Section 5 -- INV-AGG-3]

\* ============================================================================
\*                     ACTIONS
\* ============================================================================

\* --- Proof Generation ---

\* [Source: 0-input/REPORT.md, Section 3.4 -- Enterprise chains produce halo2-KZG proofs]
\* [Source: 0-input/REPORT.md, Section 5 -- Key Invariant 4: NonInteraction]
\* Enterprise generates a cryptographically valid halo2-KZG proof.
\* Each enterprise operates its own prover independently.
GenerateValidProof(e) ==
    /\ proofCounter[e] < MaxProofsPerEnt
    /\ LET pid == <<e, proofCounter[e] + 1>>
       IN
        /\ proofCounter' = [proofCounter EXCEPT ![e] = @ + 1]
        /\ proofValidity' = proofValidity \union {pid}
        /\ UNCHANGED << aggregationPool, everSubmitted, aggregations >>

\* [Source: 0-input/REPORT.md, Section 9 -- Stage 3: Adversarial]
\* Enterprise generates an INVALID proof. Models: corrupted witness, wrong
\* circuit, computational error, or deliberate attack. The proof is generated
\* (counter increments) but NOT added to proofValidity.
GenerateInvalidProof(e) ==
    /\ proofCounter[e] < MaxProofsPerEnt
    /\ proofCounter' = [proofCounter EXCEPT ![e] = @ + 1]
    /\ UNCHANGED << proofValidity, aggregationPool, everSubmitted, aggregations >>

\* --- Pool Submission ---

\* [Source: 0-input/REPORT.md, Section 5 -- NonInteraction]
\* Enterprise submits a generated proof to the aggregation pool.
\* Guards:
\*   1. Proof has been generated (n <= proofCounter[e])
\*   2. Not already in pool (duplicate rejection)
\*   3. Not currently in any aggregation (single-location invariant)
\* The guard on pool membership enforces duplicate rejection:
\* attempting to submit a proof already in the pool is simply not enabled.
\* This models: "Intento de incluir proof duplicado" -- the action is disabled.
SubmitToPool(e, n) ==
    /\ n >= 1
    /\ n <= proofCounter[e]
    /\ <<e, n>> \notin aggregationPool
    /\ \A agg \in aggregations: <<e, n>> \notin agg.components
    /\ aggregationPool' = aggregationPool \union {<<e, n>>}
    /\ everSubmitted' = everSubmitted \union {<<e, n>>}
    /\ UNCHANGED << proofCounter, proofValidity, aggregations >>

\* --- Aggregation ---

\* [Source: 0-input/REPORT.md, Section 3.4 -- ProtoGalaxy Folding Layer]
\* [Source: 0-input/REPORT.md, Section 3.1 -- Strategy Comparison Matrix]
\* Aggregate a subset of proofs from the pool via ProtoGalaxy folding.
\* Requires at least 2 proofs (aggregating a single proof has no benefit).
\*
\* The aggregation operates on a SET, not a sequence. This structurally
\* enforces OrderIndependence: since set membership is order-agnostic,
\* the result depends only on WHICH proofs are included, never on the
\* order they were presented. This models the Folding Commutativity axiom.
\*
\* Soundness: the aggregated proof is valid iff ALL component proofs are
\* cryptographically valid. This is the Aggregation Soundness axiom.
\*
\* Proofs are removed from the pool upon aggregation (consumed by folding).
AggregateSubset(S) ==
    /\ S \subseteq aggregationPool
    /\ Cardinality(S) >= 2
    /\ LET allValid == (S \subseteq proofValidity)
       IN
        /\ aggregations' = aggregations \union
               {[components |-> S, valid |-> allValid, status |-> "aggregated"]}
        /\ aggregationPool' = aggregationPool \ S
        /\ UNCHANGED << proofCounter, proofValidity, everSubmitted >>

\* --- L1 Verification ---

\* [Source: 0-input/REPORT.md, Section 3.4 -- L1 Verification: ~220K gas]
\* [Source: 0-input/REPORT.md, Section 6.2 -- Gas Savings by Strategy]
\* Submit the aggregated Groth16 proof to BasisRollup.sol on L1 for verification.
\* The L1 verifier is deterministic: accepts valid proofs, rejects invalid ones.
\* Gas cost is AggregatedGasCost (~220K), independent of component count.
VerifyOnL1(agg) ==
    /\ agg \in aggregations
    /\ agg.status = "aggregated"
    /\ LET newStatus == IF agg.valid THEN "l1_verified" ELSE "l1_rejected"
       IN
        /\ aggregations' = (aggregations \ {agg}) \union
               {[components |-> agg.components,
                 valid |-> agg.valid,
                 status |-> newStatus]}
        /\ UNCHANGED << proofCounter, proofValidity, aggregationPool, everSubmitted >>

\* --- Recovery from Rejection ---

\* [Source: 0-input/REPORT.md, Section 5 -- Key Invariant 2: IndependencePreservation]
\* When an aggregated proof is rejected at L1 (due to an invalid component),
\* recover all component proofs back to the aggregation pool. This enables
\* re-aggregation excluding the invalid proof, preserving independence:
\* a valid proof from enterprise e2 is not permanently lost because
\* enterprise e1 submitted an invalid proof.
\*
\* This action is the operational mechanism for IndependencePreservation.
\* Without it, valid proofs consumed by a failed aggregation would be
\* permanently inaccessible.
RecoverFromRejection(agg) ==
    /\ agg \in aggregations
    /\ agg.status = "l1_rejected"
    /\ aggregationPool' = aggregationPool \union agg.components
    /\ aggregations' = aggregations \ {agg}
    /\ UNCHANGED << proofCounter, proofValidity, everSubmitted >>

\* ============================================================================
\*                     NEXT-STATE RELATION
\* ============================================================================

Next ==
    \/ \E e \in Enterprises: GenerateValidProof(e)
    \/ \E e \in Enterprises: GenerateInvalidProof(e)
    \/ \E e \in Enterprises, n \in 1..MaxProofsPerEnt: SubmitToPool(e, n)
    \/ \E S \in SUBSET aggregationPool: AggregateSubset(S)
    \/ \E agg \in aggregations: VerifyOnL1(agg)
    \/ \E agg \in aggregations: RecoverFromRejection(agg)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\*                     SAFETY PROPERTIES
\* ============================================================================

\* --- S1: AggregationSoundness ---
\* [Why]: The aggregated proof must be valid if and only if ALL component proofs
\* are cryptographically valid. A single invalid component MUST cause the entire
\* aggregated proof to be rejected. This is the foundational security guarantee
\* of the ProtoGalaxy folding + Groth16 decider architecture.
\* Both directions matter:
\*   Forward:  all valid => aggregation valid (no false negatives)
\*   Backward: aggregation valid => all valid (no false positives / soundness)
\* [Source: 0-input/REPORT.md, Section 5 -- INV-AGG-1]
\* [Source: 0-input/REPORT.md, Section 8 -- Updated Invariant INV-AGG-1]
AggregationSoundness ==
    \A agg \in aggregations:
        agg.valid = (agg.components \subseteq proofValidity)

\* --- S2: IndependencePreservation ---
\* [Why]: A valid proof that has been submitted to the aggregation system must
\* remain accessible: either in the aggregation pool (available for future
\* aggregation) or in an aggregation record (pending, verified, or rejected).
\* No valid proof is permanently lost due to co-aggregation with an invalid
\* proof from another enterprise. Combined with RecoverFromRejection, this
\* guarantees that valid proofs in rejected aggregations can be recovered
\* to the pool and re-aggregated without the offending invalid proof.
\* [Source: 0-input/REPORT.md, Section 5 -- INV-AGG-2]
\* [Source: 0-input/REPORT.md, Section 8 -- Updated Invariant INV-AGG-2]
IndependencePreservation ==
    \A pid \in everSubmitted:
        pid \in proofValidity =>
            \/ pid \in aggregationPool
            \/ \E agg \in aggregations: pid \in agg.components

\* --- S3: OrderIndependence ---
\* [Why]: The aggregation result must be deterministic with respect to the
\* component set. Two aggregation records over the exact same proof set must
\* yield the same validity verdict. This verifies the Folding Commutativity
\* axiom at the protocol level: since ProtoGalaxy folding is commutative
\* and associative, the order of folding does not affect the result.
\* The model enforces this structurally by using set-based aggregation.
\* This invariant additionally verifies no action creates inconsistent
\* records over the same component set across time (after recovery + re-agg).
\* [Source: 0-input/REPORT.md, Section 5 -- INV-AGG-3]
\* [Source: 0-input/REPORT.md, Section 8 -- Updated Invariant INV-AGG-3]
OrderIndependence ==
    \A a1, a2 \in aggregations:
        (a1.components = a2.components) => (a1.valid = a2.valid)

\* --- S4: GasMonotonicity ---
\* [Why]: The per-enterprise gas cost of aggregated verification must be
\* strictly less than individual verification for N >= 2 enterprises.
\* Since AggregatedGasCost is constant regardless of N, per-enterprise
\* cost = AggregatedGasCost / N, which strictly decreases as N increases.
\* This invariant verifies the parameter relationship:
\*   AggregatedGasCost < BaseGasPerProof * N  for all N >= 2
\* With AggregatedGasCost=220K and BaseGasPerProof=420K:
\*   N=2: 220K < 840K (3.8x savings)
\*   N=3: 220K < 1260K (5.7x savings)
\*   N=6: 220K < 2520K (11.5x savings)
\* [Source: 0-input/REPORT.md, Section 3.2 -- Gas Savings Factor by N]
\* [Source: 0-input/REPORT.md, Section 8 -- Updated Invariant INV-AGG-4]
GasMonotonicity ==
    \A agg \in aggregations:
        AggregatedGasCost < BaseGasPerProof * Cardinality(agg.components)

\* --- S5: SingleLocation ---
\* [Why]: Each proof must be in at most one location: either in the
\* aggregation pool OR in exactly one aggregation record. Never both,
\* never in two aggregations simultaneously. This prevents double-counting
\* or double-spending of proofs, which would violate soundness.
\* Structurally enforced by AggregateSubset (removes from pool on aggregate)
\* and RecoverFromRejection (returns to pool and removes aggregation).
SingleLocation ==
    \A pid \in ProofIds:
        \* If in pool, not in any aggregation
        /\ (pid \in aggregationPool =>
               \A agg \in aggregations: pid \notin agg.components)
        \* In at most one aggregation
        /\ Cardinality({agg \in aggregations: pid \in agg.components}) <= 1

====
