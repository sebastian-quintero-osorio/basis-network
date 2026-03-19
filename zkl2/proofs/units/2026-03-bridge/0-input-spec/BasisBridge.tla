---- MODULE BasisBridge ----
(*
 * TLA+ Specification: L1-L2 Bridge with Escape Hatch
 *
 * Models the BasisBridge.sol contract and bridge relayer for Basis Network.
 * Three operations: Deposit (L1->L2), Withdrawal (L2->L1), Forced Withdrawal
 * (escape hatch when sequencer is offline beyond a configurable timeout).
 *
 * Target: zkl2
 * Date: 2026-03-19
 * Research Unit: bridge
 * Source: zkl2/specs/units/2026-03-bridge/0-input/
 *)

EXTENDS Integers, FiniteSets, TLC

(* ========================================
              CONSTANTS
   ======================================== *)

CONSTANTS
    Users,              \* Set of bridge users (e.g., {u1, u2})
    Amounts,            \* Set of possible deposit/withdrawal amounts (finite)
    EscapeTimeout,      \* Discrete time steps before escape hatch can activate
    MaxBridgeBalance,   \* Upper bound on bridge balance (finite model checking)
    MaxTime,            \* Upper bound on discrete clock (finite model checking)
    MaxWithdrawals      \* Upper bound on total withdrawal operations (finite model checking)

ASSUME /\ Users /= {}
       /\ Amounts \subseteq (Nat \ {0})
       /\ EscapeTimeout \in (Nat \ {0})
       /\ MaxBridgeBalance \in Nat
       /\ MaxTime \in Nat
       /\ MaxWithdrawals \in Nat

(* ========================================
              VARIABLES
   ======================================== *)

VARIABLES
    bridgeBalance,          \* Nat: total ETH locked in BasisBridge contract on L1
    l2Balances,             \* [Users -> Nat]: current L2 balance per user
    lastFinalizedBals,      \* [Users -> Nat]: L2 balance snapshot at last batch finalization
    pendingWithdrawals,     \* Set of [user, amount, wid]: L2 withdrawals awaiting batch
    finalizedWithdrawals,   \* Set of [user, amount, wid]: in executed batch, claimable on L1
    claimedNullifiers,      \* Set of Nat: withdrawal IDs already claimed (INV-B1)
    escapeNullifiers,       \* Set of Users: users who used escape hatch (INV-B6)
    escapeActive,           \* BOOLEAN: escape mode active for this enterprise
    sequencerAlive,         \* BOOLEAN: sequencer/relayer processing batches
    clock,                  \* Nat: discrete time counter
    lastBatchTime,          \* Nat: clock value at last batch execution
    nextWid                 \* Nat: monotonically increasing withdrawal ID counter

vars == << bridgeBalance, l2Balances, lastFinalizedBals,
           pendingWithdrawals, finalizedWithdrawals,
           claimedNullifiers, escapeNullifiers,
           escapeActive, sequencerAlive,
           clock, lastBatchTime, nextWid >>

(* ========================================
              HELPER OPERATORS
   ======================================== *)

\* [Why]: Sum of function values over a finite set of keys.
\*        Used for computing total L2 balances and total finalized balances.
RECURSIVE SumFun(_, _)
SumFun(f, S) ==
    IF S = {} THEN 0
    ELSE LET x == CHOOSE x \in S : TRUE
         IN f[x] + SumFun(f, S \ {x})

\* [Why]: Sum of .amount fields over a set of withdrawal records.
\*        Used for computing total pending and finalized withdrawal amounts.
RECURSIVE SumAmounts(_)
SumAmounts(S) ==
    IF S = {} THEN 0
    ELSE LET w == CHOOSE w \in S : TRUE
         IN w.amount + SumAmounts(S \ {w})

\* [Why]: Finalized withdrawals not yet claimed on L1.
UnclaimedFinalized == { w \in finalizedWithdrawals : w.wid \notin claimedNullifiers }

(* ========================================
              TYPE INVARIANT
   ======================================== *)

TypeOK ==
    /\ bridgeBalance \in 0..MaxBridgeBalance
    /\ l2Balances \in [Users -> Nat]
    /\ lastFinalizedBals \in [Users -> Nat]
    /\ \A w \in pendingWithdrawals :
        w \in [user: Users, amount: Amounts, wid: Nat]
    /\ \A w \in finalizedWithdrawals :
        w \in [user: Users, amount: Amounts, wid: Nat]
    /\ claimedNullifiers \subseteq Nat
    /\ escapeNullifiers \subseteq Users
    /\ escapeActive \in BOOLEAN
    /\ sequencerAlive \in BOOLEAN
    /\ clock \in 0..MaxTime
    /\ lastBatchTime \in 0..MaxTime
    /\ nextWid \in Nat

(* ========================================
              INITIAL STATE
   ======================================== *)

\* [Source: 0-input/code/BasisBridge.sol, constructor L186-L190]
Init ==
    /\ bridgeBalance = 0
    /\ l2Balances = [u \in Users |-> 0]
    /\ lastFinalizedBals = [u \in Users |-> 0]
    /\ pendingWithdrawals = {}
    /\ finalizedWithdrawals = {}
    /\ claimedNullifiers = {}
    /\ escapeNullifiers = {}
    /\ escapeActive = FALSE
    /\ sequencerAlive = TRUE
    /\ clock = 0
    /\ lastBatchTime = 0
    /\ nextWid = 0

(* ========================================
              PROTOCOL ACTIONS
   ======================================== *)

\* [Source: 0-input/code/BasisBridge.sol, deposit() L203-L225]
\* [Source: 0-input/REPORT.md, Section "Deposit (L1->L2)"]
\* Lock ETH on L1 bridge and credit equivalent on L2.
\* Abstraction: L1 lock + relayer L2 credit modeled as one atomic step.
\* This is safe because the relayer is a trusted enterprise-operated component.
Deposit(u, amt) ==
    /\ sequencerAlive                              \* Relayer requires live sequencer
    /\ ~escapeActive                               \* No deposits during escape
    /\ amt \in Amounts
    /\ bridgeBalance + amt <= MaxBridgeBalance      \* State space bound
    /\ bridgeBalance' = bridgeBalance + amt
    /\ l2Balances' = [l2Balances EXCEPT ![u] = @ + amt]
    /\ UNCHANGED << lastFinalizedBals, pendingWithdrawals, finalizedWithdrawals,
                    claimedNullifiers, escapeNullifiers, escapeActive,
                    sequencerAlive, clock, lastBatchTime, nextWid >>

\* [Source: 0-input/REPORT.md, Section "Withdrawal (L2->L1)"]
\* [Source: 0-input/code/relayer.go, ProcessWithdrawal() L300-L321]
\* User burns tokens on L2 and adds withdrawal to the pending set.
\* The withdrawal becomes claimable on L1 after batch finalization.
InitiateWithdrawal(u, amt) ==
    /\ sequencerAlive                              \* Requires live L2 for withdrawal tx
    /\ ~escapeActive                               \* No new withdrawals during escape
    /\ amt \in Amounts
    /\ l2Balances[u] >= amt                         \* Sufficient L2 balance
    /\ nextWid < MaxWithdrawals                     \* State space bound
    /\ l2Balances' = [l2Balances EXCEPT ![u] = @ - amt]
    /\ pendingWithdrawals' = pendingWithdrawals \cup
                             {[user |-> u, amount |-> amt, wid |-> nextWid]}
    /\ nextWid' = nextWid + 1
    /\ UNCHANGED << bridgeBalance, lastFinalizedBals, finalizedWithdrawals,
                    claimedNullifiers, escapeNullifiers, escapeActive,
                    sequencerAlive, clock, lastBatchTime >>

\* [Source: 0-input/code/BasisBridge.sol, submitWithdrawRoot() L400-L416]
\* [Source: 0-input/code/relayer.go, submitWithdrawRoots() L386-L411]
\* Sequencer finalizes a batch: pending withdrawals become claimable,
\* L2 state is snapshotted, and the escape hatch timer resets.
FinalizeBatch ==
    /\ sequencerAlive
    /\ pendingWithdrawals /= {} \/ l2Balances /= lastFinalizedBals
    /\ finalizedWithdrawals' = finalizedWithdrawals \cup pendingWithdrawals
    /\ pendingWithdrawals' = {}
    /\ lastFinalizedBals' = l2Balances              \* Snapshot current L2 state
    /\ lastBatchTime' = clock                       \* Reset escape hatch timer
    /\ UNCHANGED << bridgeBalance, l2Balances, claimedNullifiers,
                    escapeNullifiers, escapeActive, sequencerAlive,
                    clock, nextWid >>

\* [Source: 0-input/code/BasisBridge.sol, claimWithdrawal() L242-L302]
\* User claims a finalized withdrawal on L1 using Merkle proof.
\* Abstraction: Merkle proof verification is abstracted (trusted crypto).
\* INV-B1: nullifier prevents double-claiming.
\* INV-B4: only finalized (executed batch) withdrawals are claimable.
ClaimWithdrawal(w) ==
    /\ w \in finalizedWithdrawals                   \* INV-B4: must be in executed batch
    /\ w.wid \notin claimedNullifiers               \* INV-B1: not already claimed
    /\ bridgeBalance >= w.amount                    \* Bridge must be solvent
    /\ bridgeBalance' = bridgeBalance - w.amount
    /\ claimedNullifiers' = claimedNullifiers \cup {w.wid}
    /\ UNCHANGED << l2Balances, lastFinalizedBals, pendingWithdrawals,
                    finalizedWithdrawals, escapeNullifiers, escapeActive,
                    sequencerAlive, clock, lastBatchTime, nextWid >>

\* [Source: 0-input/code/BasisBridge.sol, activateEscapeHatch() L312-L335]
\* [Source: 0-input/REPORT.md, Section "Escape Hatch"]
\* Activates escape mode when sequencer has not processed batches within timeout.
\* INV-B3: enforces the timeout condition.
\* [Abstraction]: The contract checks only timeout, not sequencer liveness.
\*   We add ~sequencerAlive as a modeling simplification. The contract's
\*   activateEscapeHatch() relies on block.timestamp - lastBatchExecutionTime
\*   >= escapeTimeout, with no sequencer status check. In production, the admin
\*   could call recordBatchExecution() to refresh the timer while sequencer is
\*   alive. A RecordBatchExecution heartbeat action would remove this guard.
ActivateEscapeHatch ==
    /\ ~escapeActive                                \* Not already active
    /\ ~sequencerAlive                              \* See abstraction note above
    /\ lastBatchTime > 0                            \* At least one batch executed
    /\ clock - lastBatchTime >= EscapeTimeout       \* INV-B3: timeout condition
    /\ escapeActive' = TRUE
    /\ UNCHANGED << bridgeBalance, l2Balances, lastFinalizedBals,
                    pendingWithdrawals, finalizedWithdrawals,
                    claimedNullifiers, escapeNullifiers,
                    sequencerAlive, clock, lastBatchTime, nextWid >>

\* [Source: 0-input/code/BasisBridge.sol, escapeWithdraw() L347-L387]
\* User withdraws via escape hatch using last finalized state root.
\* Pays out the user's balance as of the last finalized batch snapshot.
\* INV-B6: each user can only escape-withdraw once (separate nullifier).
\* Abstraction: Merkle proof of account balance in state trie is abstracted.
EscapeWithdraw(u) ==
    /\ escapeActive                                 \* Escape mode must be active
    /\ lastFinalizedBals[u] > 0                     \* Must have balance in finalized state
    /\ u \notin escapeNullifiers                    \* INV-B6: one escape per user
    /\ bridgeBalance >= lastFinalizedBals[u]        \* Bridge must be solvent
    /\ bridgeBalance' = bridgeBalance - lastFinalizedBals[u]
    /\ escapeNullifiers' = escapeNullifiers \cup {u}
    /\ UNCHANGED << l2Balances, lastFinalizedBals, pendingWithdrawals,
                    finalizedWithdrawals, claimedNullifiers,
                    escapeActive, sequencerAlive, clock, lastBatchTime, nextWid >>

(* ========================================
              ENVIRONMENT ACTIONS
   ======================================== *)

\* Sequencer goes offline (Byzantine fault, crash, network partition).
SequencerFail ==
    /\ sequencerAlive
    /\ sequencerAlive' = FALSE
    /\ UNCHANGED << bridgeBalance, l2Balances, lastFinalizedBals,
                    pendingWithdrawals, finalizedWithdrawals,
                    claimedNullifiers, escapeNullifiers, escapeActive,
                    clock, lastBatchTime, nextWid >>

\* Sequencer recovers (only before escape activation).
\* Once escape is active, recovery requires governance action beyond this protocol.
SequencerRecover ==
    /\ ~sequencerAlive
    /\ ~escapeActive                                \* No recovery after escape
    /\ sequencerAlive' = TRUE
    /\ UNCHANGED << bridgeBalance, l2Balances, lastFinalizedBals,
                    pendingWithdrawals, finalizedWithdrawals,
                    claimedNullifiers, escapeNullifiers, escapeActive,
                    clock, lastBatchTime, nextWid >>

\* Discrete time step. Bounded for finite state exploration.
Tick ==
    /\ clock < MaxTime
    /\ clock' = clock + 1
    /\ UNCHANGED << bridgeBalance, l2Balances, lastFinalizedBals,
                    pendingWithdrawals, finalizedWithdrawals,
                    claimedNullifiers, escapeNullifiers, escapeActive,
                    sequencerAlive, lastBatchTime, nextWid >>

(* ========================================
              NEXT-STATE RELATION
   ======================================== *)

Next ==
    \/ \E u \in Users, amt \in Amounts : Deposit(u, amt)
    \/ \E u \in Users, amt \in Amounts : InitiateWithdrawal(u, amt)
    \/ FinalizeBatch
    \/ \E w \in finalizedWithdrawals : ClaimWithdrawal(w)
    \/ ActivateEscapeHatch
    \/ \E u \in Users : EscapeWithdraw(u)
    \/ SequencerFail
    \/ SequencerRecover
    \/ Tick

\* Fairness constraints for liveness verification.
\* Required for temporal property EscapeEventualWithdrawal.
Fairness ==
    /\ WF_vars(Tick)
    /\ WF_vars(ActivateEscapeHatch)
    /\ \A u \in Users : WF_vars(EscapeWithdraw(u))

Spec == Init /\ [][Next]_vars /\ Fairness

(* ========================================
              SAFETY PROPERTIES
   ======================================== *)

\* [Why]: INV-B1 + INV-B6 -- No asset can be withdrawn more than once.
\*        Structural uniqueness of withdrawal IDs in the finalized set,
\*        combined with the consequence that bridge balance never goes negative.
\*        A negative bridge balance would indicate a double-spend or
\*        over-withdrawal -- a critical solvency failure.
NoDoubleSpend ==
    \* Structural: each finalized withdrawal has a unique wid
    /\ \A w1, w2 \in finalizedWithdrawals :
        w1.wid = w2.wid => w1 = w2
    \* Consequence: bridge never pays out more than it received
    /\ bridgeBalance >= 0

\* [Why]: INV-B2 -- Conservation of value across L1 and L2.
\*        Before escape: exact accounting (every locked wei is traceable to an
\*        L2 balance, a pending withdrawal, or an unclaimed finalized withdrawal).
\*        During escape: solvency (bridge can cover all remaining obligations).
\*
\*        The inequality during escape reflects the known escape hatch gap:
\*        deposits made after the last finalization are not captured by the
\*        escape mechanism. Those funds remain locked in the bridge as excess.
\*        This is a documented limitation, not a bug (see REPORT.md Section
\*        "Escape Hatch" and Figueira arxiv 2503.23986).
BalanceConservation ==
    LET unclaimed == UnclaimedFinalized
        activeUsers == Users \ escapeNullifiers
    IN
    \* Pre-escape: exact accounting identity
    /\ (escapeNullifiers = {}) =>
        bridgeBalance = SumFun(l2Balances, Users)
                      + SumAmounts(pendingWithdrawals)
                      + SumAmounts(unclaimed)
    \* During/after escape: bridge covers finalized balances + unclaimed
    /\ escapeActive =>
        bridgeBalance >= SumFun(lastFinalizedBals, activeUsers)
                       + SumAmounts(unclaimed)

\* [Why]: INV-B3 -- When escape mode is active, every user with a finalized
\*        balance can individually be covered by the bridge. This guarantees
\*        that the escape hatch is not merely activatable but actually usable
\*        by every affected user.
EscapeHatchLiveness ==
    escapeActive =>
        \A u \in Users :
            (lastFinalizedBals[u] > 0 /\ u \notin escapeNullifiers) =>
                bridgeBalance >= lastFinalizedBals[u]

(* ========================================
              LIVENESS PROPERTY (TEMPORAL)
   ======================================== *)

\* [Why]: If the sequencer is permanently offline and escape is active,
\*        every user with a finalized balance eventually withdraws.
\*        Requires fairness on Tick, ActivateEscapeHatch, and EscapeWithdraw.
EscapeEventualWithdrawal ==
    \A u \in Users :
        (escapeActive /\ lastFinalizedBals[u] > 0 /\ u \notin escapeNullifiers)
        ~> (u \in escapeNullifiers)

====
