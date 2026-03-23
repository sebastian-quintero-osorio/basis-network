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
 * Security hardening:
 *   - Rate limiting: per-IP token bucket (ATK-API-01)
 *   - API key authentication: Bearer or X-API-Key header (ATK-API-02)
 *   - Transaction deduplication: reject duplicate txHash (ATK-BA4)
 *   - Input validation: hex format, field length limits
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
import { RateLimiter } from "./rate-limiter";
import { ApiKeyAuthenticator, type AuthConfig } from "./auth";
import { registry, apiRequestsTotal } from "../metrics";

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
// Transaction Deduplication (ATK-BA4)
// ---------------------------------------------------------------------------

/**
 * LRU-bounded set for tracking recently seen transaction hashes.
 * Prevents replay attacks and duplicate submissions.
 * Bounded to prevent unbounded memory growth.
 */
class TxDeduplicator {
  private readonly seen: Map<string, number> = new Map();
  private readonly maxSize: number;
  private readonly ttlMs: number;

  constructor(maxSize: number = 10000, ttlMs: number = 3600000) {
    this.maxSize = maxSize;
    this.ttlMs = ttlMs;
  }

  /**
   * Check if a txHash has been seen recently.
   * Returns true if the hash is a duplicate.
   */
  isDuplicate(txHash: string): boolean {
    const ts = this.seen.get(txHash);
    if (ts !== undefined) {
      if (Date.now() - ts < this.ttlMs) {
        return true;
      }
      // Expired entry, remove it
      this.seen.delete(txHash);
    }
    return false;
  }

  /**
   * Record a txHash as seen.
   */
  record(txHash: string): void {
    // Evict oldest entries if at capacity
    if (this.seen.size >= this.maxSize) {
      const firstKey = this.seen.keys().next().value as string;
      this.seen.delete(firstKey);
    }
    this.seen.set(txHash, Date.now());
  }
}

// ---------------------------------------------------------------------------
// Input Validation
// ---------------------------------------------------------------------------

/** Maximum length for hex-encoded field values. */
const MAX_HEX_LENGTH = 128;

/** BN128 scalar field prime (Poseidon hash domain). Values must be < this. */
const BN128_FIELD_PRIME =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** Validate that a string is a valid hex value (no 0x prefix). */
function isValidHex(value: string): boolean {
  return /^[0-9a-fA-F]+$/.test(value) && value.length <= MAX_HEX_LENGTH;
}

/** Validate that a hex value is within the BN128 scalar field. */
function isWithinBN128Field(hex: string): boolean {
  try {
    return BigInt("0x" + hex) < BN128_FIELD_PRIME;
  } catch {
    return false;
  }
}

/** Validate SHA-256 hash format. */
function isValidTxHash(hash: string): boolean {
  return /^[0-9a-fA-F]{64}$/.test(hash);
}

// ---------------------------------------------------------------------------
// Server Factory
// ---------------------------------------------------------------------------

/**
 * Create and configure the Fastify API server with security hardening.
 *
 * @param orchestrator - The Enterprise Node orchestrator instance
 * @param config - Node configuration
 * @param authConfig - Optional authentication configuration
 * @returns Configured Fastify instance (not yet listening)
 */
export function createServer(
  orchestrator: EnterpriseNodeOrchestrator,
  config: NodeConfig,
  authConfig?: AuthConfig
): FastifyInstance {
  // TLS configuration: if API_TLS_CERT and API_TLS_KEY are set, enable HTTPS.
  const tlsCert = process.env["API_TLS_CERT"];
  const tlsKey = process.env["API_TLS_KEY"];
  let httpsOptions: Record<string, unknown> = {};
  if (tlsCert && tlsKey) {
    try {
      const fs = require("fs") as typeof import("fs");
      httpsOptions = {
        https: {
          cert: fs.readFileSync(tlsCert),
          key: fs.readFileSync(tlsKey),
        },
      };
      log.info("TLS enabled", { cert: tlsCert, key: tlsKey });
    } catch (tlsError: unknown) {
      log.warn("TLS certificate loading failed, falling back to HTTP", {
        cert: tlsCert,
        key: tlsKey,
        error: String(tlsError),
      });
    }
  }

  const server = Fastify({
    logger: false, // We use our own structured logger
    bodyLimit: 1048576, // 1MB max request body
    ...httpsOptions,
  });

  // Security: Rate limiter
  const rateLimiter = new RateLimiter({
    maxTokens: 100,    // 100 requests burst
    refillRate: 10,    // 10 requests/second sustained
  });
  rateLimiter.start();

  // Security: API key authentication
  const auth = new ApiKeyAuthenticator(
    authConfig ?? { enabled: false, keys: [] }
  );

  // Security: Transaction deduplication (ATK-BA4)
  const dedup = new TxDeduplicator();

  // Graceful cleanup on server close
  server.addHook("onClose", async () => {
    rateLimiter.stop();
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
      const clientIp = request.ip;

      // Security: Rate limiting per IP (ATK-API-01)
      if (!rateLimiter.allow(clientIp)) {
        log.warn("Rate limited (IP)", { ip: clientIp });
        return reply.status(429).send({
          error: "Too many requests",
          retryAfterMs: 1000,
        });
      }

      // Security: Authentication (ATK-API-02)
      const authResult = auth.validate(
        request.headers.authorization,
        request.headers["x-api-key"] as string | undefined
      );
      if (!authResult.valid) {
        return reply.status(401).send({
          error: authResult.reason ?? "Unauthorized",
        });
      }

      const body = request.body;

      // Input validation: required fields
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

      // Input validation: format checks
      if (!isValidTxHash(body.txHash)) {
        return reply.status(400).send({
          error: "txHash must be a 64-character hex string (SHA-256)",
        });
      }

      if (!isValidHex(body.key) || !isValidHex(body.newValue)) {
        return reply.status(400).send({
          error: "key and newValue must be valid hex strings (max 128 chars)",
        });
      }

      // Input validation: BN128 field range (prevents SMT crash on out-of-field values)
      if (!isWithinBN128Field(body.key) || !isWithinBN128Field(body.newValue)) {
        return reply.status(400).send({
          error: "key and newValue must be within BN128 scalar field",
        });
      }
      if (body.oldValue !== "0" && !isWithinBN128Field(body.oldValue)) {
        return reply.status(400).send({
          error: "oldValue must be within BN128 scalar field",
        });
      }

      // Security: Rate limiting per enterprise (prevents one enterprise starving others)
      const enterpriseKey = `enterprise:${body.enterpriseId}`;
      if (!rateLimiter.allow(enterpriseKey)) {
        log.warn("Rate limited (enterprise)", { enterprise: body.enterpriseId });
        return reply.status(429).send({
          error: "Too many requests for this enterprise",
          retryAfterMs: 1000,
        });
      }

      // Security: Transaction deduplication (ATK-BA4)
      if (dedup.isDuplicate(body.txHash)) {
        log.warn("Duplicate transaction rejected", { txHash: body.txHash });
        return reply.status(409).send({
          error: "Duplicate transaction",
          txHash: body.txHash,
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
        dedup.record(tx.txHash);

        log.debug("Transaction submitted via API", {
          txHash: tx.txHash,
          seq,
        });

        const ipRemaining = rateLimiter.remaining(clientIp);
        const entRemaining = rateLimiter.remaining(`enterprise:${body.enterpriseId}`);
        reply.header("X-RateLimit-Remaining", String(Math.min(ipRemaining, entRemaining)));
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

  // -----------------------------------------------------------------------
  // GET /metrics  -- Prometheus metrics export
  // -----------------------------------------------------------------------
  server.get("/metrics", async (_request: FastifyRequest, reply: FastifyReply) => {
    const metricsOutput = await registry.metrics();
    return reply
      .header("Content-Type", registry.contentType)
      .status(200)
      .send(metricsOutput);
  });

  // -----------------------------------------------------------------------
  // API request counter hook (fires after every response)
  // -----------------------------------------------------------------------
  server.addHook("onResponse", (request, reply, done) => {
    // Exclude the /metrics endpoint itself to avoid self-referential noise
    if (request.url !== "/metrics") {
      apiRequestsTotal
        .labels(request.method, request.url, String(reply.statusCode))
        .inc();
    }
    done();
  });

  log.info("API server configured", {
    routes: [
      "POST /v1/transactions",
      "GET /v1/status",
      "GET /v1/batches/:id",
      "GET /v1/batches",
      "GET /health",
      "GET /metrics",
    ],
    security: {
      rateLimiting: true,
      authentication: authConfig?.enabled ?? false,
      deduplication: true,
      inputValidation: true,
    },
  });

  return server;
}
