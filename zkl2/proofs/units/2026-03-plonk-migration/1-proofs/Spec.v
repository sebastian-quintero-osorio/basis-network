(* ========================================================================= *)
(* Spec.v -- Faithful Translation of PlonkMigration.tla into Coq            *)
(* ========================================================================= *)
(* Source: 0-input-spec/PlonkMigration.tla                                   *)
(* TLC Evidence: 9,117,756 states, 3,985,171 distinct, depth 22 -- PASS     *)
(*                                                                           *)
(* Translation methodology:                                                  *)
(*   - TLA+ VARIABLES   -> Coq Record fields                                *)
(*   - TLA+ CONSTANTS   -> Coq Parameters / Axioms                          *)
(*   - TLA+ actions     -> Coq Prop relations on (State, State) pairs       *)
(*   - TLA+ Sequences   -> Coq lists                                        *)
(*   - TLA+ EXCEPT      -> Point-wise update equations                      *)
(*   - TLA+ invariants  -> Coq State predicates                             *)
(*                                                                           *)
(* S6 (PhaseConsistency) holds by construction: activeVerifiers is not      *)
(* stored but computed from migrationPhase via ps_accepted.                 *)
(* ========================================================================= *)

From PlonkMigration Require Import Common.
From Stdlib Require Import List Arith PeanoNat Lia Bool.
Import ListNotations.

(* ========================================================================= *)
(*                         PROTOCOL PARAMETERS                               *)
(* ========================================================================= *)

(* [TLA+ lines 10-13] *)
Parameter MaxBatches : nat.
Parameter MaxMigrationSteps : nat.

Axiom max_batches_pos : MaxBatches >= 1.

(* ========================================================================= *)
(*                               STATE                                       *)
(* ========================================================================= *)

(* [TLA+ lines 34-42: VARIABLES]
   Note: activeVerifiers is omitted (derived from migrationPhase via
   ps_accepted). This matches the implementation approach and makes
   S6 PhaseConsistency hold by construction. *)
Record State := mkState {
  migrationPhase     : Phase;
  batchQueue         : Enterprise -> list BatchRecord;
  verifiedBatches    : Enterprise -> list BatchRecord;
  batchCounter       : Enterprise -> nat;
  proofRegistry      : list ProofRecord;
  migrationStepCount : nat;
  failureDetected    : bool;
}.

(* ========================================================================= *)
(*                           INITIAL STATE                                   *)
(* ========================================================================= *)

(* [TLA+ lines 86-94] *)
Definition Init (s : State) : Prop :=
  migrationPhase s = Groth16Only /\
  (forall e, batchQueue s e = nil) /\
  (forall e, verifiedBatches s e = nil) /\
  (forall e, batchCounter s e = 0) /\
  proofRegistry s = nil /\
  migrationStepCount s = 0 /\
  failureDetected s = false.

(* ========================================================================= *)
(*                              ACTIONS                                      *)
(* ========================================================================= *)

(* [TLA+ lines 130-140: SubmitBatch(e, ps)]
   Enterprise e submits a batch with proof system ps.
   Guard: batchCounter < MaxBatches, not in rollback phase. *)
Definition SubmitBatch (e : Enterprise) (ps : ProofSystemId)
    (s s' : State) : Prop :=
  batchCounter s e < MaxBatches /\
  migrationPhase s <> Rollback /\
  batchQueue s' e = batchQueue s e ++ [mkBatch e (S (batchCounter s e)) ps] /\
  (forall e', e' <> e -> batchQueue s' e' = batchQueue s e') /\
  batchCounter s' e = S (batchCounter s e) /\
  (forall e', e' <> e -> batchCounter s' e' = batchCounter s e') /\
  migrationPhase s' = migrationPhase s /\
  verifiedBatches s' = verifiedBatches s /\
  proofRegistry s' = proofRegistry s /\
  migrationStepCount s' = migrationStepCount s /\
  failureDetected s' = failureDetected s.

(* [TLA+ lines 150-162: VerifyBatch(e)]
   Verify the head of enterprise e's queue.
   isValid := batch.proofSystem in activeVerifiers (= ps_accepted).
   Phase-stamp the proof record for temporal invariant checking. *)
Definition VerifyBatch (e : Enterprise) (s s' : State) : Prop :=
  exists batch rest,
    batchQueue s e = batch :: rest /\
    proofRegistry s' =
      mkProofRec batch
        (ps_accepted (batch_proofSystem batch) (migrationPhase s))
        (migrationPhase s)
      :: proofRegistry s /\
    (if ps_accepted (batch_proofSystem batch) (migrationPhase s)
     then verifiedBatches s' e = batch :: verifiedBatches s e
     else verifiedBatches s' e = verifiedBatches s e) /\
    (forall e', e' <> e -> verifiedBatches s' e' = verifiedBatches s e') /\
    batchQueue s' e = rest /\
    (forall e', e' <> e -> batchQueue s' e' = batchQueue s e') /\
    migrationPhase s' = migrationPhase s /\
    batchCounter s' = batchCounter s /\
    migrationStepCount s' = migrationStepCount s /\
    failureDetected s' = failureDetected s.

(* [TLA+ lines 169-175: StartDualVerification]
   Transition: Groth16Only -> Dual. Both verifiers become active. *)
Definition StartDualVerification (s s' : State) : Prop :=
  migrationPhase s = Groth16Only /\
  migrationPhase s' = Dual /\
  migrationStepCount s' = 0 /\
  batchQueue s' = batchQueue s /\
  verifiedBatches s' = verifiedBatches s /\
  batchCounter s' = batchCounter s /\
  proofRegistry s' = proofRegistry s /\
  failureDetected s' = failureDetected s.

(* [TLA+ lines 184-191: CutoverToPlonkOnly]
   Transition: Dual -> PlonkOnly. Requires no failure and empty queues. *)
Definition CutoverToPlonkOnly (s s' : State) : Prop :=
  migrationPhase s = Dual /\
  failureDetected s = false /\
  (forall e, batchQueue s e = nil) /\
  migrationPhase s' = PlonkOnly /\
  batchQueue s' = batchQueue s /\
  verifiedBatches s' = verifiedBatches s /\
  batchCounter s' = batchCounter s /\
  proofRegistry s' = proofRegistry s /\
  migrationStepCount s' = migrationStepCount s /\
  failureDetected s' = failureDetected s.

(* [TLA+ lines 195-200: DualPeriodTick]
   Increment step counter during dual period. *)
Definition DualPeriodTick (s s' : State) : Prop :=
  migrationPhase s = Dual /\
  migrationStepCount s < MaxMigrationSteps /\
  migrationStepCount s' = S (migrationStepCount s) /\
  migrationPhase s' = migrationPhase s /\
  batchQueue s' = batchQueue s /\
  verifiedBatches s' = verifiedBatches s /\
  batchCounter s' = batchCounter s /\
  proofRegistry s' = proofRegistry s /\
  failureDetected s' = failureDetected s.

(* [TLA+ lines 210-215: DetectFailure]
   Flag a critical failure during dual verification. *)
Definition DetectFailure (s s' : State) : Prop :=
  migrationPhase s = Dual /\
  failureDetected s = false /\
  failureDetected s' = true /\
  migrationPhase s' = migrationPhase s /\
  batchQueue s' = batchQueue s /\
  verifiedBatches s' = verifiedBatches s /\
  batchCounter s' = batchCounter s /\
  proofRegistry s' = proofRegistry s /\
  migrationStepCount s' = migrationStepCount s.

(* [TLA+ lines 220-226: RollbackMigration]
   Transition: Dual -> Rollback. Requires failure detected. *)
Definition RollbackMigration (s s' : State) : Prop :=
  migrationPhase s = Dual /\
  failureDetected s = true /\
  migrationPhase s' = Rollback /\
  batchQueue s' = batchQueue s /\
  verifiedBatches s' = verifiedBatches s /\
  batchCounter s' = batchCounter s /\
  proofRegistry s' = proofRegistry s /\
  migrationStepCount s' = migrationStepCount s /\
  failureDetected s' = failureDetected s.

(* [TLA+ lines 230-237: CompleteRollback]
   Transition: Rollback -> Groth16Only. Requires all queues drained. *)
Definition CompleteRollback (s s' : State) : Prop :=
  migrationPhase s = Rollback /\
  (forall e, batchQueue s e = nil) /\
  migrationPhase s' = Groth16Only /\
  failureDetected s' = false /\
  migrationStepCount s' = 0 /\
  batchQueue s' = batchQueue s /\
  verifiedBatches s' = verifiedBatches s /\
  batchCounter s' = batchCounter s /\
  proofRegistry s' = proofRegistry s.

(* ========================================================================= *)
(*                         NEXT-STATE RELATION                               *)
(* ========================================================================= *)

(* [TLA+ lines 243-251] *)
Definition Next (s s' : State) : Prop :=
  (exists e ps, SubmitBatch e ps s s') \/
  (exists e, VerifyBatch e s s') \/
  StartDualVerification s s' \/
  CutoverToPlonkOnly s s' \/
  DualPeriodTick s s' \/
  DetectFailure s s' \/
  RollbackMigration s s' \/
  CompleteRollback s s'.

(* ========================================================================= *)
(*                     SAFETY PROPERTIES                                     *)
(* ========================================================================= *)

(* S1: MigrationSafety [TLA+ lines 265-271]
   No batch lost during migration. Every submitted sequence number
   exists either in the batch queue or in the proof registry. *)
Definition MigrationSafety (s : State) : Prop :=
  forall e n,
    1 <= n -> n <= batchCounter s e ->
    (exists b, In b (batchQueue s e) /\
               batch_enterprise b = e /\ batch_seqNo b = n) \/
    (exists r, In r (proofRegistry s) /\
               batch_enterprise (proof_batch r) = e /\
               batch_seqNo (proof_batch r) = n).

(* S2: BackwardCompatibility [TLA+ lines 278-282]
   Groth16 proofs verified during phases with Groth16 active have
   valid = TRUE. Uses phase stamp for temporal correctness. *)
Definition BackwardCompatibility (s : State) : Prop :=
  forall r,
    In r (proofRegistry s) ->
    batch_proofSystem (proof_batch r) = PSGroth16 ->
    ps_accepted PSGroth16 (proof_phase r) = true ->
    proof_valid r = true.

(* S3: Soundness [TLA+ lines 288-291]
   No false positives. Every batch in verifiedBatches has a
   valid = TRUE record in the proof registry. *)
Definition Soundness (s : State) : Prop :=
  forall e b,
    In b (verifiedBatches s e) ->
    exists r, In r (proofRegistry s) /\
              proof_batch r = b /\ proof_valid r = true.

(* S4: Completeness [TLA+ lines 300-302]
   No false negatives. If a batch's proof system was active at
   verification time, the result is valid = TRUE. *)
Definition Completeness (s : State) : Prop :=
  forall r,
    In r (proofRegistry s) ->
    ps_accepted (batch_proofSystem (proof_batch r)) (proof_phase r) = true ->
    proof_valid r = true.

(* S5: NoGroth16AfterCutover [TLA+ lines 308-311]
   After cutover to PlonkOnly, Groth16 batches are rejected. *)
Definition NoGroth16AfterCutover (s : State) : Prop :=
  forall r,
    In r (proofRegistry s) ->
    batch_proofSystem (proof_batch r) = PSGroth16 ->
    proof_phase r = PlonkOnly ->
    proof_valid r = false.

(* S6: PhaseConsistency [TLA+ lines 317-318]
   Holds by construction: activeVerifiers computed from phase. *)
Definition PhaseConsistency (_ : State) : Prop := True.

(* S7: RollbackOnlyOnFailure [TLA+ lines 323-324] *)
Definition RollbackOnlyOnFailure (s : State) : Prop :=
  migrationPhase s = Rollback -> failureDetected s = true.

(* S8: NoBatchLossDuringRollback [TLA+ lines 331-338]
   Specialization of S1 for rollback phase. *)
Definition NoBatchLossDuringRollback (s : State) : Prop :=
  migrationPhase s = Rollback -> MigrationSafety s.
