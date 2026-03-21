From ProductionDAC Require Import Common Spec.
Goal forall s s' b0 S0, RecoverData b0 S0 s s' -> recoveryNodes s' b0 = S0.
Proof.
  intros s s' b0 S0 H.
  destruct H as (H1 & H2 & H3 & H4 & H5 & H6 & H7 & H8 & H9 & H10 & H11 & H12 & H13 & H14 & H15).
  exact H6.
Qed.
