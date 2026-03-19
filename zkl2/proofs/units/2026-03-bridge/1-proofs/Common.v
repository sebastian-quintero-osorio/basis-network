(* ========================================== *)
(*     Common.v -- Standard Library            *)
(*     BasisBridge Verification Unit           *)
(*     zkl2/proofs/units/2026-03-bridge        *)
(* ========================================== *)

(* Shared types, functional map utilities, sum helpers, and tactics
   for the BasisBridge L1-L2 bridge verification.

   Models bridge state with per-user balance functions and
   withdrawal lists. Sum operations map TLA+ SumFun and SumAmounts.

   Source: BasisBridge.tla, BasisBridge.sol, relayer.go *)

From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
From Stdlib Require Import List.
Import ListNotations.

(* ========================================== *)
(*     ABSTRACT TYPES                          *)
(* ========================================== *)

(* User identifier. Nat for decidable equality.
   [Source: BasisBridge.tla, line 22 -- Users constant]
   [Source: BasisBridge.sol -- address type] *)
Definition User := nat.

(* Withdrawal identifier. Monotonically increasing.
   [Source: BasisBridge.tla, line 52 -- nextWid]
   [Source: BasisBridge.sol, line 90 -- withdrawalNullifier] *)
Definition Wid := nat.

(* ========================================== *)
(*     WITHDRAWAL RECORD                       *)
(* ========================================== *)

(* Models a withdrawal in pendingWithdrawals or finalizedWithdrawals.
   [Source: BasisBridge.tla, lines 44-45 -- [user, amount, wid] records]
   [Source: relayer/types.go -- WithdrawalEvent, WithdrawTrieEntry] *)
Record Withdrawal := mkW {
  w_user   : User;
  w_amount : nat;
  w_wid    : Wid;
}.

(* ========================================== *)
(*     FUNCTIONAL MAP OPERATIONS               *)
(* ========================================== *)

(* Pointwise update of a function at a single key.
   Models TLA+ [f EXCEPT ![k] = v] and Solidity mapping writes.
   [Source: BasisBridge.tla -- EXCEPT operator throughout]
   [Source: BasisBridge.sol -- mapping writes] *)
Definition update_map {A : Type} (f : nat -> A) (k : nat) (v : A) : nat -> A :=
  fun n => if Nat.eqb n k then v else f n.

Lemma update_map_eq : forall (A : Type) (f : nat -> A) k v,
  update_map f k v k = v.
Proof.
  intros. unfold update_map. rewrite Nat.eqb_refl. reflexivity.
Qed.

Lemma update_map_neq : forall (A : Type) (f : nat -> A) k v n,
  n <> k -> update_map f k v n = f n.
Proof.
  intros. unfold update_map.
  destruct (Nat.eqb_spec n k); [contradiction | reflexivity].
Qed.

(* ========================================== *)
(*     NAT LIST MEMBERSHIP                     *)
(* ========================================== *)

(* Boolean membership test for nat lists.
   Used for nullifier and escaped-user checks. *)
Fixpoint nat_mem (n : nat) (l : list nat) : bool :=
  match l with
  | [] => false
  | x :: rest => if Nat.eqb n x then true else nat_mem n rest
  end.

Lemma nat_mem_true : forall n l, nat_mem n l = true <-> In n l.
Proof.
  intros n l. induction l as [| x rest IH]; simpl.
  - split; [discriminate | contradiction].
  - destruct (Nat.eqb_spec n x) as [-> | Hne].
    + split; [intro; left; reflexivity | auto].
    + rewrite IH. split.
      * intro; right; assumption.
      * intros [Heq | Hin]; [congruence | assumption].
Qed.

Lemma nat_mem_false : forall n l, nat_mem n l = false <-> ~ In n l.
Proof.
  intros n l. split; intro H.
  - intro Hin. apply nat_mem_true in Hin. congruence.
  - destruct (nat_mem n l) eqn:E; [| reflexivity].
    exfalso. apply H. apply nat_mem_true. exact E.
Qed.

(* ========================================== *)
(*     SUM HELPERS                             *)
(* ========================================== *)

(* Sum of function values over a list of keys.
   [Source: BasisBridge.tla, lines 66-70 -- SumFun] *)
Fixpoint sum_fun (f : User -> nat) (users : list User) : nat :=
  match users with
  | [] => 0
  | u :: rest => f u + sum_fun f rest
  end.

(* Sum of the zero function is zero. *)
Lemma sum_fun_zero : forall users,
  sum_fun (fun _ => 0) users = 0.
Proof.
  induction users as [| u rest IH]; simpl; lia.
Qed.

(* Sum of amounts in a list of withdrawals.
   [Source: BasisBridge.tla, lines 74-78 -- SumAmounts] *)
Fixpoint sum_amounts (ws : list Withdrawal) : nat :=
  match ws with
  | [] => 0
  | w :: rest => w_amount w + sum_amounts rest
  end.

(* Sum distributes over append. *)
Lemma sum_amounts_app : forall l1 l2,
  sum_amounts (l1 ++ l2) = sum_amounts l1 + sum_amounts l2.
Proof.
  induction l1 as [| w rest IH]; intros l2; simpl.
  - reflexivity.
  - rewrite IH. lia.
Qed.

(* An element's value is bounded by the sum. *)
Lemma sum_fun_ge_elem : forall f users u,
  In u users -> f u <= sum_fun f users.
Proof.
  intros f users u Hin.
  induction users as [| a rest IH]; [contradiction |].
  simpl. destruct Hin as [-> | Hin']; [lia | specialize (IH Hin'); lia].
Qed.

(* sum_fun is unchanged when f is updated at a key not in users. *)
Lemma sum_fun_notin_update : forall (f : nat -> nat) users k v,
  ~ In k users ->
  sum_fun (update_map f k v) users = sum_fun f users.
Proof.
  intros f users k v Hnotin.
  induction users as [| a rest IH]; simpl.
  - reflexivity.
  - assert (a <> k) by (intro; subst; apply Hnotin; left; reflexivity).
    assert (~ In k rest) by (intro; apply Hnotin; right; assumption).
    rewrite update_map_neq by assumption.
    rewrite IH by assumption. reflexivity.
Qed.

(* Increasing one user's balance increases the sum.
   [Used in Deposit preservation] *)
Lemma sum_fun_update_add : forall f users u amt,
  NoDup users -> In u users ->
  sum_fun (update_map f u (f u + amt)) users = sum_fun f users + amt.
Proof.
  intros f users u amt Hnd Hin.
  induction users as [| a rest IH]; [contradiction |].
  simpl in *. inversion Hnd; subst.
  destruct Hin as [-> | Hin'].
  - rewrite update_map_eq.
    rewrite sum_fun_notin_update by assumption. lia.
  - rewrite update_map_neq by (intro Heq; subst; contradiction).
    rewrite IH by assumption. lia.
Qed.

(* Decreasing one user's balance decreases the sum. Additive form.
   [Used in InitiateWithdrawal preservation] *)
Lemma sum_fun_update_sub : forall f users u amt,
  NoDup users -> In u users -> f u >= amt ->
  sum_fun (update_map f u (f u - amt)) users + amt = sum_fun f users.
Proof.
  intros f users u amt Hnd Hin Hge.
  induction users as [| a rest IH]; [contradiction |].
  simpl in *. inversion Hnd; subst.
  destruct Hin as [-> | Hin'].
  - rewrite update_map_eq.
    rewrite sum_fun_notin_update by assumption. lia.
  - rewrite update_map_neq by (intro Heq; subst; contradiction).
    specialize (IH H2 Hin'). lia.
Qed.

(* ========================================== *)
(*     UNCLAIMED WITHDRAWALS                   *)
(* ========================================== *)

(* Finalized withdrawals whose wid is NOT in the claimed list.
   [Source: BasisBridge.tla, line 81 -- UnclaimedFinalized] *)
Fixpoint unclaimed (fin : list Withdrawal) (claimed : list Wid)
  : list Withdrawal :=
  match fin with
  | [] => []
  | w :: rest =>
    if nat_mem (w_wid w) claimed then unclaimed rest claimed
    else w :: unclaimed rest claimed
  end.

(* Adding a wid that does not appear in fin to claimed leaves
   unclaimed unchanged. *)
Lemma unclaimed_add_absent : forall fin claimed wid,
  (forall w, In w fin -> w_wid w <> wid) ->
  unclaimed fin (wid :: claimed) = unclaimed fin claimed.
Proof.
  induction fin as [| b rest IH]; intros claimed wid Hdiff; simpl.
  - reflexivity.
  - assert (Hbw : w_wid b <> wid) by (apply Hdiff; left; reflexivity).
    simpl. destruct (Nat.eqb_spec (w_wid b) wid); [contradiction |].
    destruct (nat_mem (w_wid b) claimed) eqn:Hmem.
    + apply IH. intros w Hw. apply Hdiff. right. exact Hw.
    + f_equal. apply IH. intros w Hw. apply Hdiff. right. exact Hw.
Qed.

(* Claiming one withdrawal: removes exactly that withdrawal from
   unclaimed. Additive form avoids nat subtraction.
   [Used in ClaimWithdrawal preservation] *)
Lemma sum_unclaimed_claim : forall fin claimed w,
  In w fin ->
  nat_mem (w_wid w) claimed = false ->
  NoDup (map w_wid fin) ->
  sum_amounts (unclaimed fin (w_wid w :: claimed)) + w_amount w =
  sum_amounts (unclaimed fin claimed).
Proof.
  induction fin as [| a rest IH]; intros claimed w Hin Hncl Hnd.
  - contradiction.
  - simpl in Hnd. inversion Hnd; subst.
    simpl.
    destruct Hin as [-> | Hin'].
    + (* a = w: removed from unclaimed by new claim *)
      simpl. rewrite Nat.eqb_refl.
      rewrite Hncl. simpl.
      rewrite unclaimed_add_absent.
      * lia.
      * intros w' Hw' Heq.
        apply H1. rewrite in_map_iff. exists w'. auto.
    + (* a <> w, recurse *)
      assert (Haw : w_wid a <> w_wid w).
      { intro Heq. apply H1. rewrite in_map_iff. exists w. auto. }
      simpl. destruct (Nat.eqb_spec (w_wid a) (w_wid w)); [contradiction |].
      destruct (nat_mem (w_wid a) claimed) eqn:Hmem.
      * apply IH; assumption.
      * simpl. specialize (IH claimed w Hin' Hncl H2). lia.
Qed.

(* Unclaimed of concatenation when right-side wids are fresh (not in
   claimed). Splits into unclaimed of left plus entire right.
   [Used in FinalizeBatch preservation] *)
Lemma unclaimed_app_fresh : forall fin pending claimed,
  (forall w, In w pending -> nat_mem (w_wid w) claimed = false) ->
  unclaimed (fin ++ pending) claimed =
  unclaimed fin claimed ++ pending.
Proof.
  induction fin as [| a rest IH]; intros pending claimed Hfresh; simpl.
  - induction pending as [| p rest' IH']; simpl.
    + reflexivity.
    + rewrite (Hfresh p (or_introl eq_refl)). simpl.
      f_equal. apply IH'. intros w Hw. apply Hfresh. right. exact Hw.
  - destruct (nat_mem (w_wid a) claimed) eqn:Hmem.
    + apply IH. exact Hfresh.
    + simpl. f_equal. apply IH. exact Hfresh.
Qed.

(* An unclaimed element contributes to the sum. *)
Lemma sum_amounts_unclaimed_ge : forall fin claimed w,
  In w fin ->
  nat_mem (w_wid w) claimed = false ->
  NoDup (map w_wid fin) ->
  w_amount w <= sum_amounts (unclaimed fin claimed).
Proof.
  induction fin as [| a rest IH]; intros claimed w Hin Hncl Hnd.
  - contradiction.
  - simpl in Hnd. inversion Hnd; subst.
    simpl.
    destruct Hin as [-> | Hin'].
    + rewrite Hncl. simpl. lia.
    + assert (Haw : w_wid a <> w_wid w).
      { intro Heq. apply H1. rewrite in_map_iff. exists w. auto. }
      destruct (nat_mem (w_wid a) claimed) eqn:Hmem.
      * apply IH; assumption.
      * simpl. specialize (IH claimed w Hin' Hncl H2). lia.
Qed.

(* ========================================== *)
(*     ACTIVE USERS                            *)
(* ========================================== *)

(* Users NOT in the escaped list.
   [Source: BasisBridge.tla, line 312 -- Users \ escapeNullifiers] *)
Fixpoint active_users (all_users : list User) (escaped : list User)
  : list User :=
  match all_users with
  | [] => []
  | u :: rest =>
    if nat_mem u escaped then active_users rest escaped
    else u :: active_users rest escaped
  end.

(* No escaped users means all users are active. *)
Lemma active_users_nil : forall users,
  active_users users [] = users.
Proof.
  induction users as [| u rest IH]; simpl.
  - reflexivity.
  - rewrite IH. reflexivity.
Qed.

(* Adding a user to escaped who is not in all_users is a no-op. *)
Lemma active_users_add_absent : forall users escaped u,
  ~ In u users ->
  active_users users (u :: escaped) = active_users users escaped.
Proof.
  induction users as [| a rest IH]; intros escaped u Hnotin; simpl.
  - reflexivity.
  - assert (Hau : a <> u) by (intro; subst; apply Hnotin; left; reflexivity).
    simpl. destruct (Nat.eqb_spec a u); [contradiction |].
    destruct (nat_mem a escaped) eqn:Hmem.
    + apply IH. intro. apply Hnotin. right. assumption.
    + f_equal. apply IH. intro. apply Hnotin. right. assumption.
Qed.

(* Removing one user from active decreases sum_fun by that user's value.
   [Used in EscapeWithdraw preservation] *)
Lemma sum_fun_active_remove : forall f all_users escaped u,
  NoDup all_users -> In u all_users -> ~ In u escaped ->
  sum_fun f (active_users all_users (u :: escaped)) + f u =
  sum_fun f (active_users all_users escaped).
Proof.
  induction all_users as [| a rest IH]; intros escaped u Hnd Hin Hne.
  - contradiction.
  - simpl. inversion Hnd; subst.
    destruct Hin as [-> | Hin'].
    + (* a = u: removed from active *)
      simpl. rewrite Nat.eqb_refl.
      assert (Hem : nat_mem u escaped = false) by (apply nat_mem_false; exact Hne).
      rewrite Hem. simpl.
      rewrite active_users_add_absent by exact H1. lia.
    + (* a <> u *)
      assert (Hau : a <> u) by (intro; subst; contradiction).
      simpl. destruct (Nat.eqb_spec a u); [contradiction |].
      destruct (nat_mem a escaped) eqn:Hmem.
      * apply IH; assumption.
      * simpl. specialize (IH escaped u H2 Hin' Hne). lia.
Qed.

(* Membership in active_users. *)
Lemma in_active_users : forall u users escaped,
  NoDup users -> In u users -> nat_mem u escaped = false ->
  In u (active_users users escaped).
Proof.
  induction users as [| a rest IH]; intros escaped Hnd Hin Hm.
  - contradiction.
  - simpl. inversion Hnd; subst.
    destruct Hin as [-> | Hin'].
    + rewrite Hm. left. reflexivity.
    + destruct (nat_mem a escaped).
      * apply IH; assumption.
      * right. apply IH; assumption.
Qed.

(* ========================================== *)
(*     NODUP HELPERS                           *)
(* ========================================== *)

(* NoDup for concatenation from components.
   May be in Stdlib but we prove it to be safe. *)
Lemma NoDup_app_intro : forall (A : Type) (l1 l2 : list A),
  NoDup l1 -> NoDup l2 ->
  (forall x, In x l1 -> ~ In x l2) ->
  NoDup (l1 ++ l2).
Proof.
  induction l1 as [| a l1' IH]; intros l2 Hnd1 Hnd2 Hdis; simpl.
  - exact Hnd2.
  - inversion Hnd1; subst. constructor.
    + rewrite in_app_iff. intros [H | H].
      * contradiction.
      * exact (Hdis a (or_introl eq_refl) H).
    + apply IH; [exact H2 | exact Hnd2 |].
      intros x Hx. apply Hdis. right. exact Hx.
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
