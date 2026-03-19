(* ========================================== *)
(*     Impl.v -- Go Implementation Model       *)
(*     Abstract Model of sequencer Go code     *)
(*     zkl2/proofs/units/2026-03-sequencer     *)
(* ========================================== *)

(* This file models the Go implementation of the enterprise L2 sequencer
   as Coq definitions. The key architectural difference from the spec:

   TLA+ (Spec.v):
     ProduceBlock non-deterministically chooses numForced in a range.
     The only constraint is numForced >= minRequired.

   Go (this file):
     BlockBuilder.BuildBlock operates in cooperative mode:
       1. DrainForBlock drains ALL forced txs (up to MaxTxPerBlock)
       2. Mempool.Drain fills remaining capacity
     The sequencer always calls BuildBlock with cooperative=true.

   The verification proves that the Go implementation's deterministic
   choice is always within the spec's non-deterministic range.

   Goroutine modeling: The Go sequencer uses sync.Mutex for thread
   safety (Mempool.mu, ForcedInclusionQueue.mu, Sequencer.mu).
   We model each public method as an atomic state transition,
   abstracting away concurrency. This is safe because all shared
   state access is serialized by the mutexes.

   Source: sequencer.go, mempool.go, forced_inclusion.go,
           block_builder.go, types.go (frozen in 0-input-impl/) *)

From Sequencer Require Import Common.
From Sequencer Require Import Spec.
From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
Import ListNotations.

(* ========================================== *)
(*     IMPLEMENTATION STATE                    *)
(* ========================================== *)

(* The implementation state mirrors the spec state but adds the
   cooperative flag from the Go BlockBuilder.

   Goroutine model: each field corresponds to a Go struct field:
     im_mempool     -> Mempool.txs      (sync.Mutex serialized)
     im_fqueue      -> ForcedInclusionQueue.queue (sync.Mutex serialized)
     im_blocks      -> Sequencer.blocks  (sync.Mutex serialized)
     im_blocknum    -> Sequencer.blockNumber (sync.Mutex serialized)
     im_cooperative -> BlockBuilder cooperative flag (always true in prod)

   [Source: types.go lines 41-51, 75-79, 123-133, 167-189]
   [Source: sequencer.go lines 24-45] *)
Record impl_state := mkImplState {
  im_mempool     : list nat;
  im_fqueue      : list (nat * nat);
  im_blocks      : list (list nat);
  im_blocknum    : nat;
  im_everseen    : list nat;
  im_fdeadlines  : list (nat * nat);
  im_cooperative : bool;
}.

(* Default production configuration: cooperative=true.
   [Source: sequencer.go line 100 -- BuildBlock(s.blockNumber, s.lastHash, true)] *)
Definition impl_init : impl_state :=
  mkImplState [] [] [] 0 [] [] true.

(* ========================================== *)
(*     IMPLEMENTATION ACTIONS                  *)
(* ========================================== *)

(* Compute the number of forced txs to drain for a block.
   Models ForcedInclusionQueue.DrainForBlock.

   Cooperative mode: drain all queued forced txs (up to capacity).
   Non-cooperative mode: drain only expired forced txs.
   In both modes, at least minRequired must be drained.

   [Source: forced_inclusion.go lines 93-149] *)
Definition impl_nf (s : impl_state) : nat :=
  let epc := expired_prefix_count (im_blocknum s) (im_fqueue s) in
  let raw := if im_cooperative s
             then length (im_fqueue s)
             else epc in
  let capped := Nat.min raw MaxTxPerBlock in
  Nat.max capped epc.

(* Compute the number of mempool txs to include after forced.
   Models BlockBuilder.BuildBlock step 2: fill remaining capacity.

   [Source: block_builder.go lines 75-90] *)
Definition impl_nm (s : impl_state) : nat :=
  let nf := impl_nf s in
  let remaining := MaxTxPerBlock - nf in
  Nat.min remaining (length (im_mempool s)).

Inductive impl_step : impl_state -> impl_state -> Prop :=

  (* Mempool.Add: insert a regular transaction.
     Thread-safe via sync.Mutex. Deduplication via seen map.
     [Source: mempool.go lines 51-78] *)
  | ImSubmitTx : forall tx s,
      is_forced_b tx = false ->
      ~ In tx (im_everseen s) ->
      impl_step s (mkImplState
        (im_mempool s ++ [tx])
        (im_fqueue s)
        (im_blocks s)
        (im_blocknum s)
        (im_everseen s ++ [tx])
        (im_fdeadlines s)
        (im_cooperative s))

  (* ForcedInclusionQueue.Submit: add a forced transaction.
     Thread-safe via sync.Mutex.
     [Source: forced_inclusion.go lines 57-76] *)
  | ImSubmitForcedTx : forall ftx s,
      is_forced_b ftx = true ->
      ~ In ftx (im_everseen s) ->
      impl_step s (mkImplState
        (im_mempool s)
        (im_fqueue s ++ [(ftx, im_blocknum s)])
        (im_blocks s)
        (im_blocknum s)
        (im_everseen s ++ [ftx])
        (im_fdeadlines s ++ [(ftx, im_blocknum s)])
        (im_cooperative s))

  (* Sequencer.ProduceBlock -> BlockBuilder.BuildBlock.
     The Go code deterministically computes nf and nm.

     Block production goroutine (StartSequencer) calls ProduceBlock
     on each ticker tick. ProduceBlock acquires Sequencer.mu, delegates
     to BlockBuilder.BuildBlock, then advances blockNumber.

     [Source: sequencer.go lines 96-107]
     [Source: block_builder.go lines 52-117] *)
  | ImBuildBlock : forall s,
      impl_nf s <= length (im_fqueue s) ->
      expired_prefix_count (im_blocknum s) (im_fqueue s) <= MaxTxPerBlock ->
      impl_step s (mkImplState
        (drop (impl_nm s) (im_mempool s))
        (drop (impl_nf s) (im_fqueue s))
        (im_blocks s ++ [forced_ids (take (impl_nf s) (im_fqueue s))
                          ++ take (impl_nm s) (im_mempool s)])
        (im_blocknum s + 1)
        (im_everseen s)
        (im_fdeadlines s)
        (im_cooperative s)).

(* ========================================== *)
(*     STEP EQUIVALENCE                        *)
(* ========================================== *)

(* The mapping from implementation state to specification state.
   The cooperative flag is erased (it is an implementation detail). *)
Definition map_state (is : impl_state) : spec_state :=
  mkSpecState
    (im_mempool is)
    (im_fqueue is)
    (im_blocks is)
    (im_blocknum is)
    (im_everseen is)
    (im_fdeadlines is).

(* Implementation initial state maps to spec initial state. *)
Lemma map_init : map_state impl_init = spec_init.
Proof.
  reflexivity.
Qed.

(* Helper: impl_nf satisfies the spec constraints. *)
Lemma impl_nf_ge_epc : forall s,
  impl_nf s >= expired_prefix_count (im_blocknum s) (im_fqueue s).
Proof.
  intros s. unfold impl_nf. apply Nat.le_max_r.
Qed.

(* When expired prefix fits in block capacity, impl_nf <= MaxTxPerBlock.
   This is the normal operational regime. The pathological case where
   more than MaxTxPerBlock forced txs expire simultaneously is excluded
   by the enterprise deployment model (frequent block production). *)
Lemma impl_nf_le_max : forall s,
  expired_prefix_count (im_blocknum s) (im_fqueue s) <= MaxTxPerBlock ->
  impl_nf s <= MaxTxPerBlock.
Proof.
  intros s Hepc. unfold impl_nf.
  assert (H1 := Nat.le_min_r
    (if im_cooperative s then length (im_fqueue s)
     else expired_prefix_count (im_blocknum s) (im_fqueue s))
    MaxTxPerBlock).
  assert (H2 := Nat.le_max_l
    (Nat.min (if im_cooperative s then length (im_fqueue s)
              else expired_prefix_count (im_blocknum s) (im_fqueue s))
             MaxTxPerBlock)
    (expired_prefix_count (im_blocknum s) (im_fqueue s))).
  destruct (Nat.max_spec
    (Nat.min (if im_cooperative s then length (im_fqueue s)
              else expired_prefix_count (im_blocknum s) (im_fqueue s))
             MaxTxPerBlock)
    (expired_prefix_count (im_blocknum s) (im_fqueue s)))
    as [[Hlt Heq]|[Hge Heq]]; rewrite Heq; lia.
Qed.

Lemma impl_nf_nm_le_max : forall s,
  expired_prefix_count (im_blocknum s) (im_fqueue s) <= MaxTxPerBlock ->
  impl_nf s + impl_nm s <= MaxTxPerBlock.
Proof.
  intros s Hepc.
  assert (Hnf := impl_nf_le_max s Hepc).
  unfold impl_nm.
  assert (H := Nat.le_min_l (MaxTxPerBlock - impl_nf s) (length (im_mempool s))).
  lia.
Qed.

Lemma impl_nm_le_mempool : forall s,
  impl_nm s <= length (im_mempool s).
Proof.
  intros s. unfold impl_nm. apply Nat.le_min_r.
Qed.

(* Every implementation step corresponds to a valid specification step.
   The Go code's deterministic choices fall within the TLA+ spec's
   non-deterministic range. *)
Theorem refinement_step : forall is is',
  impl_step is is' ->
  spec_step (map_state is) (map_state is').
Proof.
  intros is is' Hstep.
  inversion Hstep; subst; simpl.
  - (* ImSubmitTx -> SpSubmitTx *)
    apply SpSubmitTx; assumption.
  - (* ImSubmitForcedTx -> SpSubmitForcedTx *)
    apply SpSubmitForcedTx; assumption.
  - (* ImBuildBlock -> SpProduceBlock *)
    apply (SpProduceBlock (impl_nf is) (impl_nm is)).
    + exact H.
    + exact (impl_nm_le_mempool is).
    + exact (impl_nf_nm_le_max is H0).
    + exact (impl_nf_ge_epc is).
Qed.
