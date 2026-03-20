(* ========================================== *)
(*     Spec.v -- TLA+ Specification Model      *)
(*     Faithful Translation of HubAndSpoke.tla *)
(*     zkl2/proofs/units/2026-03-hub-and-spoke *)
(* ========================================== *)

(* This file translates the TLA+ specification of the Hub-and-Spoke
   cross-enterprise protocol into Coq definitions.

   4-phase cross-enterprise message lifecycle:
     Phase 1: PrepareMessage     (source enterprise)
     Phase 2: VerifyAtHub        (L1 hub contract)
     Phase 3: RespondToMessage   (destination enterprise)
     Phase 4: AttemptSettlement   (L1 hub contract)

   Messages are indexed by (source, dest, nonce) triples, matching
   the Solidity mapping(bytes32 => Message) where
   msgId = keccak256(source, dest, nonce).

   Source: HubAndSpoke.tla (frozen in 0-input-spec/) *)

From HubAndSpoke Require Import Common.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.

(* ========================================== *)
(*     STATE DEFINITION                        *)
(* ========================================== *)

(* Combined protocol state.
   [Source: HubAndSpoke.tla, lines 57-63 -- VARIABLES] *)
Record State := mkState {
  (* Per-enterprise state root version on L1.
     [Source: HubAndSpoke.tla, line 58 -- stateRoots] *)
  st_roots   : Enterprise -> nat;

  (* Message store indexed by (source, dest, nonce).
     None = no message at this key.
     [Source: HubAndSpoke.tla, line 59 -- messages]
     [Source: BasisHub.sol, line 102 -- messages mapping] *)
  st_msgs    : Enterprise -> Enterprise -> nat -> option Message;

  (* Consumed nonces per directed pair.
     [Source: HubAndSpoke.tla, line 60 -- usedNonces]
     [Source: BasisHub.sol, line 106 -- usedNonces mapping] *)
  st_nonces  : Enterprise -> Enterprise -> nat -> bool;

  (* Per-pair nonce counter (last allocated nonce).
     [Source: HubAndSpoke.tla, line 61 -- msgCounter]
     [Source: BasisHub.sol, line 110 -- messageCounters mapping] *)
  st_counter : Enterprise -> Enterprise -> nat;

  (* Current L1 block height.
     [Source: HubAndSpoke.tla, line 62 -- blockHeight] *)
  st_block   : nat;
}.

(* ========================================== *)
(*     INITIAL STATE                           *)
(* ========================================== *)

(* [Source: HubAndSpoke.tla, lines 153-158 -- Init]
   All roots at version 0, no messages, no consumed nonces,
   all counters at 0, block height 1. *)
Definition init_state : State :=
  mkState
    (fun _ => 0)
    (fun _ _ _ => None)
    (fun _ _ _ => false)
    (fun _ _ => 0)
    1.

(* ========================================== *)
(*     STEP RELATION                           *)
(* ========================================== *)

(* Non-deterministic state transition.
   Parameterized by timeout_blocks (TLA+ TimeoutBlocks constant).
   [Source: HubAndSpoke.tla, lines 391-420 -- Next, NextAdversarial] *)
Inductive step (tb : nat) : State -> State -> Prop :=

  (* --- Phase 1: Message Preparation ---
     [Source: HubAndSpoke.tla, lines 178-199 -- PrepareMessage]
     [Source: spoke.go, lines 68-103 -- PrepareMessage]
     [Source: BasisHub.sol, lines 248-280 -- prepareMessage]
     Enterprise 'src' creates a cross-enterprise message to 'dst'.
     Nonce allocated from per-pair counter. Source proof may be valid
     or invalid (nondeterministic, modeling adversarial enterprises). *)
  | step_prepare : forall s src dst pv n,
      src <> dst ->
      n = st_counter s src dst + 1 ->
      st_msgs s src dst n = None ->
      step tb s (mkState
        (st_roots s)
        (update_map3 (st_msgs s) src dst n
          (Some (mkMsg src dst n pv false (st_roots s src) 0 Prepared (st_block s))))
        (st_nonces s)
        (update_map2 (st_counter s) src dst n)
        (st_block s))

  (* --- Phase 2: Hub Verification (success) ---
     [Source: HubAndSpoke.tla, lines 217-231 -- VerifyAtHub, success]
     [Source: hub.go, lines 133-178 -- VerifyMessage, success]
     [Source: BasisHub.sol, lines 294-323 -- verifyMessage, success]
     All checks pass: root current, proof valid, nonce fresh.
     Nonce consumed. Status -> HubVerified. *)
  | step_verify_pass : forall s src dst n msg,
      st_msgs s src dst n = Some msg ->
      msg_status msg = Prepared ->
      msg_srcRootVer msg = st_roots s src ->
      msg_srcProofValid msg = true ->
      st_nonces s src dst n = false ->
      step tb s (mkState
        (st_roots s)
        (update_map3 (st_msgs s) src dst n (Some (set_status msg HubVerified)))
        (update_map3 (st_nonces s) src dst n true)
        (st_counter s)
        (st_block s))

  (* --- Phase 2: Hub Verification (failure) ---
     [Source: HubAndSpoke.tla, lines 232-235 -- VerifyAtHub, failure]
     At least one check fails. Nonce NOT consumed. Status -> Failed. *)
  | step_verify_fail : forall s src dst n msg,
      st_msgs s src dst n = Some msg ->
      msg_status msg = Prepared ->
      (msg_srcRootVer msg <> st_roots s src \/
       msg_srcProofValid msg = false \/
       st_nonces s src dst n = true) ->
      step tb s (mkState
        (st_roots s)
        (update_map3 (st_msgs s) src dst n (Some (set_status msg Failed)))
        (st_nonces s)
        (st_counter s)
        (st_block s))

  (* --- Phase 3: Response ---
     [Source: HubAndSpoke.tla, lines 248-257 -- RespondToMessage]
     [Source: spoke.go, lines 119-137 -- RespondToMessage]
     [Source: BasisHub.sol, lines 354-381 -- respondToMessage]
     Destination responds with proof validity and current root. *)
  | step_respond : forall s src dst n msg dpv,
      st_msgs s src dst n = Some msg ->
      msg_status msg = HubVerified ->
      step tb s (mkState
        (st_roots s)
        (update_map3 (st_msgs s) src dst n
          (Some (set_response msg dpv (st_roots s dst))))
        (st_nonces s)
        (st_counter s)
        (st_block s))

  (* --- Phase 4: Atomic Settlement (success) ---
     [Source: HubAndSpoke.tla, lines 279-297 -- AttemptSettlement, success]
     [Source: hub.go, lines 251-306 -- SettleMessage, success]
     [Source: BasisHub.sol, lines 401-426 -- settleMessage, success]
     BOTH proofs valid AND BOTH roots current.
     ATOMIC: Both state roots advance by 1 in a single step.
     There is NO intermediate state where one root is updated
     but the other is not.
     [Invariant: INV-CE6 AtomicSettlement] *)
  | step_settle_pass : forall s src dst n msg,
      st_msgs s src dst n = Some msg ->
      msg_status msg = Responded ->
      msg_srcProofValid msg = true ->
      msg_dstProofValid msg = true ->
      msg_srcRootVer msg = st_roots s src ->
      msg_dstRootVer msg = st_roots s dst ->
      step tb s (mkState
        (advance_roots (st_roots s) src dst)
        (update_map3 (st_msgs s) src dst n (Some (set_status msg Settled)))
        (st_nonces s)
        (st_counter s)
        (st_block s))

  (* --- Phase 4: Atomic Settlement (failure) ---
     [Source: HubAndSpoke.tla, lines 298-302 -- AttemptSettlement, failure]
     At least one check fails. NEITHER root changes. Status -> Failed. *)
  | step_settle_fail : forall s src dst n msg,
      st_msgs s src dst n = Some msg ->
      msg_status msg = Responded ->
      (msg_srcProofValid msg = false \/
       msg_dstProofValid msg = false \/
       msg_srcRootVer msg <> st_roots s src \/
       msg_dstRootVer msg <> st_roots s dst) ->
      step tb s (mkState
        (st_roots s)
        (update_map3 (st_msgs s) src dst n (Some (set_status msg Failed)))
        (st_nonces s)
        (st_counter s)
        (st_block s))

  (* --- Timeout ---
     [Source: HubAndSpoke.tla, lines 315-321 -- TimeoutMessage]
     [Source: hub.go, lines 331-357 -- TimeoutMessage]
     [Source: BasisHub.sol, lines 451-468 -- timeoutMessage]
     [Invariant: INV-CE9 TimeoutSafety] *)
  | step_timeout : forall s src dst n msg,
      st_msgs s src dst n = Some msg ->
      is_terminal (msg_status msg) = false ->
      st_block s >= msg_createdAt msg + tb ->
      step tb s (mkState
        (st_roots s)
        (update_map3 (st_msgs s) src dst n (Some (set_status msg TimedOut)))
        (st_nonces s)
        (st_counter s)
        (st_block s))

  (* --- Block Advance ---
     [Source: HubAndSpoke.tla, lines 328-331 -- AdvanceBlock] *)
  | step_advance_block : forall s,
      step tb s (mkState
        (st_roots s)
        (st_msgs s)
        (st_nonces s)
        (st_counter s)
        (st_block s + 1))

  (* --- Independent State Root Evolution ---
     [Source: HubAndSpoke.tla, lines 347-351 -- UpdateStateRoot]
     Creates race conditions: if a root changes between phases,
     the hub detects staleness and rejects the message. *)
  | step_update_root : forall s e,
      step tb s (mkState
        (update_map (st_roots s) e (st_roots s e + 1))
        (st_msgs s)
        (st_nonces s)
        (st_counter s)
        (st_block s)).

(* ========================================== *)
(*     SAFETY PROPERTIES                       *)
(* ========================================== *)

(* S1: CrossEnterpriseIsolation (INV-CE5).
   Messages carry only public metadata; source /= dest.
   The Message record has no field for private enterprise data.
   ZK zero-knowledge and Poseidon hiding are cryptographic axioms
   (not verified by this model).
   [Source: HubAndSpoke.tla, lines 450-458] *)
Definition CrossEnterpriseIsolation (s : State) : Prop :=
  forall src dst n msg,
    st_msgs s src dst n = Some msg -> src <> dst.

(* S2: AtomicSettlement (INV-CE6).
   Settled => both roots strictly advanced past recorded versions.
   Combined with the structural guarantee that AttemptSettlement updates
   both roots in a single atomic step (no interleaving), this proves
   no partial settlement exists in any reachable state.
   [Source: HubAndSpoke.tla, lines 476-480] *)
Definition AtomicSettlement (s : State) : Prop :=
  forall src dst n msg,
    st_msgs s src dst n = Some msg -> msg_status msg = Settled ->
    st_roots s src > msg_srcRootVer msg /\
    st_roots s dst > msg_dstRootVer msg.

(* S3: CrossRefConsistency (INV-CE7).
   Settled => both proofs valid. No settled message can have an invalid
   source or destination proof.
   [Source: HubAndSpoke.tla, lines 492-496] *)
Definition CrossRefConsistency (s : State) : Prop :=
  forall src dst n msg,
    st_msgs s src dst n = Some msg -> msg_status msg = Settled ->
    msg_srcProofValid msg = true /\ msg_dstProofValid msg = true.

(* S4: ReplayProtection (INV-CE8).
   Post-verified => nonce consumed. This prevents re-verification:
   step_verify_pass requires st_nonces = false, but once a message
   passes verification, the nonce is permanently consumed.
   [Source: HubAndSpoke.tla, lines 514-521] *)
Definition ReplayProtection (s : State) : Prop :=
  forall src dst n msg,
    st_msgs s src dst n = Some msg ->
    is_post_verified (msg_status msg) = true ->
    st_nonces s src dst n = true.

(* S5: TimeoutSafety (INV-CE9).
   TimedOut => deadline exceeded. No message reaches timed_out
   prematurely.
   [Source: HubAndSpoke.tla, lines 537-540] *)
Definition TimeoutSafety (s : State) (tb : nat) : Prop :=
  forall src dst n msg,
    st_msgs s src dst n = Some msg -> msg_status msg = TimedOut ->
    st_block s >= msg_createdAt msg + tb.

(* S6: HubNeutrality (INV-CE10).
   Post-verified => source proof valid. The hub only verifies
   proofs, never generates them. Every message that passes hub
   verification has a valid source proof.
   [Source: HubAndSpoke.tla, lines 558-561] *)
Definition HubNeutrality (s : State) : Prop :=
  forall src dst n msg,
    st_msgs s src dst n = Some msg ->
    is_post_verified (msg_status msg) = true ->
    msg_srcProofValid msg = true.
