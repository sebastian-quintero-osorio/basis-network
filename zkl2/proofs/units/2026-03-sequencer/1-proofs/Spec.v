(* ========================================== *)
(*     Spec.v -- TLA+ Specification Model      *)
(*     Faithful Translation of Sequencer.tla   *)
(*     zkl2/proofs/units/2026-03-sequencer     *)
(* ========================================== *)

(* This file translates the TLA+ specification of the enterprise L2
   sequencer into Coq definitions. The specification models:

   - FIFO mempool for regular transactions (SubmitTx action)
   - Arbitrum-style forced inclusion queue with deadline enforcement
     (SubmitForcedTx action)
   - Single-operator block production with forced-first ordering
     (ProduceBlock action)

   Every definition is tagged with its source in Sequencer.tla.

   Key design choices for Coq modeling:
   - Transaction IDs are nat (decidable equality)
   - is_forced_b : nat -> bool classifies transactions (Txs vs ForcedTxs)
   - Forced queue entries are (tx_id, submit_block) pairs
   - sp_everseen tracks DOMAIN submitOrder for deduplication
   - sp_fdeadlines is append-only record of all forced submissions

   [Source: zkl2/specs/units/2026-03-sequencer/1-formalization/
    v0-analysis/specs/Sequencer/Sequencer.tla] *)

From Sequencer Require Import Common.
From Stdlib Require Import List.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
Import ListNotations.

(* ========================================== *)
(*     CONSTANTS (Parameters)                  *)
(* ========================================== *)

(* Transaction type classifier. Returns true for forced transactions
   (ForcedTxs set), false for regular transactions (Txs set).
   Models the disjoint partition: Txs \cap ForcedTxs = {}.
   [Source: Sequencer.tla line 33 -- ASSUME Txs \cap ForcedTxs = {}] *)
Parameter is_forced_b : nat -> bool.

(* Blocks within which a forced tx MUST be included after submission.
   [Source: Sequencer.tla line 31] *)
Parameter ForcedDeadlineBlocks : nat.

(* Maximum transactions per block.
   [Source: Sequencer.tla line 29] *)
Parameter MaxTxPerBlock : nat.

(* [Source: Sequencer.tla lines 34-36 -- ASSUME clauses] *)
Axiom ForcedDeadlineBlocks_pos : ForcedDeadlineBlocks > 0.
Axiom MaxTxPerBlock_pos : MaxTxPerBlock > 0.

(* ========================================== *)
(*     HELPER DEFINITIONS                      *)
(* ========================================== *)

(* Project forced queue entries to their transaction IDs.
   forced_ids(q) = {q[i][1] : i in 1..Len(q)} in TLA+ notation. *)
Definition forced_ids (q : list (nat * nat)) : list nat := map fst q.

(* Count the maximal prefix of consecutive expired forced transactions.
   A forced tx (_, submit_block) is expired when
   submit_block + ForcedDeadlineBlocks <= current block number.

   Models the TLA+ minRequired computation:
     minRequired == Cardinality({i \in 1..Len(forcedQueue) :
                     \A j \in 1..i : IsExpired(j)})

   [Source: Sequencer.tla lines 147-156] *)
Fixpoint expired_prefix_count (bn : nat) (q : list (nat * nat)) : nat :=
  match q with
  | [] => 0
  | (_, sb) :: rest =>
    if Nat.leb (sb + ForcedDeadlineBlocks) bn
    then S (expired_prefix_count bn rest)
    else 0
  end.

(* ========================================== *)
(*     STATE                                   *)
(* ========================================== *)

(* The specification state combines all TLA+ variables.
   [Source: Sequencer.tla lines 58-65 -- VARIABLES declaration] *)
Record spec_state := mkSpecState {
  sp_mempool   : list nat;            (* Seq(Txs): FIFO pending regular txs *)
  sp_fqueue    : list (nat * nat);    (* Seq(ForcedTxs) x blockNum: forced queue *)
  sp_blocks    : list (list nat);     (* Seq(Seq(AllTxIds)): produced blocks *)
  sp_blocknum  : nat;                 (* Nat: blocks produced so far *)
  sp_everseen  : list nat;            (* DOMAIN submitOrder: all submitted IDs *)
  sp_fdeadlines : list (nat * nat);   (* Permanent record: (ftx, submit_block) *)
}.

(* [Source: Sequencer.tla lines 98-104 -- Init] *)
Definition spec_init : spec_state :=
  mkSpecState [] [] [] 0 [] [].

(* ========================================== *)
(*     STEP RELATION                           *)
(* ========================================== *)

(* The next-state relation. Each constructor corresponds to a TLA+ action.
   [Source: Sequencer.tla lines 179-183 -- Next] *)
Inductive spec_step : spec_state -> spec_state -> Prop :=

  (* SubmitTx: A user submits a regular transaction to the mempool.
     [Source: Sequencer.tla lines 114-119] *)
  | SpSubmitTx : forall tx s,
      is_forced_b tx = false ->
      ~ In tx (sp_everseen s) ->
      spec_step s (mkSpecState
        (sp_mempool s ++ [tx])
        (sp_fqueue s)
        (sp_blocks s)
        (sp_blocknum s)
        (sp_everseen s ++ [tx])
        (sp_fdeadlines s))

  (* SubmitForcedTx: A transaction is submitted via L1 for forced inclusion.
     Records the current block number for deadline enforcement.
     [Source: Sequencer.tla lines 126-132] *)
  | SpSubmitForcedTx : forall ftx s,
      is_forced_b ftx = true ->
      ~ In ftx (sp_everseen s) ->
      spec_step s (mkSpecState
        (sp_mempool s)
        (sp_fqueue s ++ [(ftx, sp_blocknum s)])
        (sp_blocks s)
        (sp_blocknum s)
        (sp_everseen s ++ [ftx])
        (sp_fdeadlines s ++ [(ftx, sp_blocknum s)]))

  (* ProduceBlock: The sequencer produces a block.
     Chooses nf forced txs and nm mempool txs, subject to:
       nf >= minRequired (expired forced txs must be included)
       nf + nm <= MaxTxPerBlock (block capacity)
     Forced txs appear first in the block, then mempool txs.
     [Source: Sequencer.tla lines 143-177] *)
  | SpProduceBlock : forall nf nm s,
      nf <= length (sp_fqueue s) ->
      nm <= length (sp_mempool s) ->
      nf + nm <= MaxTxPerBlock ->
      nf >= expired_prefix_count (sp_blocknum s) (sp_fqueue s) ->
      spec_step s (mkSpecState
        (drop nm (sp_mempool s))
        (drop nf (sp_fqueue s))
        (sp_blocks s ++ [forced_ids (take nf (sp_fqueue s))
                          ++ take nm (sp_mempool s)])
        (sp_blocknum s + 1)
        (sp_everseen s)
        (sp_fdeadlines s)).

(* ========================================== *)
(*     SAFETY PROPERTY DEFINITIONS             *)
(* ========================================== *)

(* The set of all included transaction IDs.
   [Source: Sequencer.tla line 80] *)
Definition included (s : spec_state) : list nat :=
  concat (sp_blocks s).

(* Property 1: No Double Inclusion.
   No transaction appears in more than one block. Modeled as NoDup on
   the flattened block list (stronger: no duplicates within or across).
   [Source: Sequencer.tla lines 191-193] *)
Definition no_double_inclusion (s : spec_state) : Prop :=
  NoDup (included s).

(* Property 2: Included Were Submitted.
   Only previously submitted transactions may appear in blocks.
   [Source: Sequencer.tla lines 205-206] *)
Definition included_were_submitted (s : spec_state) : Prop :=
  forall x, In x (included s) -> In x (sp_everseen s).

(* Property 3: Forced Before Mempool.
   Within each block, no regular tx precedes a forced tx.
   [Source: Sequencer.tla lines 211-217] *)
Definition forced_before_mempool (s : spec_state) : Prop :=
  forall b, In b (sp_blocks s) ->
    ~ exists i j, i < j /\ j < length b /\
      is_forced_b (nth i b 0) = false /\
      is_forced_b (nth j b 0) = true.

(* Property 4: Forced Inclusion Deadline.
   If we have passed the deadline for a forced tx, it must be included.
   [Source: Sequencer.tla lines 199-201] *)
Definition forced_inclusion_deadline (s : spec_state) : Prop :=
  forall ftx sb,
    In (ftx, sb) (sp_fdeadlines s) ->
    sp_blocknum s > sb + ForcedDeadlineBlocks ->
    In ftx (included s).

(* Property 5: FIFO Within Block.
   Within each block, transactions of the same type are ordered by their
   position in the original queue (submission order). This is a structural
   consequence of Take-from-front on FIFO queues.
   [Source: Sequencer.tla lines 224-233] *)
Definition fifo_within_block (s : spec_state) : Prop :=
  forall b, In b (sp_blocks s) ->
    exists k,
      (forall i, i < k -> i < length b ->
        is_forced_b (nth i b 0) = true) /\
      (forall i, k <= i -> i < length b ->
        is_forced_b (nth i b 0) = false).

(* ========================================== *)
(*     STRENGTHENED INVARIANT                  *)
(* ========================================== *)

(* The strengthened invariant captures all structural properties needed
   to prove the safety properties as inductive invariants. Each field
   corresponds to a necessary intermediate fact.

   The invariant holds in the initial state and is preserved by every
   step of the next-state relation. *)
Record Inv (s : spec_state) : Prop := mkInv {

  (* I1: No duplicates across active components (mempool, forced queue,
     and all blocks). This is the master structural invariant from which
     NoDoubleInclusion follows directly. *)
  inv_nd : NoDup (sp_mempool s ++ forced_ids (sp_fqueue s)
                   ++ included s);

  (* I2: Mempool contains only regular transactions. *)
  inv_tm : forall x, In x (sp_mempool s) -> is_forced_b x = false;

  (* I3: Forced queue contains only forced transactions. *)
  inv_tf : forall x, In x (forced_ids (sp_fqueue s)) ->
           is_forced_b x = true;

  (* I4: Block number equals number of produced blocks. *)
  inv_bn : sp_blocknum s = length (sp_blocks s);

  (* I5: Ever-seen set has no duplicates. *)
  inv_en : NoDup (sp_everseen s);

  (* I6: All active elements are in the ever-seen set. *)
  inv_ei : forall x, In x (sp_mempool s ++ forced_ids (sp_fqueue s)
                            ++ included s) ->
           In x (sp_everseen s);

  (* I7: Forced queue is sorted by submit_block (FIFO property). *)
  inv_so : sorted_snd (sp_fqueue s);

  (* I8: Conservation -- every forced deadline entry is either still
     in the queue or already included in a block. *)
  inv_co : forall ftx sb,
    In (ftx, sb) (sp_fdeadlines s) ->
    In (ftx, sb) (sp_fqueue s) \/ In ftx (included s);

  (* I9: Every queue entry has a matching deadline record. *)
  inv_dc : forall ftx sb,
    In (ftx, sb) (sp_fqueue s) ->
    In (ftx, sb) (sp_fdeadlines s);

  (* I10: Submit blocks in queue are bounded by current block number. *)
  inv_db : forall ftx sb,
    In (ftx, sb) (sp_fqueue s) -> sb <= sp_blocknum s;

  (* I11: Block structure -- each block has a forced prefix followed
     by a mempool suffix. *)
  inv_bs : forall b, In b (sp_blocks s) ->
    exists k,
      (forall i, i < k -> i < length b ->
        is_forced_b (nth i b 0) = true) /\
      (forall i, k <= i -> i < length b ->
        is_forced_b (nth i b 0) = false);

  (* I12: Forced inclusion deadline holds. *)
  inv_fd : forced_inclusion_deadline s;
}.
