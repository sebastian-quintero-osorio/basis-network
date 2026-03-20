(* ========================================================================= *)
(* Spec.v -- Faithful Translation of ProofAggregation.tla into Coq          *)
(* ========================================================================= *)
(* Source: 0-input-spec/ProofAggregation.tla                                 *)
(* TLC Evidence: 788,734 states, 209,517 distinct, depth 19 -- PASS          *)
(*                                                                           *)
(* Translation methodology:                                                  *)
(*   - TLA+ VARIABLES -> Coq Record fields                                   *)
(*   - TLA+ sets of aggregation records -> Prop-valued relation              *)
(*   - TLA+ actions -> Coq Definitions as Prop relations on State pairs     *)
(*   - TLA+ SUBSET ProofIds -> PidSet (axiomatized finite sets)             *)
(*   - TLA+ Cardinality -> pid_card : PidSet -> nat                         *)
(*   - TLA+ safety invariants -> Coq Definitions as State predicates        *)
(*                                                                           *)
(* Each definition tagged with source TLA+ line numbers.                     *)
(* ========================================================================= *)

From Stdlib Require Import Arith PeanoNat Bool.
From ProofAggregation Require Import Common.

(* ========================================================================= *)
(*                               STATE                                       *)
(* ========================================================================= *)

(* [TLA+ lines 34-41: VARIABLES]
   The aggregation set is modeled as a Prop-valued relation
   (components, valid, status) rather than a concrete data structure.
   This captures set semantics naturally: no duplicates, order-irrelevant. *)
Record State := mkState {
  proofCounter    : nat -> nat;
  proofValidity   : PidSet;
  aggregationPool : PidSet;
  everSubmitted   : PidSet;
  agg_exists      : PidSet -> bool -> AggStatus -> Prop
}.

(* ========================================================================= *)
(*                     INITIAL STATE                                          *)
(* ========================================================================= *)

(* [TLA+ lines 81-86: Init] *)
Definition Init (s : State) : Prop :=
  (forall e, proofCounter s e = 0) /\
  proofValidity s = pid_empty /\
  aggregationPool s = pid_empty /\
  everSubmitted s = pid_empty /\
  (forall S v st, ~ agg_exists s S v st).

(* ========================================================================= *)
(*                          ACTIONS                                           *)
(* ========================================================================= *)

(* [TLA+ lines 120-126: GenerateValidProof(e)]
   Enterprise generates a cryptographically valid halo2-KZG proof.
   proofCounter[e] increments; new pid added to proofValidity.
   UNCHANGED << aggregationPool, everSubmitted, aggregations >> *)
Definition GenerateValidProof (e : nat) (s s' : State) : Prop :=
  let pid := mkPid e (S (proofCounter s e)) in
  (forall e', proofCounter s' e' =
    if Nat.eq_dec e' e then S (proofCounter s e)
    else proofCounter s e') /\
  proofValidity s' =
    pid_union (proofValidity s) (pid_add pid pid_empty) /\
  aggregationPool s' = aggregationPool s /\
  everSubmitted s' = everSubmitted s /\
  (forall S v st, agg_exists s' S v st <-> agg_exists s S v st).

(* [TLA+ lines 132-135: GenerateInvalidProof(e)]
   Enterprise generates an INVALID proof.
   proofCounter[e] increments; proofValidity unchanged. *)
Definition GenerateInvalidProof (e : nat) (s s' : State) : Prop :=
  (forall e', proofCounter s' e' =
    if Nat.eq_dec e' e then S (proofCounter s e)
    else proofCounter s e') /\
  proofValidity s' = proofValidity s /\
  aggregationPool s' = aggregationPool s /\
  everSubmitted s' = everSubmitted s /\
  (forall S v st, agg_exists s' S v st <-> agg_exists s S v st).

(* [TLA+ lines 148-155: SubmitToPool(pid)]
   Enterprise submits a generated proof to the aggregation pool.
   Guards: sequence >= 1, sequence <= counter, not in pool, not in any agg.
   aggregationPool and everSubmitted grow by {pid}. *)
Definition SubmitToPool (pid : ProofId) (s s' : State) : Prop :=
  pid_seq pid >= 1 /\
  pid_seq pid <= proofCounter s (pid_ent pid) /\
  ~ pid_mem pid (aggregationPool s) /\
  (forall S v st, agg_exists s S v st -> ~ pid_mem pid S) /\
  aggregationPool s' =
    pid_union (aggregationPool s) (pid_add pid pid_empty) /\
  everSubmitted s' =
    pid_union (everSubmitted s) (pid_add pid pid_empty) /\
  proofCounter s' = proofCounter s /\
  proofValidity s' = proofValidity s /\
  (forall S v st, agg_exists s' S v st <-> agg_exists s S v st).

(* [TLA+ lines 173-181: AggregateSubset(S)]
   Aggregate a subset of proofs from the pool via ProtoGalaxy folding.
   Guards: S subset of pool, |S| >= 2.
   allValid == (S subset of proofValidity).
   Creates new aggregation record; removes S from pool. *)
Definition AggregateSubset (S : PidSet) (s s' : State) : Prop :=
  pid_is_subset S (aggregationPool s) /\
  pid_card S >= MinAggregationSize /\
  (forall S' v' st', agg_exists s' S' v' st' <->
    (S' = S /\ v' = subset_bool S (proofValidity s) /\ st' = Aggregated)
    \/ agg_exists s S' v' st') /\
  aggregationPool s' = pid_diff (aggregationPool s) S /\
  proofCounter s' = proofCounter s /\
  proofValidity s' = proofValidity s /\
  everSubmitted s' = everSubmitted s.

(* [TLA+ lines 190-199: VerifyOnL1(agg)]
   Submit aggregated Groth16 proof to BasisRollup.sol on L1.
   L1 verifier is deterministic: accepts valid, rejects invalid.
   Status changes from Aggregated to L1Verified or L1Rejected. *)
Definition VerifyOnL1 (S : PidSet) (v : bool) (s s' : State) : Prop :=
  agg_exists s S v Aggregated /\
  (forall S' v' st', agg_exists s' S' v' st' <->
    (S' = S /\ v' = v /\
      st' = (if v then L1Verified else L1Rejected))
    \/ (agg_exists s S' v' st' /\
        ~ (S' = S /\ v' = v /\ st' = Aggregated))) /\
  proofCounter s' = proofCounter s /\
  proofValidity s' = proofValidity s /\
  aggregationPool s' = aggregationPool s /\
  everSubmitted s' = everSubmitted s.

(* [TLA+ lines 213-218: RecoverFromRejection(agg)]
   Recover component proofs from a rejected aggregation back to the pool.
   This is the operational mechanism for IndependencePreservation (S2):
   valid proofs are never permanently lost due to co-aggregation
   with an invalid proof from another enterprise. *)
Definition RecoverFromRejection (S : PidSet) (v : bool)
    (s s' : State) : Prop :=
  agg_exists s S v L1Rejected /\
  aggregationPool s' = pid_union (aggregationPool s) S /\
  (forall S' v' st', agg_exists s' S' v' st' <->
    (agg_exists s S' v' st' /\
      ~ (S' = S /\ v' = v /\ st' = L1Rejected))) /\
  proofCounter s' = proofCounter s /\
  proofValidity s' = proofValidity s /\
  everSubmitted s' = everSubmitted s.

(* ========================================================================= *)
(*                     NEXT-STATE RELATION                                    *)
(* ========================================================================= *)

(* [TLA+ lines 224-231: Next] *)
Definition Next (s s' : State) : Prop :=
  (exists e, GenerateValidProof e s s') \/
  (exists e, GenerateInvalidProof e s s') \/
  (exists pid, SubmitToPool pid s s') \/
  (exists S, AggregateSubset S s s') \/
  (exists S v, VerifyOnL1 S v s s') \/
  (exists S v, RecoverFromRejection S v s s').

(* ========================================================================= *)
(*                     SAFETY PROPERTIES                                      *)
(* ========================================================================= *)

(* --- S1: AggregationSoundness ---
   [TLA+ lines 248-250]
   The aggregated proof is valid iff ALL component proofs are valid.
   Both directions matter:
     Forward:  all valid => aggregation valid (no false negatives)
     Backward: aggregation valid => all valid (soundness) *)
Definition AggregationSoundness (s : State) : Prop :=
  forall S v st, agg_exists s S v st ->
    v = subset_bool S (proofValidity s).

(* --- S2: IndependencePreservation ---
   [TLA+ lines 262-266]
   A valid proof that has been submitted is never permanently lost.
   It is always in the pool or in some aggregation record. *)
Definition IndependencePreservation (s : State) : Prop :=
  forall pid,
    pid_mem pid (everSubmitted s) ->
    pid_mem pid (proofValidity s) ->
    pid_mem pid (aggregationPool s) \/
    (exists S v st, agg_exists s S v st /\ pid_mem pid S).

(* --- S3: OrderIndependence ---
   [TLA+ lines 279-281]
   The aggregation result is deterministic with respect to the
   component set. Same components => same validity. *)
Definition OrderIndependence (s : State) : Prop :=
  forall S v1 v2 st1 st2,
    agg_exists s S v1 st1 ->
    agg_exists s S v2 st2 ->
    v1 = v2.

(* --- S4: GasMonotonicity ---
   [TLA+ lines 296-298]
   Per-enterprise gas cost strictly decreases with aggregation.
   AggregatedGasCost < BaseGasPerProof * N for all N >= 2. *)
Definition GasMonotonicity (s : State) : Prop :=
  forall S v st, agg_exists s S v st ->
    AggregatedGasCost < BaseGasPerProof * pid_card S.

(* --- S5: SingleLocation ---
   [TLA+ lines 307-313]
   Each proof is in at most one location: either in the aggregation
   pool OR in exactly one aggregation record. Never both. *)
Definition SingleLocation (s : State) : Prop :=
  forall pid,
    (pid_mem pid (aggregationPool s) ->
      forall S v st, agg_exists s S v st -> ~ pid_mem pid S) /\
    (forall S1 v1 st1 S2 v2 st2,
      agg_exists s S1 v1 st1 -> pid_mem pid S1 ->
      agg_exists s S2 v2 st2 -> pid_mem pid S2 ->
      S1 = S2 /\ v1 = v2 /\ st1 = st2).

(* ========================================================================= *)
(*                     STRENGTHENING INVARIANTS                               *)
(* ========================================================================= *)
(* These are auxiliary invariants needed to make the safety properties        *)
(* inductive. They encode structural properties of proof generation          *)
(* and submission that are implicit in the TLA+ counter mechanism.           *)

(* All submitted proofs have sequence <= their enterprise's counter.
   Encodes: proofs are generated before they can be submitted. *)
Definition SubmittedInRange (s : State) : Prop :=
  forall pid,
    pid_mem pid (everSubmitted s) ->
    pid_seq pid <= proofCounter s (pid_ent pid).

(* All components of all aggregations were submitted. *)
Definition ComponentsSubmitted (s : State) : Prop :=
  forall S v st,
    agg_exists s S v st ->
    pid_is_subset S (everSubmitted s).

(* Everything in the pool was submitted. *)
Definition PoolSubmitted (s : State) : Prop :=
  pid_is_subset (aggregationPool s) (everSubmitted s).

(* All aggregations have at least MinAggregationSize components. *)
Definition CardBound (s : State) : Prop :=
  forall S v st,
    agg_exists s S v st ->
    pid_card S >= MinAggregationSize.
