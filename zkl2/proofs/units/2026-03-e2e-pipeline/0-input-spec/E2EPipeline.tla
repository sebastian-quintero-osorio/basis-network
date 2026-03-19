---- MODULE E2EPipeline ----

(***************************************************************************)
(* E2E Pipeline: L2-to-L1 Proving Pipeline for Basis Network zkEVM        *)
(*                                                                         *)
(* Models the end-to-end pipeline that transforms L2 transactions into     *)
(* verified ZK proofs on the Avalanche L1. Each batch progresses through   *)
(* five stages with automatic retry on failure:                            *)
(*                                                                         *)
(*   Pending -> Executed -> Witnessed -> Proved -> Submitted -> Finalized  *)
(*                                                                         *)
(* Any stage may fail. After MaxRetries exhausted, the batch transitions   *)
(* to a terminal Failed state. Failure at any stage must not corrupt L1    *)
(* state or leave partial artifacts on-chain.                              *)
(*                                                                         *)
(* [Source: 0-input/REPORT.md -- "E2E Pipeline Latency and Reliability"]   *)
(* [Source: 0-input/code/pipeline/orchestrator.go -- Orchestrator]         *)
(***************************************************************************)

EXTENDS Integers, FiniteSets

(* ======================================================================= *)
(*                         CONSTANTS                                       *)
(* ======================================================================= *)

CONSTANTS
    Batches,        \* Set of batch identifiers (finite for model checking)
    MaxRetries      \* Maximum retry attempts per stage before failure

(* ======================================================================= *)
(*                         STAGE DEFINITIONS                               *)
(* ======================================================================= *)

\* [Source: 0-input/code/pipeline/types.go, lines 26-42]
\* Pipeline stages are strictly ordered. A batch advances monotonically
\* through this sequence, or terminates at "failed".
\*
\* Stage machine from the reference implementation:
\*   Pending(0) -> Executed(1) -> Witnessed(2) -> Proved(3) ->
\*   Submitted(4) -> Finalized(5)
\*   Any non-terminal stage -> Failed(6) after MaxRetries exhausted.

StageSet == {"pending", "executed", "witnessed", "proved",
             "submitted", "finalized", "failed"}

TerminalStages == {"finalized", "failed"}

(* ======================================================================= *)
(*                         VARIABLES                                       *)
(* ======================================================================= *)

VARIABLES
    batchStage,     \* [Batches -> StageSet] current pipeline stage per batch
    retryCount,     \* [Batches -> 0..MaxRetries] retry attempts at current stage
    hasTrace,       \* [Batches -> BOOLEAN] valid execution trace produced
    hasWitness,     \* [Batches -> BOOLEAN] valid witness tables produced
    hasProof,       \* [Batches -> BOOLEAN] valid ZK proof (Groth16) produced
    proofOnL1       \* [Batches -> BOOLEAN] proof submitted and verified on L1

vars == << batchStage, retryCount, hasTrace, hasWitness, hasProof, proofOnL1 >>

(* ======================================================================= *)
(*                         TYPE INVARIANT                                  *)
(* ======================================================================= *)

TypeOK ==
    /\ batchStage \in [Batches -> StageSet]
    /\ retryCount \in [Batches -> 0..MaxRetries]
    /\ hasTrace   \in [Batches -> BOOLEAN]
    /\ hasWitness \in [Batches -> BOOLEAN]
    /\ hasProof   \in [Batches -> BOOLEAN]
    /\ proofOnL1  \in [Batches -> BOOLEAN]

(* ======================================================================= *)
(*                         INITIAL STATE                                   *)
(* ======================================================================= *)

\* [Source: 0-input/code/pipeline/types.go, NewBatchState()]
\* All batches begin at "pending" with zero retries and no artifacts.
Init ==
    /\ batchStage = [b \in Batches |-> "pending"]
    /\ retryCount = [b \in Batches |-> 0]
    /\ hasTrace   = [b \in Batches |-> FALSE]
    /\ hasWitness = [b \in Batches |-> FALSE]
    /\ hasProof   = [b \in Batches |-> FALSE]
    /\ proofOnL1  = [b \in Batches |-> FALSE]

(* ======================================================================= *)
(*                         ACTIONS -- EXECUTE STAGE                        *)
(* ======================================================================= *)

\* [Source: 0-input/code/pipeline/stages_sim.go, Execute()]
\* [Source: 0-input/REPORT.md, Section "Bottleneck Analysis" -- Execute 0.1%]
\*
\* Run L2 transactions through the EVM executor, collect execution traces.
\* Execution is fast (4K-12K tx/s) and rarely the bottleneck.
\* Produces: execution traces with NONCE_CHANGE, BALANCE_CHANGE, SSTORE, SLOAD.

ExecuteSuccess(b) ==
    /\ batchStage[b] = "pending"
    /\ batchStage' = [batchStage EXCEPT ![b] = "executed"]
    /\ hasTrace'   = [hasTrace EXCEPT ![b] = TRUE]
    /\ retryCount' = [retryCount EXCEPT ![b] = 0]
    /\ UNCHANGED << hasWitness, hasProof, proofOnL1 >>

\* [Source: 0-input/code/pipeline/orchestrator.go, executeWithRetry()]
\* Stage failure with retries remaining. Retry count increments.
\* Batch remains at current stage for re-attempt.
ExecuteFail(b) ==
    /\ batchStage[b] = "pending"
    /\ retryCount[b] < MaxRetries
    /\ retryCount' = [retryCount EXCEPT ![b] = @ + 1]
    /\ UNCHANGED << batchStage, hasTrace, hasWitness, hasProof, proofOnL1 >>

\* [Source: 0-input/code/pipeline/orchestrator.go, lines 200-202]
\* All retries exhausted. Batch transitions to terminal "failed" state.
\* No partial artifacts are produced (hasTrace remains FALSE).
ExecuteExhaust(b) ==
    /\ batchStage[b] = "pending"
    /\ retryCount[b] >= MaxRetries
    /\ batchStage' = [batchStage EXCEPT ![b] = "failed"]
    /\ UNCHANGED << retryCount, hasTrace, hasWitness, hasProof, proofOnL1 >>

(* ======================================================================= *)
(*                         ACTIONS -- WITNESS STAGE                        *)
(* ======================================================================= *)

\* [Source: 0-input/code/pipeline/stages_sim.go, Witness()]
\* [Source: 0-input/REPORT.md, "Go-Rust Boundary (Witness Generation)"]
\*
\* Generate witness tables from execution traces. Cross-language boundary:
\* Go orchestrator sends BatchTraceJSON via stdin to Rust witness generator,
\* receives WitnessResultJSON via stdout. Overhead: <2.5ms for 100 tx.
\*
\* Precondition: valid execution trace must exist (hasTrace = TRUE).

WitnessSuccess(b) ==
    /\ batchStage[b] = "executed"
    /\ hasTrace[b] = TRUE
    /\ batchStage' = [batchStage EXCEPT ![b] = "witnessed"]
    /\ hasWitness' = [hasWitness EXCEPT ![b] = TRUE]
    /\ retryCount' = [retryCount EXCEPT ![b] = 0]
    /\ UNCHANGED << hasTrace, hasProof, proofOnL1 >>

WitnessFail(b) ==
    /\ batchStage[b] = "executed"
    /\ hasTrace[b] = TRUE
    /\ retryCount[b] < MaxRetries
    /\ retryCount' = [retryCount EXCEPT ![b] = @ + 1]
    /\ UNCHANGED << batchStage, hasTrace, hasWitness, hasProof, proofOnL1 >>

\* Witness exhaustion: trace exists but witness generation failed permanently.
\* hasWitness remains FALSE. No downstream artifacts contaminated.
WitnessExhaust(b) ==
    /\ batchStage[b] = "executed"
    /\ retryCount[b] >= MaxRetries
    /\ batchStage' = [batchStage EXCEPT ![b] = "failed"]
    /\ UNCHANGED << retryCount, hasTrace, hasWitness, hasProof, proofOnL1 >>

(* ======================================================================= *)
(*                         ACTIONS -- PROVE STAGE                          *)
(* ======================================================================= *)

\* [Source: 0-input/code/pipeline/stages_sim.go, Prove()]
\* [Source: 0-input/REPORT.md, "Primary bottleneck: Proof generation at 71.3%"]
\*
\* Generate Groth16 ZK proof from witness tables. This is the pipeline
\* bottleneck: ~10s for 100 tx (71.3% of E2E latency). Failure modes
\* include OOM (prover memory exhaustion) and timeout.
\*
\* Precondition: valid witness must exist (hasWitness = TRUE).
\* Postcondition: hasProof = TRUE, proof contains 192 bytes (2*G1 + 1*G2).

ProveSuccess(b) ==
    /\ batchStage[b] = "witnessed"
    /\ hasWitness[b] = TRUE
    /\ batchStage' = [batchStage EXCEPT ![b] = "proved"]
    /\ hasProof'   = [hasProof EXCEPT ![b] = TRUE]
    /\ retryCount' = [retryCount EXCEPT ![b] = 0]
    /\ UNCHANGED << hasTrace, hasWitness, proofOnL1 >>

ProveFail(b) ==
    /\ batchStage[b] = "witnessed"
    /\ hasWitness[b] = TRUE
    /\ retryCount[b] < MaxRetries
    /\ retryCount' = [retryCount EXCEPT ![b] = @ + 1]
    /\ UNCHANGED << batchStage, hasTrace, hasWitness, hasProof, proofOnL1 >>

\* Prove exhaustion: witness exists but proof generation failed permanently.
\* hasProof remains FALSE. No L1 state is affected.
ProveExhaust(b) ==
    /\ batchStage[b] = "witnessed"
    /\ retryCount[b] >= MaxRetries
    /\ batchStage' = [batchStage EXCEPT ![b] = "failed"]
    /\ UNCHANGED << retryCount, hasTrace, hasWitness, hasProof, proofOnL1 >>

(* ======================================================================= *)
(*                         ACTIONS -- SUBMIT STAGE                         *)
(* ======================================================================= *)

\* [Source: 0-input/code/pipeline/stages_sim.go, Submit()]
\* [Source: 0-input/REPORT.md, "L1 Submission Time" -- 3 txs * ~1.3s each]
\*
\* Submit ZK proof to Basis Network L1 on Avalanche. The submission
\* encompasses three L1 transactions as a logical unit:
\*   1. commitBatch: commit batch data hash
\*   2. proveBatch:  submit ZK proof for on-chain verification
\*   3. executeBatch: execute state transition after proof verification
\*
\* [Source: 0-input/REPORT.md, BasisRollup.sol benchmarks -- 287K gas]
\*
\* Precondition: valid ZK proof must exist (hasProof = TRUE).
\* Postcondition: proofOnL1 = TRUE (all three L1 txs succeeded atomically).
\* Failure modes: L1 tx revert, network timeout, nonce conflict.

SubmitSuccess(b) ==
    /\ batchStage[b] = "proved"
    /\ hasProof[b] = TRUE
    /\ batchStage' = [batchStage EXCEPT ![b] = "submitted"]
    /\ proofOnL1'  = [proofOnL1 EXCEPT ![b] = TRUE]
    /\ retryCount' = [retryCount EXCEPT ![b] = 0]
    /\ UNCHANGED << hasTrace, hasWitness, hasProof >>

SubmitFail(b) ==
    /\ batchStage[b] = "proved"
    /\ hasProof[b] = TRUE
    /\ retryCount[b] < MaxRetries
    /\ retryCount' = [retryCount EXCEPT ![b] = @ + 1]
    /\ UNCHANGED << batchStage, hasTrace, hasWitness, hasProof, proofOnL1 >>

\* Submit exhaustion: proof exists but L1 submission failed permanently.
\* proofOnL1 remains FALSE. L1 state is not corrupted.
SubmitExhaust(b) ==
    /\ batchStage[b] = "proved"
    /\ retryCount[b] >= MaxRetries
    /\ batchStage' = [batchStage EXCEPT ![b] = "failed"]
    /\ UNCHANGED << retryCount, hasTrace, hasWitness, hasProof, proofOnL1 >>

(* ======================================================================= *)
(*                         ACTIONS -- FINALIZE                             *)
(* ======================================================================= *)

\* [Source: 0-input/code/pipeline/orchestrator.go, line 134]
\*
\* After successful L1 submission (commitBatch + proveBatch + executeBatch),
\* the batch is marked as finalized. This is a deterministic transition
\* with no failure mode: once the proof is verified on L1, finalization
\* is guaranteed by the Avalanche consensus (sub-second Snowman finality).
\*
\* Precondition: batch is submitted AND proof is verified on L1.
\* Postcondition: batch reaches terminal "finalized" state.

Finalize(b) ==
    /\ batchStage[b] = "submitted"
    /\ proofOnL1[b] = TRUE
    /\ batchStage' = [batchStage EXCEPT ![b] = "finalized"]
    /\ UNCHANGED << retryCount, hasTrace, hasWitness, hasProof, proofOnL1 >>

(* ======================================================================= *)
(*                         NEXT STATE RELATION                             *)
(* ======================================================================= *)

\* [Source: 0-input/code/pipeline/orchestrator.go, ProcessBatch()]
\* Non-deterministic choice: any non-terminal batch may take any enabled
\* action. This models concurrent batch processing where multiple batches
\* progress through the pipeline independently (MaxConcurrentBatches).

\* All batches have reached a terminal state. The pipeline is quiescent.
\* Explicit stuttering prevents TLC from reporting false deadlock.
Done ==
    /\ \A b \in Batches: batchStage[b] \in TerminalStages
    /\ UNCHANGED vars

Next ==
    \/ \E b \in Batches:
        \/ ExecuteSuccess(b)
        \/ ExecuteFail(b)
        \/ ExecuteExhaust(b)
        \/ WitnessSuccess(b)
        \/ WitnessFail(b)
        \/ WitnessExhaust(b)
        \/ ProveSuccess(b)
        \/ ProveFail(b)
        \/ ProveExhaust(b)
        \/ SubmitSuccess(b)
        \/ SubmitFail(b)
        \/ SubmitExhaust(b)
        \/ Finalize(b)
    \/ Done

(* ======================================================================= *)
(*                         FAIRNESS                                        *)
(* ======================================================================= *)

\* [Why]: Weak fairness on per-batch actions ensures liveness. If any action
\* for a given batch is continuously enabled, the system must eventually take
\* some action for that batch. This models the real orchestrator's guarantee
\* that no batch is starved: the event loop processes all active batches.
\*
\* Under this fairness condition, each batch eventually reaches a terminal
\* state (finalized or failed). Combined with retry exhaustion, this prevents
\* infinite stalling at any pipeline stage.

BatchAction(b) ==
    \/ ExecuteSuccess(b)
    \/ ExecuteFail(b)
    \/ ExecuteExhaust(b)
    \/ WitnessSuccess(b)
    \/ WitnessFail(b)
    \/ WitnessExhaust(b)
    \/ ProveSuccess(b)
    \/ ProveFail(b)
    \/ ProveExhaust(b)
    \/ SubmitSuccess(b)
    \/ SubmitFail(b)
    \/ SubmitExhaust(b)
    \/ Finalize(b)

Fairness == \A b \in Batches: WF_vars(BatchAction(b))

Spec == Init /\ [][Next]_vars /\ Fairness

(* ======================================================================= *)
(*                         SAFETY PROPERTIES                               *)
(* ======================================================================= *)

\* [Why]: Core integrity guarantee. Every finalized batch must have a complete
\* artifact chain (trace -> witness -> proof) AND the proof must be verified
\* on L1. This prevents the system from marking a batch as finalized without
\* actual cryptographic verification on the Avalanche L1.
\*
\* Derived from: information-theoretic requirement that L1 state transitions
\* must be backed by valid ZK proofs (soundness of the Groth16 proof system).
PipelineIntegrity ==
    \A b \in Batches:
        batchStage[b] = "finalized" =>
            /\ hasTrace[b]
            /\ hasWitness[b]
            /\ hasProof[b]
            /\ proofOnL1[b]

\* [Why]: Partial failure must not corrupt L1 state. A batch that fails at
\* any stage before L1 submission must leave zero footprint on L1. This is
\* the atomicity guarantee: either the full pipeline succeeds (all artifacts
\* produced, proof verified on L1) or the batch fails cleanly.
\*
\* Derived from: the L1 submission stage (commitBatch + proveBatch +
\* executeBatch) is treated as an atomic unit. If any sub-transaction fails,
\* the entire submission is retried. proofOnL1 is set TRUE only on full
\* success of all three L1 transactions.
AtomicFailure ==
    \A b \in Batches:
        batchStage[b] = "failed" => ~proofOnL1[b]

\* [Why]: Artifacts form a strict dependency chain matching the pipeline
\* stage ordering. Witness generation requires a valid trace; proof generation
\* requires a valid witness; L1 submission requires a valid proof.
\* No artifact can exist without its predecessor.
\*
\* Derived from: the causal chain of cryptographic commitments. The witness
\* commits to the execution trace; the proof commits to the witness; the L1
\* verification commits to the proof. Breaking this chain would allow
\* fabricated state transitions.
ArtifactDependencyChain ==
    \A b \in Batches:
        /\ hasWitness[b] => hasTrace[b]
        /\ hasProof[b]   => hasWitness[b]
        /\ proofOnL1[b]  => hasProof[b]

\* [Why]: Monotonic progress ensures that once an artifact is produced, the
\* batch stage is consistent with having that artifact. Artifacts are never
\* revoked. A batch with a trace has advanced past "pending"; a batch with
\* a proof has advanced past "witnessed"; a batch with L1 verification is
\* at "submitted" or "finalized" (never "failed", per AtomicFailure).
\*
\* Derived from: the irreversibility of cryptographic computation. Once a
\* valid proof exists, it remains valid. The pipeline cannot "undo" a proof.
MonotonicProgress ==
    \A b \in Batches:
        /\ hasTrace[b]   => batchStage[b] \in
            {"executed", "witnessed", "proved", "submitted", "finalized", "failed"}
        /\ hasWitness[b] => batchStage[b] \in
            {"witnessed", "proved", "submitted", "finalized", "failed"}
        /\ hasProof[b]   => batchStage[b] \in
            {"proved", "submitted", "finalized", "failed"}
        /\ proofOnL1[b]  => batchStage[b] \in
            {"submitted", "finalized"}

(* ======================================================================= *)
(*                         LIVENESS PROPERTIES                             *)
(* ======================================================================= *)

\* [Why]: Every batch eventually reaches a terminal state (finalized or
\* failed). The pipeline cannot stall indefinitely. Under weak fairness,
\* either the stage succeeds (advancing the batch) or retries exhaust
\* (failing the batch). No infinite loops.
\*
\* [Source: 0-input/REPORT.md, "Retry Analysis" -- 100% success at 30%
\* failure rate with exponential backoff, max 5 retries.]
\* In the model, non-deterministic failure allows TLC to explore both
\* success and failure paths for completeness.
EventualTermination ==
    \A b \in Batches:
        <>(batchStage[b] \in TerminalStages)

====
