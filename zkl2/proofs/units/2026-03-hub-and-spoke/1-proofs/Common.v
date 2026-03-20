(* ========================================== *)
(*     Common.v -- Standard Library            *)
(*     HubAndSpoke Verification Unit           *)
(*     zkl2/proofs/units/2026-03-hub-and-spoke *)
(* ========================================== *)

(* Shared types, map utilities, and tactics for the Hub-and-Spoke
   cross-enterprise protocol verification.

   Source: HubAndSpoke.tla, hub.go, spoke.go, BasisHub.sol *)

From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
From Stdlib Require Import List.
Import ListNotations.

(* ========================================== *)
(*     ABSTRACT TYPES                          *)
(* ========================================== *)

(* Enterprise identifier. Nat for decidable equality.
   [Source: HubAndSpoke.tla, line 10 -- Enterprises]
   [Source: hub.go -- common.Address]
   [Source: BasisHub.sol -- address] *)
Definition Enterprise := nat.

(* ========================================== *)
(*     MESSAGE STATUS                          *)
(* ========================================== *)

(* Cross-enterprise message lifecycle status.
   [Source: HubAndSpoke.tla, lines 31-32 -- MsgStatuses]
   [Source: BasisHub.sol, lines 38-46 -- MessageStatus enum] *)
Inductive MsgStatus :=
  | Prepared
  | HubVerified
  | Responded
  | Settled
  | TimedOut
  | Failed.

(* Terminal: no further transitions.
   [Source: HubAndSpoke.tla, line 35 -- TerminalStatuses] *)
Definition is_terminal (s : MsgStatus) : bool :=
  match s with Settled | TimedOut | Failed => true | _ => false end.

(* Post-verification: passed hub verification gate.
   [Source: HubAndSpoke.tla, lines 519-520] *)
Definition is_post_verified (s : MsgStatus) : bool :=
  match s with HubVerified | Responded | Settled => true | _ => false end.

(* ========================================== *)
(*     MESSAGE RECORD                          *)
(* ========================================== *)

(* CRITICAL (Isolation -- INV-CE5): This record carries ONLY public
   metadata. No field for private enterprise data. Proof validity is
   boolean (1-bit). Root versions are public L1 state.

   [Source: HubAndSpoke.tla, lines 70-90]
   [Source: BasisHub.sol, lines 63-75] *)
Record Message := mkMsg {
  msg_source        : Enterprise;
  msg_dest          : Enterprise;
  msg_nonce         : nat;
  msg_srcProofValid : bool;
  msg_dstProofValid : bool;
  msg_srcRootVer    : nat;
  msg_dstRootVer    : nat;
  msg_status        : MsgStatus;
  msg_createdAt     : nat;
}.

(* Update status, preserving all other fields. *)
Definition set_status (m : Message) (s : MsgStatus) : Message :=
  mkMsg (msg_source m) (msg_dest m) (msg_nonce m)
    (msg_srcProofValid m) (msg_dstProofValid m)
    (msg_srcRootVer m) (msg_dstRootVer m) s (msg_createdAt m).

(* Record response: update destProofValid, destRootVer, status.
   [Source: HubAndSpoke.tla, lines 251-256] *)
Definition set_response (m : Message) (dpv : bool) (drv : nat) : Message :=
  mkMsg (msg_source m) (msg_dest m) (msg_nonce m)
    (msg_srcProofValid m) dpv
    (msg_srcRootVer m) drv Responded (msg_createdAt m).

(* ========================================== *)
(*     FUNCTIONAL MAP: 1-KEY                   *)
(* ========================================== *)

(* Pointwise update of a function at a single key.
   Models TLA+ [f EXCEPT ![k] = v].
   [Source: BasisBridge.tla -- EXCEPT operator] *)
Definition update_map {A : Type} (f : nat -> A) (k : nat) (v : A) : nat -> A :=
  fun n => if Nat.eqb n k then v else f n.

Lemma update_map_eq : forall (A : Type) (f : nat -> A) k v,
  update_map f k v k = v.
Proof. intros. unfold update_map. rewrite Nat.eqb_refl. reflexivity. Qed.

Lemma update_map_neq : forall (A : Type) (f : nat -> A) k v n,
  n <> k -> update_map f k v n = f n.
Proof.
  intros. unfold update_map.
  destruct (Nat.eqb_spec n k); [contradiction | reflexivity].
Qed.

(* ========================================== *)
(*     FUNCTIONAL MAP: 3-KEY                   *)
(* ========================================== *)

(* For message store and nonce tracking: f(src, dst, nonce).
   Models the TLA+ message set indexed by (source, dest, nonce) triples
   and the Solidity mapping(bytes32 => Message) where
   msgId = keccak256(source, dest, nonce). *)
Definition update_map3 {A : Type}
  (f : nat -> nat -> nat -> A) (k1 k2 k3 : nat) (v : A)
  : nat -> nat -> nat -> A :=
  fun n1 n2 n3 =>
    if (Nat.eqb n1 k1) && (Nat.eqb n2 k2) && (Nat.eqb n3 k3)
    then v else f n1 n2 n3.

Lemma update_map3_eq : forall (A : Type) (f : nat -> nat -> nat -> A) k1 k2 k3 v,
  update_map3 f k1 k2 k3 v k1 k2 k3 = v.
Proof. intros. unfold update_map3. rewrite !Nat.eqb_refl. reflexivity. Qed.

Lemma update_map3_neq : forall (A : Type) (f : nat -> nat -> nat -> A)
  k1 k2 k3 v n1 n2 n3,
  n1 <> k1 \/ n2 <> k2 \/ n3 <> k3 ->
  update_map3 f k1 k2 k3 v n1 n2 n3 = f n1 n2 n3.
Proof.
  intros A f k1 k2 k3 v n1 n2 n3 H. unfold update_map3.
  destruct (Nat.eqb_spec n1 k1); simpl; [| reflexivity].
  destruct (Nat.eqb_spec n2 k2); simpl; [| reflexivity].
  destruct (Nat.eqb_spec n3 k3); [| reflexivity].
  subst. destruct H as [H | [H | H]]; contradiction.
Qed.

(* ========================================== *)
(*     FUNCTIONAL MAP: 2-KEY                   *)
(* ========================================== *)

(* For nonce counter: f(src, dst). *)
Definition update_map2 {A : Type}
  (f : nat -> nat -> A) (k1 k2 : nat) (v : A)
  : nat -> nat -> A :=
  fun n1 n2 =>
    if (Nat.eqb n1 k1) && (Nat.eqb n2 k2)
    then v else f n1 n2.

Lemma update_map2_eq : forall (A : Type) (f : nat -> nat -> A) k1 k2 v,
  update_map2 f k1 k2 v k1 k2 = v.
Proof. intros. unfold update_map2. rewrite !Nat.eqb_refl. reflexivity. Qed.

(* ========================================== *)
(*     ADVANCE ROOTS                           *)
(* ========================================== *)

(* Atomically advance two enterprise roots by 1.
   Models TLA+ [stateRoots EXCEPT ![e1] = @+1, ![e2] = @+1].
   When e1 = e2, the root advances by 1 (not 2), matching
   the TLA+ EXCEPT semantics.
   [Source: HubAndSpoke.tla, lines 292-294 -- AttemptSettlement success] *)
Definition advance_roots (roots : Enterprise -> nat) (e1 e2 : Enterprise)
  : Enterprise -> nat :=
  fun e => if Nat.eqb e e1 then roots e1 + 1
           else if Nat.eqb e e2 then roots e2 + 1
           else roots e.

(* advance_roots never decreases a root. *)
Lemma advance_roots_ge : forall roots e1 e2 e,
  advance_roots roots e1 e2 e >= roots e.
Proof.
  intros. unfold advance_roots.
  destruct (Nat.eqb_spec e e1); [subst; lia |].
  destruct (Nat.eqb_spec e e2); [subst; lia | lia].
Qed.

(* advance_roots at e1 gives roots(e1) + 1. *)
Lemma advance_roots_at_e1 : forall roots e1 e2,
  advance_roots roots e1 e2 e1 = roots e1 + 1.
Proof. intros. unfold advance_roots. rewrite Nat.eqb_refl. reflexivity. Qed.

(* advance_roots at e2 gives roots(e2) + 1 regardless of whether e1 = e2.
   When e1 = e2: first branch fires, giving roots(e1)+1 = roots(e2)+1.
   When e1 /= e2: second branch fires, giving roots(e2)+1. *)
Lemma advance_roots_at_e2 : forall roots e1 e2,
  advance_roots roots e1 e2 e2 = roots e2 + 1.
Proof.
  intros. unfold advance_roots.
  destruct (Nat.eqb e2 e1) eqn:He.
  - apply Nat.eqb_eq in He. subst. reflexivity.
  - rewrite Nat.eqb_refl. reflexivity.
Qed.

(* ========================================== *)
(*     TRIPLE DECIDABILITY                     *)
(* ========================================== *)

(* For case-splitting on message store keys (src, dst, nonce). *)
Lemma triple_eq_dec : forall a b c d e f : nat,
  (a = d /\ b = e /\ c = f) \/ (a <> d \/ b <> e \/ c <> f).
Proof.
  intros.
  destruct (Nat.eq_dec a d) as [-> | ?];
  [destruct (Nat.eq_dec b e) as [-> | ?];
   [destruct (Nat.eq_dec c f) as [-> | ?];
    [left; auto | right; right; right; auto]
   | right; right; left; auto]
  | right; left; auto].
Qed.

(* ========================================== *)
(*     TACTIC                                  *)
(* ========================================== *)

(* Destruct the outermost match expression. *)
Ltac destruct_match :=
  match goal with
  | [ |- context[match ?x with _ => _ end] ] => destruct x eqn:?
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x eqn:?
  end.
