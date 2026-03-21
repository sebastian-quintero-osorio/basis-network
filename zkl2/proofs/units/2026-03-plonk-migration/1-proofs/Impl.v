(* ========================================================================= *)
(* Impl.v -- Abstract Model of Rust and Solidity Implementation              *)
(* ========================================================================= *)
(* Models the key verification logic from:                                   *)
(*   Rust:     types.rs (MigrationPhase::accepts)                            *)
(*             verifier.rs (verify_with_phase)                               *)
(*   Solidity: BasisVerifier.sol (_isProofSystemActive, phase transitions)   *)
(*                                                                           *)
(* Proves that both implementations are isomorphic to the TLA+ spec's       *)
(* VerifiersForPhase mapping and phase transition guards.                   *)
(* ========================================================================= *)

From PlonkMigration Require Import Common.
From PlonkMigration Require Import Spec.

(* ========================================================================= *)
(*                RUST MODEL: MigrationPhase::accepts                        *)
(* ========================================================================= *)

(* Models types.rs lines 38-52.
   MigrationPhase::active_verifiers() returns &[ProofSystem].
   MigrationPhase::accepts() checks containment in that slice.
   Argument order follows Rust: (self: Phase, ps: ProofSystem). *)
Definition rust_accepts (p : Phase) (ps : ProofSystemId) : bool :=
  match p with
  | Groth16Only =>
      match ps with PSGroth16 => true  | PSPlonk => false end
  | Dual => true
  | PlonkOnly =>
      match ps with PSPlonk  => true  | PSGroth16 => false end
  | Rollback =>
      match ps with PSGroth16 => true  | PSPlonk => false end
  end.

(* Rust implementation faithfully implements VerifiersForPhase.
   Proof by exhaustive case analysis on all (Phase x ProofSystem) pairs. *)
Theorem rust_accepts_correct : forall p ps,
  rust_accepts p ps = ps_accepted ps p.
Proof. intros [] []; reflexivity. Qed.

(* ========================================================================= *)
(*            SOLIDITY MODEL: _isProofSystemActive                           *)
(* ========================================================================= *)

(* Models BasisVerifier.sol lines 431-442.
   Uses if-else chain; Dual phase returns true for ALL proof systems. *)
Definition sol_is_active (p : Phase) (ps : ProofSystemId) : bool :=
  match p with
  | Groth16Only =>
      match ps with PSGroth16 => true  | _ => false end
  | Dual => true
  | PlonkOnly =>
      match ps with PSPlonk  => true  | _ => false end
  | Rollback =>
      match ps with PSGroth16 => true  | _ => false end
  end.

(* Solidity implementation faithfully implements VerifiersForPhase. *)
Theorem sol_is_active_correct : forall p ps,
  sol_is_active p ps = ps_accepted ps p.
Proof. intros [] []; reflexivity. Qed.

(* Both implementations agree -- Rust and Solidity are equivalent. *)
Corollary rust_sol_equivalence : forall p ps,
  rust_accepts p ps = sol_is_active p ps.
Proof.
  intros p ps.
  rewrite rust_accepts_correct, sol_is_active_correct. reflexivity.
Qed.

(* ========================================================================= *)
(*        SOLIDITY MODEL: Phase Transition Guards                            *)
(* ========================================================================= *)

(* startDualVerification [BasisVerifier.sol:287] *)
Definition sol_can_start_dual (p : Phase) : bool :=
  match p with Groth16Only => true | _ => false end.

Lemma sol_start_dual_sound : forall p,
  sol_can_start_dual p = true -> p = Groth16Only.
Proof. destruct p; simpl; congruence. Qed.

(* cutoverToPlonkOnly [BasisVerifier.sol:310-316] *)
Definition sol_can_cutover (p : Phase) (fd : bool) : bool :=
  match p with Dual => negb fd | _ => false end.

Lemma sol_cutover_sound : forall p fd,
  sol_can_cutover p fd = true -> p = Dual /\ fd = false.
Proof.
  destruct p; simpl; try discriminate.
  destruct fd; simpl; try discriminate.
  intros _. split; reflexivity.
Qed.

(* rollbackMigration [BasisVerifier.sol:355-356] *)
Definition sol_can_rollback (p : Phase) (fd : bool) : bool :=
  match p with Dual => fd | _ => false end.

Lemma sol_rollback_sound : forall p fd,
  sol_can_rollback p fd = true -> p = Dual /\ fd = true.
Proof.
  destruct p; simpl; try discriminate.
  destruct fd; simpl; try discriminate.
  intros _. split; reflexivity.
Qed.

(* completeRollback [BasisVerifier.sol:372-373] *)
Definition sol_can_complete_rollback (p : Phase) : bool :=
  match p with Rollback => true | _ => false end.

Lemma sol_complete_rollback_sound : forall p,
  sol_can_complete_rollback p = true -> p = Rollback.
Proof. destruct p; simpl; congruence. Qed.
