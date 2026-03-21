From Stdlib Require Import Arith PeanoNat Lia.
From ProductionDAC Require Import Common Spec.
Goal forall s s' (b : Batch), (exists b0 S0, RecoverData b0 S0 s s') ->
  recoverSt s' b <> RecNone -> True.
Proof.
  intros s s' b Hrd Hne.
  destruct Hrd as [b0 [S0 Hrd_prop]].
  destruct Hrd_prop as (Hb0 & Hcv0 & HrsNone & Hsmem & Hne0 &
    Hrn' & Hcases & Hrnother & Hrsother & Honl & Hdt & Hcvf & Hcc' & Hatf & Hcsf).
  destruct (Batch_eq_dec b b0) as [Heqb | Hneb].
  - subst.
    rewrite Hrn' in Hne.
    exact I.
  - exact I.
Qed.
