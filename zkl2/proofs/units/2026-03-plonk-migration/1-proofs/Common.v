(* ========================================================================= *)
(* Common.v -- Standard Library for PLONK Migration Verification             *)
(* ========================================================================= *)
(* Provides migration phase types, proof system identifiers, batch and proof *)
(* record types, and the VerifiersForPhase acceptance function.              *)
(*                                                                           *)
(* Source: PlonkMigration.tla                                                *)
(* TLC Evidence: 9,117,756 states, 3,985,171 distinct, depth 22 -- PASS     *)
(* ========================================================================= *)

From Stdlib Require Import Arith PeanoNat Lia List Bool.
Import ListNotations.

(* ========================================================================= *)
(*                     MIGRATION PHASE TYPE                                  *)
(* ========================================================================= *)

(* [TLA+ line 20: Phases == {"groth16_only", "dual", "plonk_only", "rollback"}]
   [Rust: types.rs:18-28]  [Solidity: BasisVerifier.sol:32-37] *)
Inductive Phase : Type :=
  | Groth16Only
  | Dual
  | PlonkOnly
  | Rollback.

Lemma Phase_eq_dec : forall a b : Phase, {a = b} + {a <> b}.
Proof. decide equality. Defined.

(* ========================================================================= *)
(*                     PROOF SYSTEM IDENTIFIER                               *)
(* ========================================================================= *)

(* [TLA+ line 12: ProofSystems == {"groth16", "plonk"}]
   [Rust: types.rs:62-66]  [Solidity: BasisVerifier.sol:40-43] *)
Inductive ProofSystemId : Type :=
  | PSGroth16
  | PSPlonk.

Lemma ProofSystemId_eq_dec : forall a b : ProofSystemId, {a = b} + {a <> b}.
Proof. decide equality. Defined.

(* ========================================================================= *)
(*                     VERIFIERS-FOR-PHASE MAPPING                           *)
(* ========================================================================= *)

(* Boolean function encoding TLA+ VerifiersForPhase (lines 24-28).
   [Rust: MigrationPhase::accepts (types.rs:50)]
   [Solidity: _isProofSystemActive (BasisVerifier.sol:431)] *)
Definition ps_accepted (ps : ProofSystemId) (p : Phase) : bool :=
  match p, ps with
  | Groth16Only, PSGroth16 => true
  | Dual, PSGroth16        => true
  | Dual, PSPlonk          => true
  | PlonkOnly, PSPlonk     => true
  | Rollback, PSGroth16    => true
  | _, _                   => false
  end.

(* ========================================================================= *)
(*                     BATCH AND PROOF RECORD TYPES                          *)
(* ========================================================================= *)

Definition Enterprise := nat.
Definition Enterprise_eq_dec := Nat.eq_dec.

(* [TLA+ line 53: BatchRecord] *)
Record BatchRecord := mkBatch {
  batch_enterprise : Enterprise;
  batch_seqNo : nat;
  batch_proofSystem : ProofSystemId;
}.

(* [TLA+ line 61: ProofRecord] *)
Record ProofRecord := mkProofRec {
  proof_batch : BatchRecord;
  proof_valid : bool;
  proof_phase : Phase;
}.

(* ========================================================================= *)
(*                     STRUCTURAL LEMMAS                                     *)
(* ========================================================================= *)

(* S5 foundation: Groth16 NOT accepted after cutover. *)
Lemma groth16_rejected_plonk_only :
  ps_accepted PSGroth16 PlonkOnly = false.
Proof. reflexivity. Qed.

(* Exhaustive characterization of Groth16 acceptance. *)
Lemma groth16_accepted_iff : forall p,
  ps_accepted PSGroth16 p = true <-> (p = Groth16Only \/ p = Dual \/ p = Rollback).
Proof.
  split.
  - destruct p; simpl; intro H; auto; discriminate.
  - intros [H | [H | H]]; subst; reflexivity.
Qed.

(* ========================================================================= *)
(*                              TACTICS                                      *)
(* ========================================================================= *)

Ltac destruct_match :=
  match goal with
  | [ |- context[match ?x with _ => _ end] ] => destruct x
  | [ H : context[match ?x with _ => _ end] |- _ ] => destruct x
  end.

Ltac enterprise_cases e e0 :=
  destruct (Enterprise_eq_dec e e0) as [?Heq | ?Hne]; [subst | idtac].
