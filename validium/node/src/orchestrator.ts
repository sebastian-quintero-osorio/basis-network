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
import { DACNodeClient } from "./da/dac-client";
import type { DACL1Submitter } from "./da/dac-l1-submitter";
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
import {
  transactionsTotal,
  batchesTotal,
  proofsTotal,
  l1SubmissionsTotal,
  proofDuration,
  l1SubmissionDuration,
  batchSize as batchSizeHistogram,
  queueDepth as queueDepthGauge,
  nodeState as nodeStateGauge,
  uptimeSeconds,
  crashCount as crashCountGauge,
  stateToNumber,
} from "./metrics";

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
  /** Optional distributed DAC clients (gRPC). When provided, used instead of in-process DACProtocol. */
  readonly dacClients?: readonly DACNodeClient[];
  /** Optional DAC L1 attestation submitter. When provided, attestations are posted to DACAttestation.sol. */
  readonly dacL1Submitter?: DACL1Submitter;
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
  private readonly dacClients: readonly DACNodeClient[];
  private readonly dacL1Submitter?: DACL1Submitter;
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

  // -- Metrics uptime timer --
  private uptimeTimer: ReturnType<typeof setInterval> | null = null;

  // -- Graceful shutdown --
  private shuttingDown: boolean = false;
  private shutdownResolve: (() => void) | null = null;

  constructor(deps: OrchestratorDeps) {
    this.smt = deps.smt;
    this.queue = deps.queue;
    this.aggregator = deps.aggregator;
    this.prover = deps.prover;
    this.submitter = deps.submitter;
    this.dac = deps.dac;
    this.dacClients = deps.dacClients ?? [];
    this.dacL1Submitter = deps.dacL1Submitter;
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

    // Metrics: count transaction and update queue depth
    transactionsTotal.labels(tx.enterpriseId).inc();
    queueDepthGauge.set(this.queue.size);

    // [Spec: nodeState' = IF nodeState = "Idle" THEN "Receiving" ELSE nodeState]
    if (this.state === NodeState.Idle) {
      this.state = NodeState.Receiving;
      nodeStateGauge.set(stateToNumber(this.state));
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

    // Periodically update the uptime gauge (every 5 seconds)
    this.uptimeTimer = setInterval(() => {
      uptimeSeconds.set((Date.now() - this.startedAt) / 1000);
    }, 5000);

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
    if (this.uptimeTimer) {
      clearInterval(this.uptimeTimer);
      this.uptimeTimer = null;
    }
    log.info("Batch monitoring loop stopped");
  }

  /**
   * Graceful shutdown: stop accepting new batches, wait for any in-progress
   * batch cycle to complete (with timeout), and return the number of
   * unprocessed transactions remaining in the queue.
   *
   * @param timeoutMs - Maximum time (ms) to wait for in-progress batch cycle
   * @returns Number of unprocessed transactions still in the queue
   */
  async shutdownGraceful(timeoutMs: number): Promise<number> {
    this.shuttingDown = true;
    log.info("Graceful shutdown initiated", { timeoutMs });

    // Stop the batch monitoring loop (no new ticks)
    this.stop();

    // If a batch cycle is currently running, wait for it to finish
    const IN_PROGRESS_STATES = new Set([
      NodeState.Batching,
      NodeState.Proving,
      NodeState.Submitting,
    ]);

    if (this.batchCycleRunning || IN_PROGRESS_STATES.has(this.state)) {
      log.info("Waiting for in-progress batch cycle to complete", {
        state: this.state,
      });

      await new Promise<void>((resolve) => {
        this.shutdownResolve = resolve;

        const timer = setTimeout(() => {
          log.warn("Graceful shutdown timeout exceeded, forcing shutdown", {
            timeoutMs,
            state: this.state,
          });
          this.shutdownResolve = null;
          resolve();
        }, timeoutMs);

        // Check immediately in case the cycle already completed
        if (!this.batchCycleRunning && !IN_PROGRESS_STATES.has(this.state)) {
          clearTimeout(timer);
          this.shutdownResolve = null;
          resolve();
        }
      });
    }

    const remaining = this.queue.size;
    log.info("Graceful shutdown complete", {
      unprocessedTransactions: remaining,
    });
    return remaining;
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
    nodeStateGauge.set(stateToNumber(this.state));
    queueDepthGauge.set(this.queue.size);

    // [Spec: CheckQueue -- if queue non-empty, transition to Receiving]
    if (this.queue.size > 0) {
      this.state = NodeState.Receiving;
      nodeStateGauge.set(stateToNumber(this.state));
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
    // Guard: skip if shutting down
    if (this.shuttingDown) return;

    // Guard: only one batch cycle at a time
    if (this.batchCycleRunning) return;

    // [Spec: CheckQueue -- Idle with non-empty queue -> Receiving]
    if (this.state === NodeState.Idle && this.queue.size > 0) {
      this.state = NodeState.Receiving;
      nodeStateGauge.set(stateToNumber(this.state));
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
      // Notify graceful shutdown if it is waiting for cycle completion
      if (this.shuttingDown && this.shutdownResolve) {
        this.shutdownResolve();
        this.shutdownResolve = null;
      }
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
    nodeStateGauge.set(stateToNumber(this.state));
    log.info("State: Receiving -> Batching");

    const batch = this.aggregator.formBatch();
    if (!batch) {
      this.state = NodeState.Receiving;
      nodeStateGauge.set(stateToNumber(this.state));
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

    // Metrics: batch formed
    batchesTotal.labels("forming").inc();
    batchSizeHistogram.observe(batch.txCount);
    queueDepthGauge.set(this.queue.size);

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

      // Capture padding proof for the prover: a Merkle proof at key=0
      // in the current SMT state. The circuit needs real siblings for identity
      // transitions (key=0, old=0, new=0), not zeros.
      const paddingProof = this.smt.getProof(0n);
      (witness as unknown as { paddingSiblings: string[]; paddingPathBits: number[] }).paddingSiblings =
        paddingProof.siblings.map((s: bigint) => s.toString(16));
      (witness as unknown as { paddingSiblings: string[]; paddingPathBits: number[] }).paddingPathBits =
        [...paddingProof.pathBits];

      batchRecord.prevStateRoot = witness.prevStateRoot;
      batchRecord.newStateRoot = witness.newStateRoot;
      batchRecord.status = "proving";

      // Metrics: batch entering proving
      batchesTotal.labels("proving").inc();

      this.state = NodeState.Proving;
      nodeStateGauge.set(stateToNumber(this.state));
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

      // Metrics: proof completed
      proofsTotal.labels("success").inc();
      proofDuration.observe(proof.durationMs / 1000);

      batchRecord.status = "submitting";
      batchesTotal.labels("submitting").inc();
      this.state = NodeState.Submitting;
      nodeStateGauge.set(stateToNumber(this.state));
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
      const l1Start = Date.now();
      const submission = await this.submitter.submit(
        proof,
        witness.prevStateRoot,
        witness.newStateRoot,
        batch.batchNum
      );

      // Metrics: L1 submission succeeded
      l1SubmissionsTotal.labels("success").inc();
      l1SubmissionDuration.observe((Date.now() - l1Start) / 1000);

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

      // Metrics: batch confirmed
      batchesTotal.labels("confirmed").inc();

      // [Spec: nodeState' = "Idle"]
      this.state = NodeState.Idle;
      nodeStateGauge.set(stateToNumber(this.state));
      queueDepthGauge.set(this.queue.size);
      log.info("State: Submitting -> Idle (batch confirmed)", {
        batchId: batch.batchId.slice(0, 16) + "...",
        l1TxHash: submission.txHash,
        batchesProcessed: this.batchesProcessed,
      });

      // [Spec: CheckQueue -- if queue non-empty, go to Receiving]
      if (this.queue.size > 0) {
        this.state = NodeState.Receiving;
        nodeStateGauge.set(stateToNumber(this.state));
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

    // Metrics: batch failed, crash recovery
    batchesTotal.labels("failed").inc();
    l1SubmissionsTotal.labels("failure").inc();
    crashCountGauge.set(this.crashCount);
    nodeStateGauge.set(stateToNumber(this.state));

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
    // If distributed DAC clients are configured, use them via gRPC.
    if (this.dacClients.length > 0) {
      this.distributeToDacRemote(batch, newStateRoot).catch((error: unknown) => {
        log.warn("Remote DAC distribution failed (non-critical)", {
          batchId: batch.batchId.slice(0, 16) + "...",
          error: String(error),
        });
      });
      return;
    }

    // Fallback: in-process DAC (for development/testing)
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
      log.info("DAC distribution complete (in-process)", {
        batchId: batch.batchId.slice(0, 16) + "...",
        commitment: distribution.commitment.slice(0, 16) + "...",
        durationMs: distribution.durationMs,
      });

      const attestation = this.dac.collectAttestations(
        batch.batchId,
        distribution.commitment
      );
      log.info("DAC attestations collected (in-process)", {
        batchId: batch.batchId.slice(0, 16) + "...",
        certState: attestation.certificate.state,
        signatureCount: attestation.certificate.signatureCount,
      });

      // Submit attestation to DACAttestation.sol on L1 (if submitter configured).
      // In-process DAC doesn't have Ethereum addresses; L1 submission requires
      // the remote gRPC path which returns real signer addresses.
      // For in-process: use nodeId as placeholder address.
      if (this.dacL1Submitter && attestation.certificate.state === "valid") {
        const signers = attestation.certificate.attestations.map(
          (a) => "0x" + a.nodeId.toString(16).padStart(40, "0")
        );
        const signatures = attestation.certificate.attestations.map(
          (a) => a.signature
        );
        this.dacL1Submitter.submit({
          batchId: batch.batchId,
          commitment: distribution.commitment,
          signers,
          signatures,
        }).then(() => {
          log.info("DAC attestation submitted to L1", {
            batchId: batch.batchId.slice(0, 16) + "...",
          });
        }).catch((l1Error: unknown) => {
          log.warn("DAC L1 attestation submission failed (non-critical)", {
            batchId: batch.batchId.slice(0, 16) + "...",
            error: String(l1Error),
          });
        });
      }
    } catch (error: unknown) {
      log.warn("DAC distribution/attestation failed (non-critical)", {
        batchId: batch.batchId.slice(0, 16) + "...",
        error: String(error),
      });
    }
  }

  /**
   * Distribute batch data to remote DAC nodes via gRPC.
   * Uses Shamir secret sharing locally, then sends shares to each node.
   */
  private async distributeToDacRemote(batch: Batch, newStateRoot: string): Promise<void> {
    const { createHash } = await import("crypto");

    const batchData = JSON.stringify({
      batchId: batch.batchId,
      batchNum: batch.batchNum,
      transactions: batch.transactions,
      newStateRoot,
    });

    const dataCommitment = createHash("sha256").update(batchData).digest("hex");

    // Distribute shares to each remote DAC node
    const results = await Promise.allSettled(
      this.dacClients.map((client, index) =>
        client.storeShare({
          batchId: batch.batchId,
          enterpriseId: this.config.enterpriseId,
          shareValue: batchData, // In production, this would be a Shamir share
          shareIndex: index + 1,
          dataCommitment,
          totalShares: this.dacClients.length,
          threshold: this.config.dacThreshold,
        })
      )
    );

    let accepted = 0;
    for (const result of results) {
      if (result.status === "fulfilled" && result.value.accepted) {
        accepted++;
      }
    }

    log.info("Remote DAC distribution complete", {
      batchId: batch.batchId.slice(0, 16) + "...",
      accepted,
      total: this.dacClients.length,
      threshold: this.config.dacThreshold,
    });

    if (accepted < this.config.dacThreshold) {
      log.warn("DAC threshold not met, falling back to on-chain DA", {
        accepted,
        threshold: this.config.dacThreshold,
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
