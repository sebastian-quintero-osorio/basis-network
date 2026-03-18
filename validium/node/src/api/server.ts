/**
 * REST API server for the Enterprise Node.
 *
 * [Spec: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla]
 *
 * Endpoints:
 *   POST /v1/transactions  -- Submit enterprise transaction (ReceiveTx action)
 *   GET  /v1/status         -- Node health check and status
 *   GET  /v1/batches/:id    -- Query batch by ID
 *   GET  /v1/batches        -- List all batches
 *   GET  /health            -- Lightweight health probe
 *
 * @module api/server
 */

import Fastify from "fastify";
import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import type { EnterpriseNodeOrchestrator } from "../orchestrator";
import type { NodeConfig } from "../types";
import { NodeError } from "../types";
import type { Transaction } from "../queue/types";
import { createLogger } from "../logger";

const log = createLogger("api");

// ---------------------------------------------------------------------------
// Request/Response Types
// ---------------------------------------------------------------------------

interface SubmitTxBody {
  txHash: string;
  key: string;
  oldValue: string;
  newValue: string;
  enterpriseId: string;
  timestamp?: number;
}

interface BatchParams {
  id: string;
}

// ---------------------------------------------------------------------------
// Server Factory
// ---------------------------------------------------------------------------

/**
 * Create and configure the Fastify API server.
 *
 * @param orchestrator - The Enterprise Node orchestrator instance
 * @param config - Node configuration
 * @returns Configured Fastify instance (not yet listening)
 */
export function createServer(
  orchestrator: EnterpriseNodeOrchestrator,
  config: NodeConfig
): FastifyInstance {
  const server = Fastify({
    logger: false, // We use our own structured logger
    bodyLimit: 1048576, // 1MB max request body
  });

  // -----------------------------------------------------------------------
  // POST /v1/transactions
  // -----------------------------------------------------------------------
  // [Spec: ReceiveTx(tx)]
  //   Precondition: nodeState \in {"Idle", "Receiving", "Proving", "Submitting"}
  //   Effect: WAL append + queue push
  // -----------------------------------------------------------------------
  server.post(
    "/v1/transactions",
    async (
      request: FastifyRequest<{ Body: SubmitTxBody }>,
      reply: FastifyReply
    ) => {
      const body = request.body;

      // Validate required fields
      if (
        !body ||
        typeof body !== "object" ||
        !body.txHash ||
        !body.key ||
        !body.oldValue ||
        !body.newValue ||
        !body.enterpriseId
      ) {
        return reply.status(400).send({
          error: "Invalid request body",
          required: ["txHash", "key", "oldValue", "newValue", "enterpriseId"],
        });
      }

      const tx: Transaction = {
        txHash: body.txHash,
        key: body.key,
        oldValue: body.oldValue,
        newValue: body.newValue,
        enterpriseId: body.enterpriseId,
        timestamp: body.timestamp ?? Date.now(),
      };

      try {
        const seq = orchestrator.submitTransaction(tx);
        log.debug("Transaction submitted via API", {
          txHash: tx.txHash,
          seq,
        });
        return reply.status(202).send({
          status: "accepted",
          walSeq: seq,
          txHash: tx.txHash,
        });
      } catch (error) {
        if (error instanceof NodeError) {
          return reply.status(503).send({
            error: error.message,
            code: error.code,
            state: orchestrator.getStatus().state,
          });
        }
        return reply.status(500).send({
          error: "Internal server error",
        });
      }
    }
  );

  // -----------------------------------------------------------------------
  // GET /v1/status
  // -----------------------------------------------------------------------
  server.get("/v1/status", async (_request: FastifyRequest, reply: FastifyReply) => {
    const status = orchestrator.getStatus();
    return reply.status(200).send(status);
  });

  // -----------------------------------------------------------------------
  // GET /v1/batches/:id
  // -----------------------------------------------------------------------
  server.get(
    "/v1/batches/:id",
    async (
      request: FastifyRequest<{ Params: BatchParams }>,
      reply: FastifyReply
    ) => {
      const { id } = request.params;
      const batch = orchestrator.getBatch(id);

      if (!batch) {
        return reply.status(404).send({
          error: "Batch not found",
          batchId: id,
        });
      }

      return reply.status(200).send(batch);
    }
  );

  // -----------------------------------------------------------------------
  // GET /v1/batches
  // -----------------------------------------------------------------------
  server.get("/v1/batches", async (_request: FastifyRequest, reply: FastifyReply) => {
    const batches = orchestrator.getAllBatches();
    return reply.status(200).send({
      count: batches.length,
      batches,
    });
  });

  // -----------------------------------------------------------------------
  // GET /health
  // -----------------------------------------------------------------------
  server.get("/health", async (_request: FastifyRequest, reply: FastifyReply) => {
    const status = orchestrator.getStatus();
    const healthy = status.state !== "Error";
    return reply.status(healthy ? 200 : 503).send({
      healthy,
      state: status.state,
      uptime: status.uptimeMs,
    });
  });

  log.info("API server configured", {
    routes: [
      "POST /v1/transactions",
      "GET /v1/status",
      "GET /v1/batches/:id",
      "GET /v1/batches",
      "GET /health",
    ],
  });

  return server;
}
