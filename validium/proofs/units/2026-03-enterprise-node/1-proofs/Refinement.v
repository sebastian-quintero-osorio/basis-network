(* ================================================================ *)
(*  Refinement.v -- Safety and Liveness Proofs                       *)
(* ================================================================ *)
(*                                                                  *)
(*  Proves that the Enterprise Node implementation (orchestrator.ts) *)
(*  correctly implements the TLA+ specification (EnterpriseNode.tla) *)
(*  with respect to key safety and liveness properties.              *)
(*                                                                  *)
(*  Structure:                                                      *)
(*    Part 1: Initial State Refinement                              *)
(*    Part 2: Safety Invariant Preservation (12 action lemmas)      *)
(*    Part 3: Main Safety Theorem (inductive invariant)             *)
(*    Part 4: ProofStateIntegrity Corollary                         *)
(*    Part 5: Impl Safety (composed operations)                     *)
(*    Part 6: Liveness Progress Lemma                               *)
(*                                                                  *)
(*  Axiom Trust Base (from Common.v):                               *)
(*    - batch_threshold_pos: BatchThreshold > 0                     *)
(*                                                                  *)
(*  Source Spec: 0-input-spec/EnterpriseNode.tla                    *)
(*  Source Impl: 0-input-impl/orchestrator.ts                       *)
(* ================================================================ *)

From EN Require Import Common.
From EN Require Import Spec.
From EN Require Import Impl.
From Stdlib Require Import Lists.List.
From Stdlib Require Import Bool.Bool.
From Stdlib Require Import Lia.

Import ListNotations.

(* ================================================================ *)
(*  PART 1: INITIAL STATE REFINEMENT                                *)
(* ================================================================ *)

(* Theorem: The initial state satisfies the safety invariant.
   All three components (SRC, PSI, NDL) hold at initialization.

   Proof strategy: Direct computation. smtState = l1State = empty_txset
   by definition. dataExposed = dk_empty which is subset of anything.
   nodeState = Idle, so PSI is vacuously True. *)
Theorem init_safety : Spec.SafetyInv Spec.init_state.
Proof.
  unfold Spec.SafetyInv, Spec.SRC, Spec.PSI, Spec.NDL, Spec.init_state.
  simpl. split; [| split].
  - reflexivity.
  - exact I.
  - apply dk_empty_subset.
Qed.

(* Theorem: Impl initial state maps to Spec initial state. *)
Theorem init_refinement :
  Impl.map_state Spec.init_state = Spec.init_state.
Proof.
  unfold Impl.map_state. reflexivity.
Qed.

(* ================================================================ *)
(*  PART 2: SAFETY INVARIANT PRESERVATION                           *)
(* ================================================================ *)

(* Each action in the TLA+ Next relation preserves SafetyInv.
   We prove a separate lemma for each of the 12 actions.

   Proof pattern:
   1. Destruct SafetyInv into SRC, PSI, NDL hypotheses
   2. Extract nodeState info from precondition
   3. Unfold hypotheses and rewrite with nodeState
   4. Split goal into 3 components and solve each *)

(* -- ReceiveTx -------------------------------------------------- *)
(* [TLA: ReceiveTx(tx), lines 145-153]
   Pipelined ingestion: Idle -> Receiving or unchanged state.
   smtState, l1State, batchTxs, batchPrevSmt, dataExposed all unchanged. *)
Lemma safe_receive_tx : forall s tx,
    Spec.SafetyInv s ->
    Spec.receive_tx_pre s tx ->
    Spec.SafetyInv (Spec.receive_tx s tx).
Proof.
  intros s tx [Hsrc [Hpsi Hndl]] [Hpend Hns].
  unfold Spec.SRC in Hsrc. unfold Spec.PSI in Hpsi.
  unfold Spec.SafetyInv. split; [| split].
  - (* SRC *)
    unfold Spec.SRC, Spec.receive_tx. simpl.
    destruct (NodeState_eq_dec (Spec.nodeState s) Idle) as [Heq | Hneq]; simpl.
    + rewrite Heq in Hsrc. simpl in Hsrc. exact Hsrc.
    + destruct Hns as [Hn | [Hn | [Hn | Hn]]]; try congruence;
      rewrite Hn in Hsrc; rewrite Hn; simpl in *; exact Hsrc.
  - (* PSI *)
    unfold Spec.PSI, Spec.receive_tx. simpl.
    destruct (NodeState_eq_dec (Spec.nodeState s) Idle) as [Heq | Hneq]; simpl.
    + exact I.
    + destruct Hns as [Hn | [Hn | [Hn | Hn]]]; try congruence;
      rewrite Hn in Hpsi; rewrite Hn; simpl in *; exact Hpsi.
  - (* NDL *)
    unfold Spec.NDL, Spec.receive_tx. simpl. exact Hndl.
Qed.

(* -- CheckQueue -------------------------------------------------- *)
(* [TLA: CheckQueue, lines 160-166]
   Idle -> Receiving. All relevant fields unchanged. *)
Lemma safe_check_queue : forall s,
    Spec.SafetyInv s ->
    Spec.check_queue_pre s ->
    Spec.SafetyInv (Spec.check_queue s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] [Hns _].
  unfold Spec.SRC in Hsrc. rewrite Hns in Hsrc. simpl in Hsrc.
  unfold Spec.SafetyInv. split; [| split].
  - unfold Spec.SRC, Spec.check_queue. simpl. exact Hsrc.
  - unfold Spec.PSI, Spec.check_queue. simpl. exact I.
  - unfold Spec.NDL, Spec.check_queue. simpl. exact Hndl.
Qed.

(* -- FormBatch --------------------------------------------------- *)
(* [TLA: FormBatch, lines 178-192]
   Receiving -> Batching. batchPrevSmt := smtState.
   Key: by SRC(Receiving), smtState = l1State,
   so batchPrevSmt = l1State (establishes PSI for Batching). *)
Lemma safe_form_batch : forall s,
    Spec.SafetyInv s ->
    Spec.form_batch_pre s ->
    Spec.SafetyInv (Spec.form_batch s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] [Hns _].
  unfold Spec.SRC in Hsrc. rewrite Hns in Hsrc. simpl in Hsrc.
  (* Hsrc : smtState s = l1State s *)
  unfold Spec.SafetyInv. split; [| split].
  - unfold Spec.SRC, Spec.form_batch. simpl. exact Hsrc.
  - (* PSI: batchPrevSmt := smtState s, and smtState s = l1State s *)
    unfold Spec.PSI, Spec.form_batch. simpl. exact Hsrc.
  - unfold Spec.NDL, Spec.form_batch. simpl. exact Hndl.
Qed.

(* -- GenerateWitness --------------------------------------------- *)
(* [TLA: GenerateWitness, lines 201-207]
   Batching -> Proving. smtState' = smtState \cup BatchTxSet.
   Key transition from idle group to active group.
   Uses SRC(Batching): smtState = l1State to establish
   SRC(Proving): smtState' = set_union l1State batchTxs. *)
Lemma safe_gen_witness : forall s,
    Spec.SafetyInv s ->
    Spec.gen_witness_pre s ->
    Spec.SafetyInv (Spec.gen_witness s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] [Hns _].
  unfold Spec.SRC in Hsrc. unfold Spec.PSI in Hpsi.
  rewrite Hns in *. simpl in *.
  (* Hsrc : smtState s = l1State s *)
  (* Hpsi : batchPrevSmt s = l1State s *)
  unfold Spec.SafetyInv. split; [| split].
  - (* SRC: set_union smtState batchTxs = set_union l1State batchTxs *)
    unfold Spec.SRC, Spec.gen_witness. simpl.
    rewrite Hsrc. reflexivity.
  - unfold Spec.PSI, Spec.gen_witness. simpl. exact Hpsi.
  - unfold Spec.NDL, Spec.gen_witness. simpl. exact Hndl.
Qed.

(* -- GenerateProof ----------------------------------------------- *)
(* [TLA: GenerateProof, lines 216-221]
   Proving -> Submitting. No field changes except nodeState.
   SRC and PSI transfer directly from Proving to Submitting. *)
Lemma safe_gen_proof : forall s,
    Spec.SafetyInv s ->
    Spec.gen_proof_pre s ->
    Spec.SafetyInv (Spec.gen_proof s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] Hns.
  unfold Spec.gen_proof_pre in Hns.
  unfold Spec.SRC in Hsrc. unfold Spec.PSI in Hpsi.
  rewrite Hns in *. simpl in *.
  unfold Spec.SafetyInv. split; [| split].
  - unfold Spec.SRC, Spec.gen_proof. simpl. exact Hsrc.
  - unfold Spec.PSI, Spec.gen_proof. simpl. exact Hpsi.
  - unfold Spec.NDL, Spec.gen_proof. simpl. exact Hndl.
Qed.

(* -- SubmitBatch ------------------------------------------------- *)
(* [TLA: SubmitBatch, lines 230-235]
   Stays Submitting. Only dataExposed grows by {proof_signals, dac_shares}.
   NDL preserved because both categories are in AllowedExternalData. *)
Lemma safe_submit_batch : forall s,
    Spec.SafetyInv s ->
    Spec.submit_batch_pre s ->
    Spec.SafetyInv (Spec.submit_batch s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] Hns.
  unfold Spec.submit_batch_pre in Hns.
  unfold Spec.SRC in Hsrc. unfold Spec.PSI in Hpsi.
  rewrite Hns in *. simpl in *.
  unfold Spec.SafetyInv. split; [| split].
  - unfold Spec.SRC, Spec.submit_batch. simpl.
    rewrite Hns. simpl. exact Hsrc.
  - unfold Spec.PSI, Spec.submit_batch. simpl.
    rewrite Hns. simpl. exact Hpsi.
  - unfold Spec.NDL, Spec.submit_batch. simpl.
    apply dk_add_ps_dac_subset. exact Hndl.
Qed.

(* -- ConfirmBatch ------------------------------------------------ *)
(* [TLA: ConfirmBatch, lines 248-256]
   Submitting -> Idle. l1State' := smtState. Batch cleared.
   Key: smtState unchanged, l1State := smtState, so both equal.
   SRC(Idle): smtState = l1State holds by construction. *)
Lemma safe_confirm_batch : forall s,
    Spec.SafetyInv s ->
    Spec.confirm_batch_pre s ->
    Spec.SafetyInv (Spec.confirm_batch s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] Hns.
  unfold Spec.SafetyInv. split; [| split].
  - unfold Spec.SRC, Spec.confirm_batch. simpl. reflexivity.
  - unfold Spec.PSI, Spec.confirm_batch. simpl. exact I.
  - unfold Spec.NDL, Spec.confirm_batch. simpl. exact Hndl.
Qed.

(* -- Crash ------------------------------------------------------- *)
(* [TLA: Crash, lines 263-273]
   {Receiving,Batching,Proving,Submitting} -> Error.
   smtState' := l1State. Both smtState and l1State point to l1State s.
   SRC(Error): smtState = l1State by construction. *)
Lemma safe_crash : forall s,
    Spec.SafetyInv s ->
    Spec.crash_pre s ->
    Spec.SafetyInv (Spec.crash s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] [Hns _].
  unfold Spec.SafetyInv. split; [| split].
  - unfold Spec.SRC, Spec.crash. simpl. reflexivity.
  - unfold Spec.PSI, Spec.crash. simpl. exact I.
  - unfold Spec.NDL, Spec.crash. simpl. exact Hndl.
Qed.

(* -- L1Reject ---------------------------------------------------- *)
(* [TLA: L1Reject, lines 279-288]
   Submitting -> Error. Same pattern as Crash: smtState := l1State. *)
Lemma safe_l1_reject : forall s,
    Spec.SafetyInv s ->
    Spec.l1_reject_pre s ->
    Spec.SafetyInv (Spec.l1_reject s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] Hns.
  unfold Spec.SafetyInv. split; [| split].
  - unfold Spec.SRC, Spec.l1_reject. simpl. reflexivity.
  - unfold Spec.PSI, Spec.l1_reject. simpl. exact I.
  - unfold Spec.NDL, Spec.l1_reject. simpl. exact Hndl.
Qed.

(* -- Retry ------------------------------------------------------- *)
(* [TLA: Retry, lines 296-302]
   Error -> Idle. smtState' := l1State (restore from checkpoint).
   SRC(Idle): smtState = l1State by construction. *)
Lemma safe_retry : forall s,
    Spec.SafetyInv s ->
    Spec.retry_pre s ->
    Spec.SafetyInv (Spec.retry s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] Hns.
  unfold Spec.SafetyInv. split; [| split].
  - unfold Spec.SRC, Spec.retry. simpl. reflexivity.
  - unfold Spec.PSI, Spec.retry. simpl. exact I.
  - unfold Spec.NDL, Spec.retry. simpl. exact Hndl.
Qed.

(* -- TimerTick --------------------------------------------------- *)
(* [TLA: TimerTick, lines 309-316]
   Stays Receiving. Only timerExpired changes to true. *)
Lemma safe_timer_tick : forall s,
    Spec.SafetyInv s ->
    Spec.timer_tick_pre s ->
    Spec.SafetyInv (Spec.timer_tick s).
Proof.
  intros s [Hsrc [Hpsi Hndl]] [Hns _].
  unfold Spec.SRC in Hsrc. rewrite Hns in Hsrc. simpl in Hsrc.
  unfold Spec.SafetyInv. split; [| split].
  - unfold Spec.SRC, Spec.timer_tick. simpl.
    rewrite Hns. simpl. exact Hsrc.
  - unfold Spec.PSI, Spec.timer_tick. simpl.
    rewrite Hns. simpl. exact I.
  - unfold Spec.NDL, Spec.timer_tick. simpl. exact Hndl.
Qed.

(* -- Done -------------------------------------------------------- *)
(* [TLA: Done, lines 321-326]
   Stuttering step: state unchanged. Trivially preserves everything. *)
Lemma safe_done : forall s,
    Spec.SafetyInv s ->
    Spec.done_pre s ->
    Spec.SafetyInv (Spec.done s).
Proof.
  intros s Hinv _. unfold Spec.done. exact Hinv.
Qed.

(* ================================================================ *)
(*  PART 3: MAIN SAFETY THEOREM                                    *)
(* ================================================================ *)

(* Theorem: SafetyInv is an inductive invariant of the specification.
   Init establishes it, and every Next step preserves it.

   [TLA: TypeOK /\ StateRootContinuity /\ ProofStateIntegrity /\
         NoDataLeakage are inductive invariants]

   Proof strategy: Case analysis on the step relation.
   Each case dispatches to the corresponding action lemma. *)
Theorem safety_preserved : forall s s',
    Spec.SafetyInv s -> Spec.step s s' -> Spec.SafetyInv s'.
Proof.
  intros s s' Hinv Hstep.
  inversion Hstep; subst;
    eauto using safe_receive_tx, safe_check_queue, safe_form_batch,
                safe_gen_witness, safe_gen_proof, safe_submit_batch,
                safe_confirm_batch, safe_crash, safe_l1_reject,
                safe_retry, safe_timer_tick, safe_done.
Qed.

(* Corollary: SafetyInv holds for all reachable states.
   A state is reachable from init_state by a finite sequence of steps. *)
Inductive reachable : Spec.State -> Prop :=
  | reach_init : reachable Spec.init_state
  | reach_step : forall s s',
      reachable s -> Spec.step s s' -> reachable s'.

Theorem safety_reachable : forall s,
    reachable s -> Spec.SafetyInv s.
Proof.
  intros s Hreach.
  induction Hreach.
  - exact init_safety.
  - exact (safety_preserved s s' IHHreach H).
Qed.

(* ================================================================ *)
(*  PART 4: PROOF-STATE INTEGRITY COROLLARY                         *)
(* ================================================================ *)

(* Theorem: INV-NO2 -- Proof-State Root Integrity.
   When the node is in Submitting state (about to send proof to L1),
   the batch's recorded previous state root (batchPrevSmt) matches
   the last confirmed state on L1 (l1State).

   This guarantees: the ZK proof's public signal prevRoot, derived
   from batchPrevSmt, is consistent with the on-chain state. The L1
   StateCommitment contract verifies submittedPrevRoot == lastConfirmedRoot.

   [TLA: ProofStateIntegrity, lines 390-391]
   [Impl: orchestrator.ts, buildBatchCircuitInput witness.prevStateRoot]

   Proof strategy: Extract from SafetyInv.PSI. In Submitting state,
   the strengthened PSI gives batchPrevSmt = l1State directly. *)
Theorem proof_state_integrity : forall s,
    Spec.SafetyInv s ->
    Spec.ProofStateIntegrity s.
Proof.
  intros s [_ [Hpsi _]].
  unfold Spec.ProofStateIntegrity.
  intro Hns.
  unfold Spec.PSI in Hpsi.
  rewrite Hns in Hpsi. simpl in Hpsi.
  exact Hpsi.
Qed.

(* Stronger version: for all reachable states. *)
Corollary proof_state_integrity_reachable : forall s,
    reachable s ->
    Spec.ProofStateIntegrity s.
Proof.
  intros s Hreach.
  exact (proof_state_integrity s (safety_reachable s Hreach)).
Qed.

(* Theorem: State Root Continuity for all reachable states.
   The SMT state is always consistent with the node's processing phase.

   [TLA: StateRootContinuity, lines 429-433] *)
Theorem state_root_continuity : forall s,
    reachable s -> Spec.SRC s.
Proof.
  intros s Hreach.
  destruct (safety_reachable s Hreach) as [Hsrc _].
  exact Hsrc.
Qed.

(* Theorem: No Data Leakage for all reachable states.
   Raw enterprise data never exits the node boundary.

   [TLA: NoDataLeakage, lines 400-401] *)
Theorem no_data_leakage : forall s,
    reachable s -> Spec.NDL s.
Proof.
  intros s Hreach.
  destruct (safety_reachable s Hreach) as [_ [_ Hndl]].
  exact Hndl.
Qed.

(* ================================================================ *)
(*  PART 5: IMPLEMENTATION SAFETY                                   *)
(* ================================================================ *)

(* The implementation step relation is coarser: each impl step
   corresponds to a composition of spec steps. Since SafetyInv
   is preserved by each spec step, it is preserved by compositions.

   We prove this for the key composed operations. *)

(* Lemma: batch_cycle preserves SafetyInv.
   batch_cycle = confirm . submit . gen_proof . gen_witness . form_batch

   Requires intermediate preconditions (they follow from the
   action definitions given form_batch_pre). *)
Lemma safe_batch_cycle : forall s,
    Spec.SafetyInv s ->
    Spec.form_batch_pre s ->
    Spec.gen_witness_pre (Spec.form_batch s) ->
    Spec.gen_proof_pre (Spec.gen_witness (Spec.form_batch s)) ->
    Spec.submit_batch_pre
      (Spec.gen_proof (Spec.gen_witness (Spec.form_batch s))) ->
    Spec.confirm_batch_pre
      (Spec.submit_batch
        (Spec.gen_proof (Spec.gen_witness (Spec.form_batch s)))) ->
    Spec.SafetyInv (Impl.batch_cycle s).
Proof.
  intros s Hinv Hfb Hgw Hgp Hsb Hcb.
  unfold Impl.batch_cycle.
  apply safe_confirm_batch; [| exact Hcb].
  apply safe_submit_batch; [| exact Hsb].
  apply safe_gen_proof; [| exact Hgp].
  apply safe_gen_witness; [| exact Hgw].
  apply safe_form_batch; [exact Hinv | exact Hfb].
Qed.

(* Lemma: handle_error (crash + retry) preserves SafetyInv. *)
Lemma safe_handle_error : forall s,
    Spec.SafetyInv s ->
    Spec.crash_pre s ->
    Spec.retry_pre (Spec.crash s) ->
    Spec.SafetyInv (Impl.handle_error s).
Proof.
  intros s Hinv Hcrash Hretry.
  unfold Impl.handle_error.
  apply safe_retry; [| exact Hretry].
  apply safe_crash; [exact Hinv | exact Hcrash].
Qed.

(* Lemma: handle_l1_reject (l1_reject + retry) preserves SafetyInv. *)
Lemma safe_handle_l1_reject : forall s,
    Spec.SafetyInv s ->
    Spec.l1_reject_pre s ->
    Spec.retry_pre (Spec.l1_reject s) ->
    Spec.SafetyInv (Impl.handle_l1_reject s).
Proof.
  intros s Hinv Hrej Hretry.
  unfold Impl.handle_l1_reject.
  apply safe_retry; [| exact Hretry].
  apply safe_l1_reject; [exact Hinv | exact Hrej].
Qed.

(* ================================================================ *)
(*  PART 6: LIVENESS PROGRESS LEMMA                                 *)
(* ================================================================ *)

(* Liveness property: EventualConfirmation.
   [TLA: <>(\A tx \in AllTxs : tx \in l1State), line 464]

   Full temporal logic proof requires trace semantics and fairness
   infrastructure beyond standard Coq. We prove the KEY progress
   lemma: each confirmed batch strictly extends l1State.

   Progress argument:
   1. ConfirmBatch sets l1State' = smtState
   2. By SRC(Submitting): smtState = l1State \cup BatchTxSet
   3. So l1State' = l1State \cup BatchTxSet (strictly larger if batch non-empty)
   4. Under fairness, pending txs are eventually received and batched
   5. Since |AllTxs| is finite and each cycle confirms >= 1 tx,
      eventually l1State = AllTxs *)

(* Theorem: After ConfirmBatch, l1State includes all batch transactions.
   This is the core progress step for liveness. *)
Theorem confirm_extends_l1 : forall s,
    Spec.SafetyInv s ->
    Spec.confirm_batch_pre s ->
    forall tx, In tx (Spec.batchTxs s) ->
    Spec.l1State (Spec.confirm_batch s) tx.
Proof.
  intros s [Hsrc [Hpsi Hndl]] Hns tx Hin.
  unfold Spec.confirm_batch. simpl.
  (* l1State (confirm_batch s) = smtState s *)
  unfold Spec.SRC in Hsrc. unfold Spec.confirm_batch_pre in Hns.
  rewrite Hns in Hsrc. simpl in Hsrc.
  (* Hsrc : smtState s = set_union (l1State s) (list_to_set (batchTxs s)) *)
  rewrite Hsrc.
  unfold set_union, list_to_set.
  right. exact Hin.
Qed.

(* Theorem: After ConfirmBatch, l1State retains all previously
   confirmed transactions (monotonicity of confirmation). *)
Theorem confirm_preserves_l1 : forall s,
    Spec.SafetyInv s ->
    Spec.confirm_batch_pre s ->
    forall tx, Spec.l1State s tx ->
    Spec.l1State (Spec.confirm_batch s) tx.
Proof.
  intros s [Hsrc [Hpsi Hndl]] Hns tx Hl1.
  unfold Spec.confirm_batch. simpl.
  unfold Spec.SRC in Hsrc. unfold Spec.confirm_batch_pre in Hns.
  rewrite Hns in Hsrc. simpl in Hsrc.
  rewrite Hsrc. unfold set_union, list_to_set.
  left. exact Hl1.
Qed.

(* ================================================================ *)
(*  SUMMARY OF VERIFIED THEOREMS                                    *)
(* ================================================================ *)

(* 1. init_safety:
      SafetyInv holds for the initial state.
      STATUS: PROVED (Qed)

   2. init_refinement:
      Impl initial state maps to Spec initial state (identity).
      STATUS: PROVED (Qed)

   3. safety_preserved:
      SafetyInv is preserved by every Spec.step action.
      STATUS: PROVED (Qed)
      Sub-lemmas: safe_receive_tx, safe_check_queue, safe_form_batch,
        safe_gen_witness, safe_gen_proof, safe_submit_batch,
        safe_confirm_batch, safe_crash, safe_l1_reject, safe_retry,
        safe_timer_tick, safe_done -- all PROVED (Qed).

   4. safety_reachable:
      SafetyInv holds for all reachable states (induction on traces).
      STATUS: PROVED (Qed)

   5. proof_state_integrity:
      INV-NO2: Submitting -> batchPrevSmt = l1State.
      STATUS: PROVED (Qed)

   6. proof_state_integrity_reachable:
      INV-NO2 for all reachable states.
      STATUS: PROVED (Qed)

   7. state_root_continuity:
      INV-NO5: SRC for all reachable states.
      STATUS: PROVED (Qed)

   8. no_data_leakage:
      INV-NO3: NDL for all reachable states.
      STATUS: PROVED (Qed)

   9. safe_batch_cycle:
      Impl.batch_cycle preserves SafetyInv (with preconditions).
      STATUS: PROVED (Qed)

   10. safe_handle_error:
       Impl.handle_error preserves SafetyInv (with preconditions).
       STATUS: PROVED (Qed)

   11. safe_handle_l1_reject:
       Impl.handle_l1_reject preserves SafetyInv (with preconditions).
       STATUS: PROVED (Qed)

   12. confirm_extends_l1:
       ConfirmBatch adds batch txs to l1State (liveness progress).
       STATUS: PROVED (Qed)

   13. confirm_preserves_l1:
       ConfirmBatch preserves existing l1State (monotonicity).
       STATUS: PROVED (Qed)

   AXIOM TRUST BASE:
   - batch_threshold_pos: BatchThreshold > 0

   PRECONDITIONS:
   - Action preconditions match TLA+ enabling conditions exactly
   - Impl composed operations require intermediate preconditions *)
