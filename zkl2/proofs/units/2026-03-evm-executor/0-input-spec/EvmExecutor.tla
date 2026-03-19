---- MODULE EvmExecutor ----

(*
 * Formal specification of the EVM Execution Engine for Basis Network zkEVM L2.
 *
 * Models the EVM as a deterministic state machine that executes transactions
 * containing sequences of opcodes (ADD, PUSH, SLOAD, SSTORE, CALL), producing
 * execution traces suitable for ZK witness generation.
 *
 * The specification verifies three critical properties:
 *   1. Determinism: same tx + same state => same result and same trace
 *   2. TraceCompleteness: every state-modifying opcode generates a trace entry
 *   3. OpcodeCorrectness: each opcode produces output consistent with EVM semantics
 *
 * [Source: 0-input/REPORT.md -- "Minimal Geth Fork as EVM Execution Engine"]
 * [Source: 0-input/hypothesis.json -- RU-L1 EVM Executor hypothesis]
 * [Source: 0-input/code/main.go -- ZKTrace structure and tracer hooks]
 * [Source: 0-input/code/opcode_analysis.go -- Opcode ZK difficulty classification]
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

(* ========================================
            CONSTANTS
   ======================================== *)
CONSTANTS
    Accounts,         \* Set of account addresses (e.g., {A1, A2, A3})
    StorageSlots,     \* Set of storage slot identifiers (e.g., {S1, S2})
    MaxValue,         \* Upper bound for integer values (bounded for model checking)
    MaxTransactions,  \* Maximum number of transactions to model-check
    Programs          \* Set of well-formed programs (sequences of opcodes)

(* ========================================
            DERIVED TYPES
   ======================================== *)

\* [Source: 0-input/code/opcode_analysis.go -- 5 representative opcodes across ZK difficulty tiers]
\* Opcode instruction types covering all five modeled opcodes:
\*   PUSH  (ZKTrivial,     ~1 constraint)
\*   ADD   (ZKCheap,       ~30 R1CS constraints)
\*   SLOAD (ZKExpensive,   ~255 Poseidon ops)
\*   SSTORE(ZKExpensive,   ~255 Poseidon ops)
\*   CALL  (ZKVeryExpensive, ~20K R1CS constraints)
OpcodeSet ==
    [type: {"PUSH"}, arg: 0..MaxValue]
    \cup [type: {"ADD"}]
    \cup [type: {"SLOAD"}, slot: StorageSlots]
    \cup [type: {"SSTORE"}, slot: StorageSlots]
    \cup [type: {"CALL"}, target: Accounts]

\* [Source: 0-input/code/main.go, lines 33-48 -- ZKTrace struct]
\* [Source: 0-input/code/main.go, lines 50-85 -- StorageAccess, BalanceChange, etc.]
\* Trace entries record state-modifying operations for ZK witness generation.
\* Each entry captures the operation type and all values needed by the prover.
TraceEntrySet ==
    [op: {"SLOAD"}, account: Accounts, slot: StorageSlots, value: 0..MaxValue]
    \cup [op: {"SSTORE"}, account: Accounts, slot: StorageSlots,
          oldValue: 0..MaxValue, newValue: 0..MaxValue]
    \cup [op: {"CALL"}, from: Accounts, to: Accounts, value: 0..MaxValue]

(* ========================================
            VARIABLES
   ======================================== *)
VARIABLES
    accountState,     \* [Accounts -> [balance, nonce, storage]] -- global account state
    currentTx,        \* Currently executing transaction record (use phase to check validity)
    pc,               \* Program counter (1-indexed into current program)
    evmStack,         \* EVM execution stack (sequence of values; top = last element)
    trace,            \* Current execution trace (sequence of trace entries)
    completedResults, \* Set of completed execution records (for determinism verification)
    preSnapshot,      \* Account state snapshot taken at transaction start
    phase,            \* Execution phase: "idle" or "executing"
    txCount           \* Number of completed transactions

vars == << accountState, currentTx, pc, evmStack, trace,
           completedResults, preSnapshot, phase, txCount >>

(* ========================================
            TYPE INVARIANT
   ======================================== *)

\* [Why]: Ensures all variables remain within their declared domains across
\* every reachable state. Catches type-level bugs in the specification itself.
TypeOK ==
    /\ accountState \in [Accounts -> [balance: 0..MaxValue,
                                       nonce: 0..MaxValue,
                                       storage: [StorageSlots -> 0..MaxValue]]]
    /\ currentTx \in [from: Accounts, to: Accounts,
                       program: Seq(OpcodeSet), value: 0..MaxValue]
    /\ pc \in 0..10
    /\ evmStack \in Seq(0..MaxValue)
    /\ Len(evmStack) <= 10
    /\ trace \in Seq(TraceEntrySet)
    /\ phase \in {"idle", "executing"}
    /\ txCount \in 0..MaxTransactions

(* ========================================
            HELPER OPERATORS
   ======================================== *)

\* Placeholder transaction record used when no transaction is executing.
\* The phase variable ("idle" vs "executing") is the authoritative indicator
\* of whether currentTx holds a real transaction. NullTx ensures currentTx
\* always has the same record type, avoiding TLC fingerprinting errors.
NullTx == [from    |-> CHOOSE a \in Accounts : TRUE,
           to      |-> CHOOSE a \in Accounts : TRUE,
           program |-> <<>>,
           value   |-> 0]

(* ========================================
            INITIAL STATE
   ======================================== *)

\* [Source: 0-input/code/main.go, lines 210-221 -- setupAccounts]
\* Each account starts with balance 1, nonce 0, and zeroed storage.
\* Initial balance of 1 per account ensures value transfers are meaningful
\* while keeping the state space bounded (total value = |Accounts|).
Init ==
    /\ accountState = [a \in Accounts |->
                        [balance |-> 1,
                         nonce   |-> 0,
                         storage |-> [s \in StorageSlots |-> 0]]]
    /\ currentTx = NullTx
    /\ pc = 0
    /\ evmStack = <<>>
    /\ trace = <<>>
    /\ completedResults = {}
    /\ preSnapshot = [a \in Accounts |->
                       [balance |-> 1,
                        nonce   |-> 0,
                        storage |-> [s \in StorageSlots |-> 0]]]
    /\ phase = "idle"
    /\ txCount = 0

\* Guard: execution is active and pc points to a valid opcode.
\* The phase variable is the authoritative indicator of whether currentTx is valid.
Executing ==
    /\ phase = "executing"
    /\ pc >= 1
    /\ pc <= Len(currentTx.program)

\* Current opcode under the program counter
CurrentOp == currentTx.program[pc]

(* ========================================
            ACTIONS -- TRANSACTION LIFECYCLE
   ======================================== *)

\* [Source: 0-input/code/main.go, lines 249-254 -- CanTransfer and Transfer]
\* [Source: 0-input/code/main.go, lines 277-293 -- EVM execution loop]
\* [Source: 0-input/REPORT.md, "Key Architectural Decision"]
\*
\* Submit a new transaction for execution.
\* Guards: idle phase, tx budget remaining, sufficient balance, no overflow.
\* The value transfer (from -> to) occurs at submission, matching Geth behavior
\* where msg.value is transferred before code execution begins.
SubmitTx(from, to, program, value) ==
    /\ phase = "idle"
    /\ txCount < MaxTransactions
    /\ from \in Accounts
    /\ to \in Accounts
    /\ from /= to
    /\ program \in Programs
    /\ value \in 0..MaxValue
    /\ accountState[from].balance >= value            \* Sufficient balance
    /\ accountState[to].balance + value <= MaxValue   \* No overflow at receiver
    /\ accountState[from].nonce + 1 <= MaxValue       \* No nonce overflow
    \* Snapshot current state for determinism verification
    /\ preSnapshot' = accountState
    \* Set up execution context
    /\ currentTx' = [from |-> from, to |-> to, program |-> program, value |-> value]
    /\ pc' = 1
    /\ evmStack' = <<>>
    /\ trace' = <<>>
    \* Transfer msg.value and increment sender nonce
    /\ accountState' = [accountState EXCEPT
        ![from].balance = accountState[from].balance - value,
        ![to].balance   = accountState[to].balance + value,
        ![from].nonce   = accountState[from].nonce + 1]
    /\ phase' = "executing"
    /\ UNCHANGED << completedResults, txCount >>

(* ========================================
            ACTIONS -- OPCODE EXECUTION
   ======================================== *)

\* [Source: 0-input/code/opcode_analysis.go, line 147 -- PUSH0/PUSH1-32: ZKTrivial, ~1 constraint]
\* PUSH: Push a constant value onto the stack.
\* Not state-modifying -- no trace entry generated.
ExecPush ==
    /\ Executing
    /\ CurrentOp.type = "PUSH"
    /\ Len(evmStack) < 10                              \* Stack overflow guard
    /\ evmStack' = Append(evmStack, CurrentOp.arg)
    /\ pc' = pc + 1
    /\ UNCHANGED << accountState, currentTx, trace, completedResults,
                     preSnapshot, phase, txCount >>

\* [Source: 0-input/code/opcode_analysis.go, line 57 -- ADD: ZKCheap, ~30 R1CS constraints]
\* ADD: Pop two values, push their sum (modulo MaxValue+1).
\* Modular arithmetic models uint256 wrapping behavior.
\* Not state-modifying -- no trace entry generated.
ExecAdd ==
    /\ Executing
    /\ CurrentOp.type = "ADD"
    /\ Len(evmStack) >= 2                              \* Stack underflow guard
    /\ LET a == evmStack[Len(evmStack)]
           b == evmStack[Len(evmStack) - 1]
           result == (a + b) % (MaxValue + 1)
           poppedStack == SubSeq(evmStack, 1, Len(evmStack) - 2)
       IN
       /\ evmStack' = Append(poppedStack, result)
       /\ pc' = pc + 1
    /\ UNCHANGED << accountState, currentTx, trace, completedResults,
                     preSnapshot, phase, txCount >>

\* [Source: 0-input/code/opcode_analysis.go, lines 129-130 -- SLOAD: ZKExpensive, 255 Poseidon ops]
\* [Source: 0-input/code/main.go, lines 50-55 -- StorageAccess struct]
\* [Source: 0-input/REPORT.md, Observation 4 -- "trace format is critical"]
\* SLOAD: Load a value from the executing contract's storage onto the stack.
\* State-modifying for tracing purposes: generates an SLOAD trace entry recording
\* the account, slot, and value read. The prover needs this to construct
\* a Poseidon SMT inclusion proof.
ExecSload ==
    /\ Executing
    /\ CurrentOp.type = "SLOAD"
    /\ Len(evmStack) < 10                              \* Stack overflow guard
    /\ LET slot   == CurrentOp.slot
           target == currentTx.to                       \* Storage belongs to executing contract
           value  == accountState[target].storage[slot]
           traceEntry == [op      |-> "SLOAD",
                          account |-> target,
                          slot    |-> slot,
                          value   |-> value]
       IN
       /\ evmStack' = Append(evmStack, value)
       /\ trace' = Append(trace, traceEntry)
       /\ pc' = pc + 1
    /\ UNCHANGED << accountState, currentTx, completedResults,
                     preSnapshot, phase, txCount >>

\* [Source: 0-input/code/opcode_analysis.go, lines 131-135 -- SSTORE: ZKExpensive, 255 Poseidon ops]
\* [Source: 0-input/code/main.go, lines 122-127 -- OnStorageChange hook]
\* SSTORE: Pop a value from the stack and write it to the executing contract's storage.
\* Generates an SSTORE trace entry recording old and new values.
\* The prover needs both values to construct a Poseidon SMT update proof.
ExecSstore ==
    /\ Executing
    /\ CurrentOp.type = "SSTORE"
    /\ Len(evmStack) >= 1                              \* Stack underflow guard
    /\ LET slot     == CurrentOp.slot
           target   == currentTx.to                     \* Storage belongs to executing contract
           newValue == evmStack[Len(evmStack)]
           oldValue == accountState[target].storage[slot]
           traceEntry == [op       |-> "SSTORE",
                          account  |-> target,
                          slot     |-> slot,
                          oldValue |-> oldValue,
                          newValue |-> newValue]
           poppedStack == SubSeq(evmStack, 1, Len(evmStack) - 1)
       IN
       /\ evmStack' = poppedStack
       /\ accountState' = [accountState EXCEPT ![target].storage[slot] = newValue]
       /\ trace' = Append(trace, traceEntry)
       /\ pc' = pc + 1
    /\ UNCHANGED << currentTx, completedResults, preSnapshot, phase, txCount >>

\* [Source: 0-input/code/opcode_analysis.go, lines 163-164 -- CALL: ZKVeryExpensive, ~20K R1CS]
\* [Source: 0-input/code/main.go, lines 129-135 -- OnBalanceChange hook]
\* [Source: 0-input/REPORT.md, Observation 1 -- "Geth's EVM role is execution and trace generation"]
\*
\* CALL: Transfer value from the executing contract to a target account.
\* Simplified model: no recursive code execution at the target (equivalent to
\* calling an EOA). Pushes 1 on success, 0 on failure.
\* Always generates a CALL trace entry regardless of success/failure -- the prover
\* needs to verify the call was attempted with the correct parameters.
ExecCall ==
    /\ Executing
    /\ CurrentOp.type = "CALL"
    /\ Len(evmStack) >= 1                              \* Stack underflow guard
    /\ LET target           == CurrentOp.target
           executingAccount  == currentTx.to            \* Contract making the call
           sendValue         == evmStack[Len(evmStack)]
           poppedStack       == SubSeq(evmStack, 1, Len(evmStack) - 1)
           canSend           == accountState[executingAccount].balance >= sendValue
           noOverflow        == (executingAccount = target)
                                \/ (accountState[target].balance + sendValue <= MaxValue)
           callSucceeds      == canSend /\ noOverflow
           callTrace         == [op    |-> "CALL",
                                 from  |-> executingAccount,
                                 to    |-> target,
                                 value |-> sendValue]
           \* Compute new account state based on call success
           newAccountState ==
               IF callSucceeds /\ executingAccount /= target
               THEN [accountState EXCEPT
                   ![executingAccount].balance = @ - sendValue,
                   ![target].balance           = @ + sendValue]
               ELSE accountState
           callResult == IF callSucceeds THEN 1 ELSE 0
       IN
       /\ accountState' = newAccountState
       /\ evmStack' = Append(poppedStack, callResult)
       /\ trace' = Append(trace, callTrace)
       /\ pc' = pc + 1
    /\ UNCHANGED << currentTx, completedResults, preSnapshot, phase, txCount >>

(* ========================================
            ACTIONS -- TRANSACTION COMPLETION
   ======================================== *)

\* [Source: 0-input/code/main.go, lines 294-299 -- trace collection after execution]
\* Finish execution when pc advances past the last opcode.
\* Records a completed result containing the transaction, pre-state snapshot,
\* post-state, and the full execution trace. This record enables the
\* Determinism invariant to compare multiple executions.
FinishTx ==
    /\ phase = "executing"
    /\ pc > Len(currentTx.program)
    /\ LET result == [tx             |-> currentTx,
                      preState       |-> preSnapshot,
                      postState      |-> accountState,
                      executionTrace |-> trace]
       IN
       /\ completedResults' = completedResults \cup {result}
    /\ currentTx' = NullTx
    /\ pc' = 0
    /\ evmStack' = <<>>
    /\ trace' = <<>>
    /\ phase' = "idle"
    /\ txCount' = txCount + 1
    /\ UNCHANGED << accountState, preSnapshot >>

(* ========================================
            NEXT STATE RELATION
   ======================================== *)

\* [Source: 0-input/REPORT.md -- "EVM as state machine with SLOAD/SSTORE/CALL operations"]
\* The system nondeterministically chooses a transaction to submit (from the
\* finite set of programs, accounts, and values) or executes the next opcode
\* in the current transaction deterministically.
Next ==
    \/ \E from, to \in Accounts, program \in Programs, value \in 0..MaxValue :
        SubmitTx(from, to, program, value)
    \/ ExecPush
    \/ ExecAdd
    \/ ExecSload
    \/ ExecSstore
    \/ ExecCall
    \/ FinishTx

(* ========================================
            SPECIFICATION
   ======================================== *)

Spec == Init /\ [][Next]_vars

(* ========================================
            SAFETY PROPERTIES
   ======================================== *)

\* --- Property 1: Determinism ---
\* [Why]: The same transaction executed on the same pre-state MUST produce the
\* same post-state and the same execution trace. This is the foundational
\* requirement for ZK proving: the prover generates a witness for a specific
\* execution, and the verifier must be able to independently derive the same
\* result. If execution is nondeterministic, the proof is meaningless.
\* [Source: 0-input/hypothesis.json -- "100% Cancun opcode compatibility"]
Determinism ==
    \A r1, r2 \in completedResults :
        (r1.tx = r2.tx /\ r1.preState = r2.preState)
        => (r1.postState = r2.postState /\ r1.executionTrace = r2.executionTrace)

\* --- Property 2: Trace Completeness ---
\* [Why]: The execution trace MUST capture ALL state-modifying operations.
\* A missing trace entry means the ZK witness is incomplete: the prover cannot
\* generate a valid proof, or worse, generates a proof that omits a state
\* transition, allowing an invalid state root to be accepted on L1.
\* [Source: 0-input/code/main.go, lines 33-48 -- ZKTrace struct]
\* [Source: 0-input/REPORT.md, Observation 4 -- "trace format is critical"]

\* Helper: count opcodes of a given type in a program
CountInProgram(program, opType) ==
    Cardinality({i \in 1..Len(program) : program[i].type = opType})

\* Helper: count trace entries of a given operation type
CountInTrace(traceSeq, opType) ==
    Cardinality({i \in 1..Len(traceSeq) : traceSeq[i].op = opType})

TraceCompleteness ==
    \A r \in completedResults :
        \* Every SLOAD in the program produces exactly one SLOAD trace entry
        /\ CountInTrace(r.executionTrace, "SLOAD")  = CountInProgram(r.tx.program, "SLOAD")
        \* Every SSTORE in the program produces exactly one SSTORE trace entry
        /\ CountInTrace(r.executionTrace, "SSTORE") = CountInProgram(r.tx.program, "SSTORE")
        \* Every CALL in the program produces exactly one CALL trace entry
        /\ CountInTrace(r.executionTrace, "CALL")   = CountInProgram(r.tx.program, "CALL")

\* --- Property 3: Opcode Correctness ---
\* [Why]: Each opcode must produce output consistent with EVM semantics.
\* An incorrect opcode means the L2 state diverges from the expected state,
\* making the ZK proof invalid -- the prover would generate a proof for a
\* computation that does not match the EVM specification.
\* [Source: 0-input/code/opcode_analysis.go -- opcode semantics reference]

\* 3a. SLOAD-after-SSTORE consistency: if SLOAD follows SSTORE on the same
\* (account, slot) with no intervening SSTORE, the SLOAD must return the
\* written value. This verifies storage read/write coherence.
SloadAfterSstoreConsistency ==
    \A r \in completedResults :
        \A i, j \in 1..Len(r.executionTrace) :
            (/\ i < j
             /\ r.executionTrace[i].op = "SSTORE"
             /\ r.executionTrace[j].op = "SLOAD"
             /\ r.executionTrace[i].account = r.executionTrace[j].account
             /\ r.executionTrace[i].slot    = r.executionTrace[j].slot
             \* No intervening SSTORE to the same (account, slot)
             /\ ~ \E k \in (i+1)..(j-1) :
                    /\ r.executionTrace[k].op = "SSTORE"
                    /\ r.executionTrace[k].account = r.executionTrace[i].account
                    /\ r.executionTrace[k].slot    = r.executionTrace[i].slot)
            => r.executionTrace[j].value = r.executionTrace[i].newValue

\* 3b. SLOAD-from-initial-state: if no preceding SSTORE wrote to the same
\* (account, slot), the SLOAD must return the value from the pre-transaction
\* state snapshot. This verifies correct initialization.
SloadFromInitialState ==
    \A r \in completedResults :
        \A j \in 1..Len(r.executionTrace) :
            (/\ r.executionTrace[j].op = "SLOAD"
             /\ ~ \E i \in 1..(j-1) :
                    /\ r.executionTrace[i].op = "SSTORE"
                    /\ r.executionTrace[i].account = r.executionTrace[j].account
                    /\ r.executionTrace[i].slot    = r.executionTrace[j].slot)
            => r.executionTrace[j].value =
                r.preState[r.executionTrace[j].account].storage[r.executionTrace[j].slot]

\* --- Property 4: Balance Integrity ---
\* [Why]: Account balances must never go negative. The EVM guarantees this via
\* the CanTransfer check. A negative balance would mean value was created from
\* nothing -- a critical safety violation.
NoNegativeBalance ==
    \A a \in Accounts : accountState[a].balance >= 0

\* --- Property 5: Balance Conservation ---
\* [Why]: The total balance across all accounts must be conserved. Value is
\* neither created nor destroyed by transactions. This mirrors the fundamental
\* EVM invariant that ETH is neither minted nor burned during execution.

RECURSIVE SumBalances(_, _)
SumBalances(remaining, acc) ==
    IF remaining = {} THEN acc
    ELSE LET a == CHOOSE x \in remaining : TRUE
         IN SumBalances(remaining \ {a}, acc + accountState[a].balance)

TotalBalance == SumBalances(Accounts, 0)

\* Initial total: 1 per account (set in Init)
InitialTotalBalance == Cardinality(Accounts)

BalanceConservation ==
    TotalBalance = InitialTotalBalance

====
