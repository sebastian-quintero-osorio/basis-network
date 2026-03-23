/**
 * Enterprise Node -- Entry Point
 *
 * [Spec: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla]
 *
 * Bootstraps the complete enterprise validium node:
 *   1. Load configuration from environment
 *   2. Initialize all modules (SMT, Queue, Aggregator, Prover, Submitter, DAC)
 *   3. Create orchestrator (state machine)
 *   4. Recover from previous crash (WAL replay)
 *   5. Start API server
 *   6. Start batch processing loop
 *   7. Register graceful shutdown handlers
 *
 * @module index
 */

import * as dotenv from "dotenv";
import { SparseMerkleTree } from "./state";
import { TransactionQueue } from "./queue";
import { BatchAggregator } from "./batch";
import { ZKProver } from "./prover";
import { L1Submitter } from "./submitter";
import { DACProtocol } from "./da";
import { EnterpriseNodeOrchestrator } from "./orchestrator";
import { createServer } from "./api";
import { loadConfig } from "./config";
import { createLogger } from "./logger";

const log = createLogger("main");

async function main(): Promise<void> {
  // Load .env file
  dotenv.config();

  const config = loadConfig();

  log.info("Basis Network Enterprise Node starting", {
    enterpriseId: config.enterpriseId,
    version: "0.1.0",
  });

  // -----------------------------------------------------------------------
  // Initialize Sparse Merkle Tree
  // [Spec: smtState = {} (genesis: empty Merkle tree)]
  // -----------------------------------------------------------------------
  const smt = await SparseMerkleTree.create(config.smtDepth);
  log.info("Sparse Merkle Tree initialized", {
    depth: config.smtDepth,
    root: smt.root.toString(16).slice(0, 16) + "...",
  });

  // -----------------------------------------------------------------------
  // Initialize Transaction Queue with WAL
  // [Spec: txQueue = <<>>, wal = <<>>, walCheckpoint = 0]
  // -----------------------------------------------------------------------
  const queue = new TransactionQueue({
    walDir: config.walDir,
    fsyncOnWrite: config.walFsync,
    hmacKey: config.walHmacKey,
    encryptionKey: config.walEncryptionKey,
  });
  log.info("Transaction queue initialized", {
    walDir: config.walDir,
    fsync: config.walFsync,
    hmacEnabled: !!config.walHmacKey,
    encryptionEnabled: !!config.walEncryptionKey,
  });

  // -----------------------------------------------------------------------
  // Initialize Batch Aggregator
  // [Spec: BatchThreshold constant]
  // -----------------------------------------------------------------------
  const aggregator = new BatchAggregator(queue, {
    maxBatchSize: config.maxBatchSize,
    maxWaitTimeMs: config.maxWaitTimeMs,
  });
  log.info("Batch aggregator initialized", {
    maxBatchSize: config.maxBatchSize,
    maxWaitTimeMs: config.maxWaitTimeMs,
  });

  // -----------------------------------------------------------------------
  // Initialize ZK Prover
  // [Spec: GenerateProof action]
  // -----------------------------------------------------------------------
  const prover = new ZKProver({
    circuitWasmPath: config.circuitWasmPath,
    provingKeyPath: config.provingKeyPath,
    enterpriseId: config.enterpriseId,
    batchSize: config.maxBatchSize,
    smtDepth: config.smtDepth,
  });

  // -----------------------------------------------------------------------
  // Initialize L1 Submitter
  // [Spec: SubmitBatch + ConfirmBatch actions]
  // -----------------------------------------------------------------------
  const submitter = new L1Submitter({
    rpcUrl: config.l1RpcUrl,
    privateKey: config.l1PrivateKey,
    contractAddress: config.stateCommitmentAddress,
    maxRetries: config.maxRetries,
    retryBaseDelayMs: config.retryBaseDelayMs,
    txConfirmTimeoutMs: config.txConfirmTimeoutMs,
  });

  // -----------------------------------------------------------------------
  // Initialize DAC Protocol
  // [Spec: SubmitBatch -- dataExposed \cup {"dac_shares"}]
  // -----------------------------------------------------------------------
  const dac = new DACProtocol({
    committeeSize: config.dacCommitteeSize,
    threshold: config.dacThreshold,
    enableFallback: config.dacEnableFallback,
  });
  log.info("DAC protocol initialized", {
    committeeSize: config.dacCommitteeSize,
    threshold: config.dacThreshold,
  });

  // Initialize distributed DAC clients if DAC_ENDPOINTS is set.
  // Format: "host1:port1,host2:port2,host3:port3"
  const dacEndpoints = process.env["DAC_ENDPOINTS"];
  let dacClients: import("./da/dac-client").DACNodeClient[] | undefined;
  if (dacEndpoints) {
    const { DACNodeClient } = await import("./da/dac-client");
    dacClients = dacEndpoints.split(",").map(
      (endpoint) => new DACNodeClient({ endpoint: endpoint.trim(), timeoutMs: 10000 })
    );
    log.info("Distributed DAC clients initialized", {
      endpoints: dacEndpoints,
      count: dacClients.length,
    });
  }

  // -----------------------------------------------------------------------
  // Create Orchestrator
  // [Spec: Init -- all variables initialized]
  // -----------------------------------------------------------------------
  const orchestrator = new EnterpriseNodeOrchestrator({
    smt,
    queue,
    aggregator,
    prover,
    submitter,
    dac,
    config,
    dacClients,
  });

  // -----------------------------------------------------------------------
  // Recovery from previous crash
  // [Spec: Retry -- replay WAL, restore SMT from checkpoint]
  // -----------------------------------------------------------------------
  await orchestrator.recover();

  // -----------------------------------------------------------------------
  // Create and start API server
  // -----------------------------------------------------------------------
  const server = createServer(orchestrator, config);
  await server.listen({ host: config.apiHost, port: config.apiPort });
  log.info("API server listening", {
    host: config.apiHost,
    port: config.apiPort,
    endpoints: [
      "POST /v1/transactions",
      "GET /v1/status",
      "GET /v1/batches/:id",
      "GET /v1/batches",
      "GET /health",
    ],
  });

  // -----------------------------------------------------------------------
  // Start batch processing loop
  // -----------------------------------------------------------------------
  orchestrator.start();

  // -----------------------------------------------------------------------
  // Graceful shutdown
  // -----------------------------------------------------------------------
  let shuttingDown = false;

  const shutdown = async (signal: string): Promise<void> => {
    if (shuttingDown) return;
    shuttingDown = true;

    log.info("Shutdown signal received", { signal });

    // Safety timeout: if shutdown takes longer than 60s, force exit
    const safetyTimer = setTimeout(() => {
      log.error("Shutdown safety timeout exceeded (60s), forcing exit");
      process.exit(1);
    }, 60000);
    // Prevent the safety timer from keeping the process alive if
    // everything else completes first
    safetyTimer.unref();

    // Graceful shutdown: stop batch loop and wait for in-progress cycle
    try {
      const remaining = await orchestrator.shutdownGraceful(30000);
      if (remaining > 0) {
        log.warn("Unprocessed transactions remain in queue", {
          count: remaining,
        });
      } else {
        log.info("All transactions processed before shutdown");
      }
    } catch (error) {
      log.error("Error during orchestrator graceful shutdown", {
        error: String(error),
      });
    }

    // Close API server (stop accepting connections, finish in-flight)
    try {
      await server.close();
      log.info("API server closed");
    } catch (error) {
      log.error("Error closing API server", { error: String(error) });
    }

    log.info("Enterprise Node stopped");
    process.exit(0);
  };

  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));

  log.info("Enterprise Node ready", {
    enterpriseId: config.enterpriseId,
    state: orchestrator.getStatus().state,
    queueDepth: orchestrator.getStatus().queueDepth,
  });
}

main().catch((error) => {
  log.error("Fatal error during startup", {
    error: error instanceof Error ? error.message : String(error),
    stack: error instanceof Error ? error.stack : undefined,
  });
  process.exit(1);
});
