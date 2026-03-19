(* ================================================================ *)
(*  Spec.v -- Faithful Translation of CrossEnterprise.tla           *)
(* ================================================================ *)
(*                                                                  *)
(*  Translates the TLA+ formal specification of the Cross-          *)
(*  Enterprise Verification Protocol into Coq. Every definition     *)
(*  is tagged with its source line in the TLA+ file.                *)
(*                                                                  *)
(*  Source: 0-input-spec/CrossEnterprise.tla, lines 1-251           *)
(*  Verified by: TLC model checker (2 enterprises, 2 batches,      *)
(*               2 state roots)                                     *)
(* ================================================================ *)

From CE Require Import Common.
From Stdlib Require Import Arith.Arith.
From Stdlib Require Import Bool.Bool.

(* ======================================== *)
(*     STATE                                *)
(* ======================================== *)

(* [Spec: VARIABLES, lines 41-45] *)
Record State := mkState {
  currentRoot    : Enterprise -> StateRoot;
  batchStatus    : Enterprise -> BatchId -> batch_status;
  batchNewRoot   : Enterprise -> BatchId -> StateRoot;
  crossRefStatus : CrossRefId -> crossref_status;
}.

(* ======================================== *)
(*     INITIAL STATE                        *)
(* ======================================== *)

(* [Spec: Init, lines 63-67]
   All enterprises start with genesis root, all batches idle,
   all batch new roots set to genesis, all cross-refs none. *)
Definition Init : State := mkState
  (fun _ => GenesisRoot)
  (fun _ _ => Idle)
  (fun _ _ => GenesisRoot)
  (fun _ => CRNone).

(* ======================================== *)
(*     ACTION PRECONDITIONS                 *)
(* ======================================== *)

(* [Spec: SubmitBatch guard, lines 78-79]
   Batch must be idle. New root must differ from current root. *)
Definition can_submit (s : State) (e : Enterprise) (b : BatchId)
    (newRoot : StateRoot) : Prop :=
  batchStatus s e b = Idle /\
  newRoot <> currentRoot s e.

(* [Spec: VerifyBatch guard, line 90]
   Batch must be in submitted state. *)
Definition can_verify_batch (s : State) (e : Enterprise)
    (b : BatchId) : Prop :=
  batchStatus s e b = Submitted.

(* [Spec: FailBatch guard, line 99]
   Batch must be in submitted state. *)
Definition can_fail_batch (s : State) (e : Enterprise)
    (b : BatchId) : Prop :=
  batchStatus s e b = Submitted.

(* [Spec: RequestCrossRef guard, lines 117-120]
   Valid ref (src # dst), status = none, both batches active. *)
Definition can_request_crossref (s : State) (ref : CrossRefId) : Prop :=
  valid_ref ref /\
  crossRefStatus s ref = CRNone /\
  (batchStatus s (cr_src ref) (cr_srcBatch ref) = Submitted \/
   batchStatus s (cr_src ref) (cr_srcBatch ref) = Verified) /\
  (batchStatus s (cr_dst ref) (cr_dstBatch ref) = Submitted \/
   batchStatus s (cr_dst ref) (cr_dstBatch ref) = Verified).

(* [Spec: VerifyCrossRef guard, lines 145-148]
   Valid ref, status = pending, BOTH batches verified.
   This is the CONSISTENCY GATE. *)
Definition can_verify_crossref (s : State) (ref : CrossRefId) : Prop :=
  valid_ref ref /\
  crossRefStatus s ref = CRPending /\
  batchStatus s (cr_src ref) (cr_srcBatch ref) = Verified /\
  batchStatus s (cr_dst ref) (cr_dstBatch ref) = Verified.

(* [Spec: RejectCrossRef guard, lines 162-164]
   Valid ref, status = pending, at least one batch NOT verified. *)
Definition can_reject_crossref (s : State) (ref : CrossRefId) : Prop :=
  valid_ref ref /\
  crossRefStatus s ref = CRPending /\
  (batchStatus s (cr_src ref) (cr_srcBatch ref) <> Verified \/
   batchStatus s (cr_dst ref) (cr_dstBatch ref) <> Verified).

(* ======================================== *)
(*     ACTIONS                              *)
(* ======================================== *)

(* [Spec: SubmitBatch, lines 77-82]
   idle -> submitted. Record claimed new root.
   UNCHANGED << currentRoot, crossRefStatus >> *)
Definition SubmitBatch (s : State) (e : Enterprise) (b : BatchId)
    (newRoot : StateRoot) : State :=
  mkState
    (currentRoot s)
    (fupdate2 (batchStatus s) e b Submitted)
    (fupdate2 (batchNewRoot s) e b newRoot)
    (crossRefStatus s).

(* [Spec: VerifyBatch, lines 89-93]
   submitted -> verified. Advance enterprise state root.
   UNCHANGED << batchNewRoot, crossRefStatus >> *)
Definition VerifyBatch (s : State) (e : Enterprise) (b : BatchId) : State :=
  mkState
    (fupdate1 (currentRoot s) e (batchNewRoot s e b))
    (fupdate2 (batchStatus s) e b Verified)
    (batchNewRoot s)
    (crossRefStatus s).

(* [Spec: FailBatch, lines 98-101]
   submitted -> idle.
   UNCHANGED << currentRoot, batchNewRoot, crossRefStatus >> *)
Definition FailBatch (s : State) (e : Enterprise) (b : BatchId) : State :=
  mkState
    (currentRoot s)
    (fupdate2 (batchStatus s) e b Idle)
    (batchNewRoot s)
    (crossRefStatus s).

(* [Spec: RequestCrossRef, lines 113-122]
   none -> pending.
   UNCHANGED << currentRoot, batchStatus, batchNewRoot >> *)
Definition RequestCrossRef (s : State) (ref : CrossRefId) : State :=
  mkState
    (currentRoot s)
    (batchStatus s)
    (batchNewRoot s)
    (fupdate_cr (crossRefStatus s) ref CRPending).

(* [Spec: VerifyCrossRef, lines 140-151]
   pending -> verified.
   ISOLATION: UNCHANGED << currentRoot, batchStatus, batchNewRoot >> *)
Definition VerifyCrossRef (s : State) (ref : CrossRefId) : State :=
  mkState
    (currentRoot s)
    (batchStatus s)
    (batchNewRoot s)
    (fupdate_cr (crossRefStatus s) ref CRVerified).

(* [Spec: RejectCrossRef, lines 157-166]
   pending -> rejected.
   UNCHANGED << currentRoot, batchStatus, batchNewRoot >> *)
Definition RejectCrossRef (s : State) (ref : CrossRefId) : State :=
  mkState
    (currentRoot s)
    (batchStatus s)
    (batchNewRoot s)
    (fupdate_cr (crossRefStatus s) ref CRRejected).

(* ======================================== *)
(*     NEXT-STATE RELATION                  *)
(* ======================================== *)

(* [Spec: Next, lines 172-184] *)
Inductive Step : State -> State -> Prop :=
  | step_submit : forall s e b r,
      can_submit s e b r ->
      Step s (SubmitBatch s e b r)
  | step_verify_batch : forall s e b,
      can_verify_batch s e b ->
      Step s (VerifyBatch s e b)
  | step_fail_batch : forall s e b,
      can_fail_batch s e b ->
      Step s (FailBatch s e b)
  | step_request_crossref : forall s ref,
      can_request_crossref s ref ->
      Step s (RequestCrossRef s ref)
  | step_verify_crossref : forall s ref,
      can_verify_crossref s ref ->
      Step s (VerifyCrossRef s ref)
  | step_reject_crossref : forall s ref,
      can_reject_crossref s ref ->
      Step s (RejectCrossRef s ref).

(* ======================================== *)
(*     SAFETY PROPERTIES                    *)
(* ======================================== *)

(* [Spec: Isolation, lines 213-218]
   Each enterprise's state root is determined solely by its own verified
   batches. No cross-enterprise action can modify another enterprise's
   state root. This simultaneously guarantees proof-before-state:
   state roots advance only through verified ZK proofs.
   [Source: 0-input/REPORT.md, "Privacy Analysis"] *)
Definition Isolation (s : State) : Prop :=
  forall e : Enterprise,
    currentRoot s e = GenesisRoot \/
    exists b : BatchId,
      batchStatus s e b = Verified /\
      batchNewRoot s e b = currentRoot s e.

(* [Spec: Consistency, lines 225-229]
   A cross-reference is verified ONLY when both constituent enterprise
   proofs have been independently verified on L1. Prevents accepting
   cross-enterprise interactions based on unverified or fraudulent state.
   [Source: 0-input/REPORT.md, "valid only if both proofs valid"] *)
Definition Consistency (s : State) : Prop :=
  forall ref : CrossRefId,
    crossRefStatus s ref = CRVerified ->
    batchStatus s (cr_src ref) (cr_srcBatch ref) = Verified /\
    batchStatus s (cr_dst ref) (cr_dstBatch ref) = Verified.

(* [Spec: NoCrossRefSelfLoop, lines 234-235]
   Any cross-reference that has entered the protocol (status != none)
   must have distinct source and destination enterprises.
   Structurally enforced by CrossRefIds construction (src # dst). *)
Definition NoCrossRefSelfLoop (s : State) : Prop :=
  forall ref : CrossRefId,
    crossRefStatus s ref <> CRNone ->
    valid_ref ref.
