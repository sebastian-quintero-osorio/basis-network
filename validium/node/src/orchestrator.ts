/**
 * Enterprise Node Orchestrator -- Pipelined state machine.
 *
 * [Spec: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla]
 *
 * Integrates all verified components into a single service:
 *   - SparseMerkleTree (RU-V1): enterprise state management
 *   - TransactionQueue + WAL (RU-V4): crash-safe ingestion
 *   - BatchAggregator + BatchBuilder (RU-V4): HYBRID batch formation + witness
 *   - ZKProver (RU-V2): Groth16 proof generation via snarkjs
 *   - L1Submitter (RU-V3): StateCommitment.sol submission
 *   - DACProtocol (RU-V6): Shamir share distribution + attestation
 *
 * State machine (TLA+ direct mapping):
 *   Idle -> Receiving -> Batching -> Proving -> Submitting -> Idle
 *                                                         \-> Error -> Idle (via Retry)
 *
 * Pipelined ingestion: ReceiveTx is concurrent with Proving and Submitting.
 *
 * @module orchestrator
 */

import * as fs from "fs";
import * as path from "path";
import { SparseMerkleTree } from "./state";
import type { SerializedSMT } from "./state";
import { TransactionQueue } from "./queue";
import type { Transaction } from "./queue/types";
import { BatchAggregator, buildBatchCircuitInput } from "./batch";
import type { Batch } from "./batch/types";
import { ZKProver } from "./prover";
import { L1Submitter } from "./submitter";
import { DACProtocol } from "./da";
import {
  NodeState,
  RECEIVING_STATES,
  NodeError,
  NodeErrorCode,
  type NodeConfig,
  type NodeStatus,
  type BatchRecord,
  type ProofResult,
} from "./types";
import { createLogger } from "./logger";

const log = createLogger("orchestrator");

/** Package version (read from package.json at build time). */
const VERSION = "0.1.0";

// ---------------------------------------------------------------------------
// Orchestrator Dependencies
// ---------------------------------------------------------------------------

export interface OrchestratorDeps {
  readonly smt: SparseMerkleTree;
  readonly queue: TransactionQueue;
  readonly aggregator: BatchAggregator;
  readonly prover: ZKProver;
  readonly submitter: L1Submitter;
  readonly dac: DACProtocol;
  readonly config: NodeConfig;
}

// ---------------------------------------------------------------------------
// EnterpriseNodeOrchestrator
// ---------------------------------------------------------------------------

/**
 * The Enterprise Node Orchestrator: pipelined state machine that processes
 * enterprise transactions through ZK proving and L1 submission.
 *
 * [Spec: All variables, Init, Next, all actions]
 */
export class EnterpriseNodeOrchestrator {
  // -- State machine --
  // [Spec: nodeState \in States]
  private state: NodeState = NodeState.Idle;

  // -- Modules --
  private smt: SparseMerkleTree;
  private readonly queue: TransactionQueue;
  private readonly aggregator: BatchAggregator;
  private readonly prover: ZKProver;
  private readonly submitter: L1Submitter;
  private readonly dac: DACProtocol;
  private readonly config: NodeConfig;

  // -- Tracking --
  // [Spec: l1State -- last confirmed state, represented by serialized SMT]
  private smtCheckpoint: SerializedSMT | null = null;
  // [Spec: crashCount]
  private crashCount: number = 0;
  // Batch history for API queries
  private readonly batchHistory: Map<string, BatchRecord> = new Map();
  // Batch counter for confirmed batches
  private batchesProcessed: number = 0;
  // Startup time for uptime calculation
  private readonly startedAt: number = Date.now();

  // -- Batch loop --
  private batchLoopTimer: ReturnType<typeof setInterval> | null = null;
  private batchCycleRunning: boolean = false;
  private running: boolean = false;

  constructor(deps: OrchestratorDeps) {
    this.smt = deps.smt;
    this.queue = deps.queue;
    this.aggregator = deps.aggregator;
    this.prover = deps.prover;
    this.submitter = deps.submitter;
    this.dac = deps.dac;
    this.config = deps.config;

    log.info("Orchestrator created", {
      enterpriseId: this.config.enterpriseId,
      maxBatchSize: this.config.maxBatchSize,
      smtDepth: this.config.smtDepth,
    });
  }

  // =========================================================================
  // Public API
  // =========================================================================

  /**
   * Accept a transaction from PLASMA/Trace adapter.
   *
   * [Spec: ReceiveTx(tx)]
   *   Precondition: nodeState \in {"Idle", "Receiving", "Proving", "Submitting"}
   *   WAL-first: wal' = Append(wal, tx), txQueue' = Append(txQueue, tx)
   *   State transition: IF nodeState = "Idle" THEN "Receiving" ELSE unchanged
   *
   * Pipelined: accepts transactions during Proving and Submitting states.
   *
   * @param tx - Enterprise transaction
   * @returns WAL sequence number
   * @throws NodeError if node cannot accept transactions in current state
   */
  submitTransaction(tx: Transaction): number {
    if (!RECEIVING_STATES.has(this.state)) {
      throw new NodeError(
        NodeErrorCode.INVALID_STATE,
        `Cannot accept transactions in state ${this.state}`
      );
    }

    // [Spec: wal' = Append(wal, tx), txQueue' = Append(txQueue, tx)]
    const seq = this.queue.enqueue(tx);

    // [Spec: nodeState' = IF nodeState = "Idle" THEN "Receiving" ELSE nodeState]
    if (this.state === NodeState.Idle) {
      this.state = NodeState.Receiving;
      log.info("State: Idle -> Receiving");
    }

    log.debug("Transaction accepted", {
      txHash: tx.txHash,
      seq,
      state: this.state,
    });

    return seq;
  }

  /**
   * Start the batch monitoring loop.
   *
   * Periodically checks if a batch should be formed and triggers the full
   * batch cycle: FormBatch -> GenerateWitness -> GenerateProof -> Submit -> Confirm.
   */
  start(): void {
    if (this.running) return;
    this.running = true;

    this.batchLoopTimer = setInterval(() => {
      void this.batchLoopTick();
    }, this.config.batchLoopIntervalMs);

    log.info("Batch monitoring loop started", {
      intervalMs: this.config.batchLoopIntervalMs,
    });
  }

  /**
   * Stop the batch monitoring loop (graceful shutdown).
   *
   * Does NOT drain the queue -- pending transactions remain in the WAL
   * for recovery on next startup.
   */
  stop(): void {
    this.running = false;
    if (this.batchLoopTimer) {
      clearInterval(this.batchLoopTimer);
      this.batchLoopTimer = null;
    }
    log.info("Batch monitoring loop stopped");
  }

  /**
   * Recover from crash: restore SMT from checkpoint and replay WAL.
   *
   * [Spec: Retry]
   *   smtState' = l1State
   *   txQueue' = SubSeq(wal, walCheckpoint + 1, Len(wal))
   *   nodeState' = "Idle"
   *
   * Called on startup (recovers from previous crash) and after errors.
   */
  async recover(): Promise<void> {
    log.info("Starting recovery");

    // [Spec: smtState' = l1State -- restore SMT from last confirmed checkpoint]
    if (this.smtCheckpoint) {
      this.smt = await SparseMerkleTree.deserialize(this.smtCheckpoint);
      log.info("SMT restored from checkpoint", {
        root: this.smt.root.toString(16).slice(0, 16) + "...",
      });
    } else {
      // Try loading from disk checkpoint
      const loaded = this.loadSmtCheckpoint();
      if (loaded) {
        this.smt = await SparseMerkleTree.deserialize(loaded);
        this.smtCheckpoint = loaded;
        log.info("SMT restored from disk checkpoint");
      }
    }

    // [Spec: txQueue' = SubSeq(wal, walCheckpoint + 1, Len(wal))]
    const recovered = this.queue.recover();
    if (recovered > 0) {
      log.info("WAL replay recovered transactions", { count: recovered });
    }

    // [Spec: nodeState' = "Idle"]
    this.state = NodeState.Idle;

    // [Spec: CheckQueue -- if queue non-empty, transition to Receiving]
    if (this.queue.size > 0) {
      this.state = NodeState.Receiving;
      log.info("Recovered transactions in queue, state -> Receiving", {
        queueSize: this.queue.size,
      });
    }

    log.info("Recovery complete", {
      state: this.state,
      queueSize: this.queue.size,
    });
  }

  /**
   * Get current node status for health check and monitoring.
   */
  getStatus(): NodeStatus {
    return {
      state: this.state,
      queueDepth: this.queue.size,
      batchesProcessed: this.batchesProcessed,
      lastConfirmedRoot: this.submitter.getLastConfirmedRoot(),
      uptimeMs: Date.now() - this.startedAt,
      crashCount: this.crashCount,
      enterpriseId: this.config.enterpriseId,
      version: VERSION,
    };
  }

  /**
   * Get batch record by ID.
   */
  getBatch(batchId: string): BatchRecord | undefined {
    return this.batchHistory.get(batchId);
  }

  /**
   * Get all batch records (most recent first).
   */
  getAllBatches(): BatchRecord[] {
    return Array.from(this.batchHistory.values()).reverse();
  }

  /**
   * Current state (for testing and monitoring).
   */
  getState(): NodeState {
    return this.state;
  }

  // =========================================================================
  // Batch Processing Loop
  // =========================================================================

  /**
   * Single tick of the batch monitoring loop.
   *
   * Checks if conditions are met for batch formation and triggers the
   * full batch cycle. Only one cycle runs at a time (state machine guard).
   */
  private async batchLoopTick(): Promise<void> {
    // Guard: only one batch cycle at a time
    if (this.batchCycleRunning) return;

    // [Spec: CheckQueue -- Idle with non-empty queue -> Receiving]
    if (this.state === NodeState.Idle && this.queue.size > 0) {
      this.state = NodeState.Receiving;
      log.info("State: Idle -> Receiving (CheckQueue)");
    }

    // Guard: only form batches in Receiving state
    if (this.state !== NodeState.Receiving) return;

    // Guard: check HYBRID trigger (size OR time)
    if (!this.aggregator.shouldFormBatch()) return;

    this.batchCycleRunning = true;
    try {
      await this.processBatchCycle();
    } catch (error) {
      log.error("Batch cycle error (unexpected)", {
        error: String(error),
      });
    } finally {
      this.batchCycleRunning = false;
    }
  }

  /**
   * Full batch processing cycle: FormBatch -> GenerateWitness -> GenerateProof
   * -> SubmitBatch -> ConfirmBatch.
   *
   * Maps directly to TLA+ actions:
   *   1. FormBatch: Receiving -> Batching
   *   2. GenerateWitness: Batching -> Proving
   *   3. GenerateProof: Proving -> Submitting
   *   4. SubmitBatch + ConfirmBatch: Submitting -> Idle
   *
   * On error: transitions to Error state and triggers recovery (Retry action).
   */
  private async processBatchCycle(): Promise<void> {
    // -----------------------------------------------------------------------
    // 1. FormBatch: Receiving -> Batching
    // [Spec: FormBatch]
    //   batchTxs' = SubSeq(txQueue, 1, batchSize)
    //   txQueue' = SubSeq(txQueue, batchSize + 1, Len(txQueue))
    //   batchPrevSmt' = smtState
    //   nodeState' = "Batching"
    // -----------------------------------------------------------------------
    this.state = NodeState.Batching;
    log.info("State: Receiving -> Batching");

    const batch = this.aggregator.formBatch();
    if (!batch) {
      this.state = NodeState.Receiving;
      return;
    }

    const batchRecord: BatchRecord = {
      batchId: batch.batchId,
      batchNum: batch.batchNum,
      txCount: batch.txCount,
      prevStateRoot: this.smt.root.toString(16),
      newStateRoot: "",
      status: "forming",
      formedAt: batch.formedAt,
    };
    this.batchHistory.set(batch.batchId, batchRecord);

    log.info("Batch formed", {
      batchId: batch.batchId.slice(0, 16) + "...",
      batchNum: batch.batchNum,
      txCount: batch.txCount,
    });

    try {
      // ---------------------------------------------------------------------
      // 2. GenerateWitness: Batching -> Proving
      // [Spec: GenerateWitness]
      //   smtState' = smtState \cup BatchTxSet
      //   nodeState' = "Proving"
      // ---------------------------------------------------------------------
      const witness = await buildBatchCircuitInput(batch, this.smt);

      batchRecord.prevStateRoot = witness.prevStateRoot;
      batchRecord.newStateRoot = witness.newStateRoot;
      batchRecord.status = "proving";

      this.state = NodeState.Proving;
      log.info("State: Batching -> Proving", {
        prevRoot: witness.prevStateRoot.slice(0, 16) + "...",
        newRoot: witness.newStateRoot.slice(0, 16) + "...",
      });

      // ---------------------------------------------------------------------
      // 3. GenerateProof: Proving -> Submitting
      // [Spec: GenerateProof]
      //   nodeState' = "Submitting"
      // ---------------------------------------------------------------------
      const proof = await this.prover.prove(witness);

      batchRecord.status = "submitting";
      this.state = NodeState.Submitting;
      log.info("State: Proving -> Submitting", {
        proofDurationMs: proof.durationMs,
      });

      // ---------------------------------------------------------------------
      // 4. SubmitBatch + ConfirmBatch: Submitting -> Idle
      // [Spec: SubmitBatch]
      //   dataExposed' = dataExposed \cup {"proof_signals", "dac_shares"}
      // [Spec: ConfirmBatch]
      //   l1State' = smtState
      //   walCheckpoint' = walCheckpoint + Len(batchTxs)
      //   batchTxs' = <<>>
      //   nodeState' = "Idle"
      // ---------------------------------------------------------------------

      // DAC distribution (non-blocking for MVP)
      // [Spec: dataExposed' = dataExposed \cup {"dac_shares"}]
      this.distributeToDac(batch, witness.newStateRoot);

      // L1 submission (blocking -- waits for on-chain confirmation)
      // [Spec: dataExposed' = dataExposed \cup {"proof_signals"}]
      const submission = await this.submitter.submit(
        proof,
        witness.prevStateRoot,
        witness.newStateRoot,
        batch.batchNum
      );

      // [Spec: ConfirmBatch -- l1State' = smtState]
      // Save SMT checkpoint (represents the new l1State)
      this.smtCheckpoint = this.smt.serialize();
      this.saveSmtCheckpoint(this.smtCheckpoint);

      // [Spec: walCheckpoint' = walCheckpoint + Len(batchTxs)]
      this.aggregator.onBatchProcessed(batch.batchId);

      // Update batch record
      batchRecord.status = "confirmed";
      batchRecord.l1TxHash = submission.txHash;
      batchRecord.confirmedAt = Date.now();
      this.batchesProcessed++;

      // [Spec: nodeState' = "Idle"]
      this.state = NodeState.Idle;
      log.info("State: Submitting -> Idle (batch confirmed)", {
        batchId: batch.batchId.slice(0, 16) + "...",
        l1TxHash: submission.txHash,
        batchesProcessed: this.batchesProcessed,
      });

      // [Spec: CheckQueue -- if queue non-empty, go to Receiving]
      if (this.queue.size > 0) {
        this.state = NodeState.Receiving;
        log.info("State: Idle -> Receiving (CheckQueue, pipelined txs)");
      }
    } catch (error) {
      // -----------------------------------------------------------------
      // Error: L1Reject or Crash
      // [Spec: L1Reject / Crash]
      //   txQueue' = <<>>
      //   batchTxs' = <<>>
      //   batchPrevSmt' = {}
      //   smtState' = l1State
      //   nodeState' = "Error"
      // -----------------------------------------------------------------
      await this.handleBatchError(batch, error);
    }
  }

  /**
   * Handle batch processing error: transition to Error state and recover.
   *
   * [Spec: L1Reject + Retry (combined for implementation efficiency)]
   */
  private async handleBatchError(
    batch: Batch,
    error: unknown
  ): Promise<void> {
    const errorMsg = error instanceof Error ? error.message : String(error);
    log.error("Batch processing failed", {
      batchId: batch.batchId.slice(0, 16) + "...",
      error: errorMsg,
    });

    // Update batch record
    const record = this.batchHistory.get(batch.batchId);
    if (record) {
      record.status = "failed";
    }

    // [Spec: nodeState' = "Error"]
    this.state = NodeState.Error;
    this.crashCount++;

    // [Spec: Retry -- automatic recovery]
    log.info("State: -> Error, initiating recovery");
    await this.recover();
  }

  // =========================================================================
  // DAC Integration
  // =========================================================================

  /**
   * Distribute batch data to DAC nodes via Shamir secret sharing.
   *
   * [Spec: SubmitBatch -- dataExposed' = dataExposed \cup {"dac_shares"}]
   *
   * Synchronous: DACProtocol.distribute() and collectAttestations() are
   * synchronous operations (in-memory Shamir splitting and attestation).
   */
  private distributeToDac(batch: Batch, newStateRoot: string): void {
    try {
      const batchData = Buffer.from(
        JSON.stringify({
          batchId: batch.batchId,
          batchNum: batch.batchNum,
          transactions: batch.transactions,
          newStateRoot,
        })
      );

      const distribution = this.dac.distribute(batch.batchId, batchData);
      log.info("DAC distribution complete", {
        batchId: batch.batchId.slice(0, 16) + "...",
        commitment: distribution.commitment.slice(0, 16) + "...",
        durationMs: distribution.durationMs,
      });

      const attestation = this.dac.collectAttestations(
        batch.batchId,
        distribution.commitment
      );
      log.info("DAC attestations collected", {
        batchId: batch.batchId.slice(0, 16) + "...",
        certState: attestation.certificate.state,
        signatureCount: attestation.certificate.signatureCount,
      });
    } catch (error: unknown) {
      log.warn("DAC distribution/attestation failed (non-critical)", {
        batchId: batch.batchId.slice(0, 16) + "...",
        error: String(error),
      });
    }
  }

  // =========================================================================
  // SMT Checkpoint Persistence
  // =========================================================================

  /** Path for the SMT checkpoint file. */
  private get smtCheckpointPath(): string {
    return path.join(this.config.walDir, "smt-checkpoint.json");
  }

  /**
   * Save SMT checkpoint to disk (atomic write via temp + rename).
   *
   * [Spec: l1State is durable (on-chain). The checkpoint is our local
   *  representation, used to restore smtState = l1State on recovery.]
   */
  private saveSmtCheckpoint(data: SerializedSMT): void {
    try {
      const dir = path.dirname(this.smtCheckpointPath);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }

      const tmpPath = this.smtCheckpointPath + ".tmp";
      fs.writeFileSync(tmpPath, JSON.stringify(data), "utf-8");
      fs.renameSync(tmpPath, this.smtCheckpointPath);

      log.debug("SMT checkpoint saved", {
        path: this.smtCheckpointPath,
        entryCount: data.entryCount,
      });
    } catch (error) {
      log.warn("Failed to save SMT checkpoint", {
        error: String(error),
      });
    }
  }

  /**
   * Load SMT checkpoint from disk.
   */
  private loadSmtCheckpoint(): SerializedSMT | null {
    try {
      if (!fs.existsSync(this.smtCheckpointPath)) {
        return null;
      }
      const raw = fs.readFileSync(this.smtCheckpointPath, "utf-8");
      return JSON.parse(raw) as SerializedSMT;
    } catch (error) {
      log.warn("Failed to load SMT checkpoint", {
        error: String(error),
      });
      return null;
    }
  }
}
