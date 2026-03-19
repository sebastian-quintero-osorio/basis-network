(* ========================================== *)
(*     Spec.v -- TLA+ Specification Model      *)
(*     Faithful Translation of BasisBridge.tla  *)
(*     zkl2/proofs/units/2026-03-bridge        *)
(* ========================================== *)

(* This file translates the TLA+ specification of the BasisBridge
   contract and relayer into Coq definitions. The model captures the
   three-operation bridge lifecycle: Deposit, Withdrawal, Escape.

   Simplification: The model focuses on a SINGLE enterprise's bridge.
   This is sound because:
   - TLA+ uses per-enterprise mappings via EXCEPT
   - Solidity uses mapping(address => ...) for enterprise isolation
   - No bridge action modifies another enterprise's state
   - All safety invariants are per-enterprise

   The TLA+ models the combined L1 contract + off-chain relayer as a
   single state machine. Deposit is atomic (L1 lock + L2 credit)
   because the relayer is a trusted enterprise-operated component.

   Source: BasisBridge.tla (frozen in 0-input-spec/) *)

From BasisBridge Require Import Common.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
From Stdlib Require Import List.
Import ListNotations.

(* ========================================== *)
(*     STATE DEFINITION                        *)
(* ========================================== *)

(* Combined bridge state. Each field corresponds to a TLA+ variable.

   [Source: BasisBridge.tla, lines 40-52 -- VARIABLES]
   bridgeBalance          -> st_bridge
   l2Balances             -> st_l2
   lastFinalizedBals      -> st_last_fin
   pendingWithdrawals     -> st_pending
   finalizedWithdrawals   -> st_finalized
   claimedNullifiers      -> st_claimed
   escapeNullifiers       -> st_escaped
   escapeActive           -> st_escape_active
   sequencerAlive         -> st_seq_alive
   clock                  -> st_clock
   lastBatchTime          -> st_last_batch
   nextWid                -> st_next_wid *)
Record State := mkState {
  st_bridge        : nat;
  st_l2            : User -> nat;
  st_last_fin      : User -> nat;
  st_pending       : list Withdrawal;
  st_finalized     : list Withdrawal;
  st_claimed       : list Wid;
  st_escaped       : list User;
  st_escape_active : bool;
  st_seq_alive     : bool;
  st_clock         : nat;
  st_last_batch    : nat;
  st_next_wid      : Wid;
}.

(* ========================================== *)
(*     INITIAL STATE                           *)
(* ========================================== *)

(* [Source: BasisBridge.tla, lines 108-120 -- Init]
   All fields zeroed. Enterprise starts with empty bridge. *)
Definition init_state : State :=
  mkState 0 (fun _ => 0) (fun _ => 0) [] [] [] []
    false true 0 0 0.

(* ========================================== *)
(*     ACTION PRECONDITIONS                    *)
(* ========================================== *)

(* Deposit guard.
   [Source: BasisBridge.tla, lines 131-135] *)
Definition can_deposit (s : State) : Prop :=
  st_seq_alive s = true /\ st_escape_active s = false.

(* InitiateWithdrawal guard.
   [Source: BasisBridge.tla, lines 147-151] *)
Definition can_withdraw (s : State) (u : User) (amt : nat) : Prop :=
  st_seq_alive s = true /\ st_escape_active s = false /\
  amt > 0 /\ st_l2 s u >= amt.

(* FinalizeBatch guard.
   [Source: BasisBridge.tla, lines 164-166]
   Over-approximation: original guard checks pending /= {} or
   l2Balances /= lastFinalizedBals. Removing this makes the system
   more non-deterministic, which is safe for proving safety properties. *)
Definition can_finalize (s : State) : Prop :=
  st_seq_alive s = true.

(* ClaimWithdrawal guard.
   [Source: BasisBridge.tla, lines 180-183]
   Abstraction: Merkle proof verification abstracted (trusted crypto). *)
Definition can_claim (s : State) (w : Withdrawal) : Prop :=
  In w (st_finalized s) /\
  ~ In (w_wid w) (st_claimed s) /\
  st_bridge s >= w_amount w.

(* ActivateEscapeHatch guard.
   [Source: BasisBridge.tla, lines 200-204] *)
Definition can_escape_activate (s : State) (esc_timeout : nat) : Prop :=
  st_escape_active s = false /\
  st_seq_alive s = false /\
  st_last_batch s > 0 /\
  st_clock s - st_last_batch s >= esc_timeout.

(* EscapeWithdraw guard.
   [Source: BasisBridge.tla, lines 216-220]
   Abstraction: Merkle proof of account balance abstracted. *)
Definition can_escape_withdraw (s : State) (u : User) : Prop :=
  st_escape_active s = true /\
  st_last_fin s u > 0 /\
  ~ In u (st_escaped s) /\
  st_bridge s >= st_last_fin s u.

(* SequencerFail guard.
   [Source: BasisBridge.tla, lines 232-233] *)
Definition can_seq_fail (s : State) : Prop :=
  st_seq_alive s = true.

(* SequencerRecover guard.
   [Source: BasisBridge.tla, lines 242-244] *)
Definition can_seq_recover (s : State) : Prop :=
  st_seq_alive s = false /\ st_escape_active s = false.

(* Tick guard.
   [Source: BasisBridge.tla, lines 252-253] *)
Definition can_tick (s : State) (max_time : nat) : Prop :=
  st_clock s < max_time.

(* ========================================== *)
(*     ACTION DEFINITIONS                      *)
(* ========================================== *)

(* Deposit(u, amt): Lock ETH on L1, credit on L2.
   [Source: BasisBridge.tla, lines 131-140] *)
Definition do_deposit (s : State) (u : User) (amt : nat) : State :=
  mkState (st_bridge s + amt)
    (update_map (st_l2 s) u (st_l2 s u + amt))
    (st_last_fin s)
    (st_pending s) (st_finalized s) (st_claimed s) (st_escaped s)
    (st_escape_active s) (st_seq_alive s)
    (st_clock s) (st_last_batch s) (st_next_wid s).

(* InitiateWithdrawal(u, amt): Burn on L2, add to pending set.
   [Source: BasisBridge.tla, lines 146-158] *)
Definition do_withdraw (s : State) (u : User) (amt : nat) : State :=
  mkState (st_bridge s)
    (update_map (st_l2 s) u (st_l2 s u - amt))
    (st_last_fin s)
    (st_pending s ++ [mkW u amt (st_next_wid s)])
    (st_finalized s) (st_claimed s) (st_escaped s)
    (st_escape_active s) (st_seq_alive s)
    (st_clock s) (st_last_batch s) (st_next_wid s + 1).

(* FinalizeBatch: Move pending to finalized, snapshot L2 state.
   [Source: BasisBridge.tla, lines 164-173] *)
Definition do_finalize (s : State) : State :=
  mkState (st_bridge s)
    (st_l2 s) (st_l2 s)
    [] (st_finalized s ++ st_pending s)
    (st_claimed s) (st_escaped s)
    (st_escape_active s) (st_seq_alive s)
    (st_clock s) (st_clock s) (st_next_wid s).

(* ClaimWithdrawal(w): Verify Merkle proof, pay out, nullify.
   [Source: BasisBridge.tla, lines 180-188] *)
Definition do_claim (s : State) (w : Withdrawal) : State :=
  mkState (st_bridge s - w_amount w)
    (st_l2 s) (st_last_fin s)
    (st_pending s) (st_finalized s)
    (w_wid w :: st_claimed s) (st_escaped s)
    (st_escape_active s) (st_seq_alive s)
    (st_clock s) (st_last_batch s) (st_next_wid s).

(* ActivateEscapeHatch: Enable escape mode after timeout.
   [Source: BasisBridge.tla, lines 200-209] *)
Definition do_escape_activate (s : State) : State :=
  mkState (st_bridge s)
    (st_l2 s) (st_last_fin s)
    (st_pending s) (st_finalized s) (st_claimed s) (st_escaped s)
    true (st_seq_alive s)
    (st_clock s) (st_last_batch s) (st_next_wid s).

(* EscapeWithdraw(u): Withdraw finalized balance via state proof.
   [Source: BasisBridge.tla, lines 216-225] *)
Definition do_escape_withdraw (s : State) (u : User) : State :=
  mkState (st_bridge s - st_last_fin s u)
    (st_l2 s) (st_last_fin s)
    (st_pending s) (st_finalized s) (st_claimed s)
    (u :: st_escaped s)
    (st_escape_active s) (st_seq_alive s)
    (st_clock s) (st_last_batch s) (st_next_wid s).

(* SequencerFail: Sequencer goes offline.
   [Source: BasisBridge.tla, lines 232-238] *)
Definition do_seq_fail (s : State) : State :=
  mkState (st_bridge s)
    (st_l2 s) (st_last_fin s)
    (st_pending s) (st_finalized s) (st_claimed s) (st_escaped s)
    (st_escape_active s) false
    (st_clock s) (st_last_batch s) (st_next_wid s).

(* SequencerRecover: Sequencer comes back online.
   [Source: BasisBridge.tla, lines 242-249] *)
Definition do_seq_recover (s : State) : State :=
  mkState (st_bridge s)
    (st_l2 s) (st_last_fin s)
    (st_pending s) (st_finalized s) (st_claimed s) (st_escaped s)
    (st_escape_active s) true
    (st_clock s) (st_last_batch s) (st_next_wid s).

(* Tick: Discrete time step.
   [Source: BasisBridge.tla, lines 252-258] *)
Definition do_tick (s : State) : State :=
  mkState (st_bridge s)
    (st_l2 s) (st_last_fin s)
    (st_pending s) (st_finalized s) (st_claimed s) (st_escaped s)
    (st_escape_active s) (st_seq_alive s)
    (st_clock s + 1) (st_last_batch s) (st_next_wid s).

(* ========================================== *)
(*     STEP RELATION                           *)
(* ========================================== *)

(* Non-deterministic state transition. Models TLA+ Next.
   Parameterized by escape timeout and user set (from TLA+ constants).
   [Source: BasisBridge.tla, lines 264-273 -- Next] *)
Inductive step (et : nat) (users : list User) :
  State -> State -> Prop :=
  | step_deposit : forall s u amt,
      In u users -> amt > 0 -> can_deposit s ->
      step et users s (do_deposit s u amt)
  | step_withdraw : forall s u amt,
      In u users -> can_withdraw s u amt ->
      step et users s (do_withdraw s u amt)
  | step_finalize : forall s,
      can_finalize s ->
      step et users s (do_finalize s)
  | step_claim : forall s w,
      can_claim s w ->
      step et users s (do_claim s w)
  | step_escape_activate : forall s,
      can_escape_activate s et ->
      step et users s (do_escape_activate s)
  | step_escape_withdraw : forall s u,
      In u users -> can_escape_withdraw s u ->
      step et users s (do_escape_withdraw s u)
  | step_seq_fail : forall s,
      can_seq_fail s ->
      step et users s (do_seq_fail s)
  | step_seq_recover : forall s,
      can_seq_recover s ->
      step et users s (do_seq_recover s)
  | step_tick : forall s mt,
      can_tick s mt ->
      step et users s (do_tick s).

(* ========================================== *)
(*     SAFETY PROPERTIES                       *)
(* ========================================== *)

(* INV-B1 + INV-B6: No asset can be withdrawn more than once.
   Structural uniqueness of withdrawal IDs in the finalized set.
   Bridge balance non-negativity is trivially true for nat.

   [Source: BasisBridge.tla, lines 293-298] *)
Definition NoDoubleSpend (s : State) : Prop :=
  forall w1 w2,
    In w1 (st_finalized s) -> In w2 (st_finalized s) ->
    w_wid w1 = w_wid w2 -> w1 = w2.

(* INV-B2: Conservation of value across L1 and L2.
   Pre-escape: exact accounting identity.
   During escape: bridge covers obligations (solvency).

   [Source: BasisBridge.tla, lines 310-322] *)
Definition BalanceConservation (s : State) (users : list User) : Prop :=
  (* Pre-escape: exact accounting *)
  (st_escaped s = [] ->
    st_bridge s = sum_fun (st_l2 s) users
                + sum_amounts (st_pending s)
                + sum_amounts (unclaimed (st_finalized s) (st_claimed s)))
  /\
  (* During escape: solvency *)
  (st_escape_active s = true ->
    st_bridge s >= sum_fun (st_last_fin s)
                     (active_users users (st_escaped s))
                 + sum_amounts (unclaimed (st_finalized s) (st_claimed s))).

(* INV-B3: Escape hatch liveness. When escape mode is active, every
   user with a finalized balance can be covered by the bridge.

   [Source: BasisBridge.tla, lines 328-332] *)
Definition EscapeHatchLiveness (s : State) (users : list User) : Prop :=
  st_escape_active s = true ->
  forall u, In u users ->
    st_last_fin s u > 0 -> ~ In u (st_escaped s) ->
    st_bridge s >= st_last_fin s u.
