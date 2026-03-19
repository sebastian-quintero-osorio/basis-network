---- MODULE MC_EvmExecutor ----

(*
 * Model instance for EvmExecutor specification.
 *
 * Finite constants chosen for exhaustive model checking:
 *   - 3 accounts: sufficient to test sender/receiver/third-party interactions
 *   - 2 storage slots: sufficient to test slot isolation
 *   - MaxValue 3: allows meaningful arithmetic (wrapping at 4) and transfers
 *   - 2 transactions: exposes inter-transaction state dependencies
 *   - 3 programs: cover all 5 opcodes (PUSH, ADD, SLOAD, SSTORE, CALL)
 *
 * [Source: User requirement -- "3 cuentas, 5 opcodes, 2 transacciones"]
 *)

EXTENDS EvmExecutor

\* Model values for accounts
CONSTANTS A1, A2, A3

\* Model values for storage slots
CONSTANTS S1, S2

\* --- Account set: 3 accounts ---
MC_Accounts == {A1, A2, A3}

\* --- Storage slots: 2 slots ---
MC_StorageSlots == {S1, S2}

\* --- Value domain: 0..3 ---
\* Chosen so that:
\*   - Initial balance 1 per account, total = 3
\*   - Transfers are meaningful (0 = no-op, 1 = full balance)
\*   - ADD wraps: (2+2) % 4 = 0, exercises modular arithmetic
MC_MaxValue == 3

\* --- Transaction budget: 2 ---
MC_MaxTransactions == 2

\* --- Programs: 3 well-formed programs covering all 5 opcodes ---
\*
\* Program 1 (Arithmetic): PUSH(1), PUSH(2), ADD
\*   Stack trace: [] -> [1] -> [1,2] -> [3]
\*   Tests: PUSH constant loading, ADD modular arithmetic
\*   No trace entries (no state-modifying ops)
\*
\* Program 2 (Storage): PUSH(1), SSTORE(S1), SLOAD(S1)
\*   Stack trace: [] -> [1] -> [] -> [1]
\*   Tests: SSTORE writes value to storage, SLOAD reads it back
\*   Trace entries: 1x SSTORE + 1x SLOAD = 2 entries
\*   Exercises SloadAfterSstoreConsistency invariant
\*
\* Program 3 (Call): PUSH(1), CALL(A3)
\*   Stack trace: [] -> [1] -> [0 or 1]
\*   Tests: CALL value transfer from executing contract to target
\*   Trace entries: 1x CALL
\*   Exercises balance conservation across CALL
MC_Programs == {
    << [type |-> "PUSH", arg |-> 1],
       [type |-> "PUSH", arg |-> 2],
       [type |-> "ADD"] >>,
    << [type |-> "PUSH", arg |-> 1],
       [type |-> "SSTORE", slot |-> S1],
       [type |-> "SLOAD",  slot |-> S1] >>,
    << [type |-> "PUSH", arg |-> 1],
       [type |-> "CALL", target |-> A3] >>
}

====
