# Validium Node -- Production Operations Guide

This document covers day-to-day operations for the Basis Network Enterprise ZK Validium Node.

---

## 1. Startup Procedure

### Prerequisites

- Node.js >= 18.0.0
- Circuit artifacts compiled and in place (WASM + zkey)
- `.env` file configured with real values
- L1 contracts deployed (StateCommitment, Groth16Verifier)
- Network access to the L1 RPC endpoint

### Steps

1. Copy the example environment file and fill in real values:

   ```bash
   cp .env.example .env
   ```

   At minimum, set `ENTERPRISE_ID`, `L1_RPC_URL`, `L1_PRIVATE_KEY`, and `STATE_COMMITMENT_ADDRESS`.

2. Ensure circuit artifacts are present. The production zkey (127 MB) must be copied from the research experiments output:

   ```bash
   mkdir -p ../circuits/build/production/state_transition_js/
   cp <source>/state_transition.wasm ../circuits/build/production/state_transition_js/
   cp <source>/state_transition_final.zkey ../circuits/build/production/
   ```

   Verify the paths match `CIRCUIT_WASM_PATH` and `PROVING_KEY_PATH` in `.env`.

3. Install dependencies (first time only):

   ```bash
   npm ci
   ```

4. Build and start the node:

   ```bash
   npm run build && npm start
   ```

   For development with hot reload:

   ```bash
   npm run dev
   ```

5. Verify the node is running:

   ```bash
   curl http://localhost:3000/health
   ```

   Expected response: `{"healthy":true,"state":"Idle","uptime":<ms>}`

---

## 2. Health Monitoring

### Endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| `/health` | GET | Lightweight health probe. Returns 200 when healthy, 503 when in Error state. |
| `/v1/status` | GET | Full node status: state, queue depth, batches processed, uptime, crash count, version. |
| `/metrics` | GET | Prometheus metrics endpoint (OpenMetrics format). |

### Prometheus Metrics

The node exports metrics under the `validium_` namespace. Connect your Prometheus instance to `http://<host>:<port>/metrics`.

### Alert Rules

Configure the following alerts in your monitoring system:

| Metric | Condition | Severity | Meaning |
|---|---|---|---|
| `validium_queue_depth` | > 100 | WARNING | Transaction queue is backing up. Batching or proving may be slow. |
| `validium_node_state` | == 5 | CRITICAL | Node is in Error state (5). Check logs for root cause. |
| `validium_proof_duration_seconds` (P99) | > 20s | WARNING | ZK proof generation is slower than expected. Check CPU load. |
| `validium_l1_submissions_total{status="failure"}` | increasing | CRITICAL | L1 submissions are failing. Check RPC connectivity and gas/nonce issues. |
| `validium_crash_count` | increasing | WARNING | Node is entering crash/recovery cycles. Review error logs. |
| `validium_uptime_seconds` | sudden drop to 0 | CRITICAL | Node restarted unexpectedly. |

### Key Gauges

- `validium_node_state` -- numeric state (0=Idle, 1=Receiving, 2=Batching, 3=Proving, 4=Submitting, 5=Error)
- `validium_queue_depth` -- current transaction queue depth
- `validium_uptime_seconds` -- node uptime in seconds

### Key Counters

- `validium_transactions_total` -- total transactions submitted (labeled by `enterprise_id`)
- `validium_batches_total` -- total batches by status (`forming`, `proving`, `submitting`, `confirmed`, `failed`)
- `validium_proofs_total` -- proof generation attempts by status (`success`, `failure`)
- `validium_l1_submissions_total` -- L1 submissions by status (`success`, `failure`)
- `validium_api_requests_total` -- API requests by `method`, `path`, `status_code`

### Key Histograms

- `validium_proof_duration_seconds` -- proof generation time (buckets: 1, 5, 10, 15, 20, 30, 60s)
- `validium_l1_submission_duration_seconds` -- L1 submission time (buckets: 1, 5, 10, 30, 60, 120s)
- `validium_batch_size` -- transactions per batch (buckets: 1, 2, 4, 8, 16, 32, 64)

---

## 3. Configuration Reference

All configuration is loaded from environment variables. Copy `.env.example` to `.env` and set values.

| Variable | Required | Default | Description |
|---|---|---|---|
| `ENTERPRISE_ID` | Yes | -- | Unique identifier for this enterprise node. |
| `L1_RPC_URL` | Yes | -- | Avalanche Subnet-EVM RPC endpoint (e.g., `https://rpc.basisnetwork.com.co`). |
| `L1_PRIVATE_KEY` | Yes | -- | Hex-encoded private key with `0x` prefix for L1 transactions. |
| `STATE_COMMITMENT_ADDRESS` | Yes | -- | Deployed StateCommitment contract address on L1. |
| `CIRCUIT_WASM_PATH` | Yes | -- | Path to compiled circuit WASM file. |
| `PROVING_KEY_PATH` | Yes | -- | Path to Groth16 proving key (`.zkey` file, ~127 MB for production). |
| `MAX_BATCH_SIZE` | No | `4` | Maximum transactions per batch. Must match circuit capacity (production: 8). |
| `MAX_WAIT_TIME_MS` | No | `30000` | Maximum wait time (ms) before forming a partial batch. |
| `WAL_DIR` | No | `./data/wal` | Directory for WAL file and SMT checkpoint storage. |
| `WAL_FSYNC` | No | `true` | Fsync every WAL write for crash safety. Set `false` only for testing. |
| `WAL_HMAC_KEY` | No | -- | HMAC key for WAL checkpoint authentication (hex, 64 chars). See Security section. |
| `SMT_DEPTH` | No | `32` | Sparse Merkle Tree depth. `32` supports 2^32 leaf positions. |
| `DAC_COMMITTEE_SIZE` | No | `3` | Number of DAC committee members. |
| `DAC_THRESHOLD` | No | `2` | Minimum attestations required. Must be in `[2, DAC_COMMITTEE_SIZE]`. |
| `DAC_ENABLE_FALLBACK` | No | `true` | Fall back to on-chain DA if DAC quorum fails. |
| `API_HOST` | No | `0.0.0.0` | API server bind address. |
| `API_PORT` | No | `3000` | API server port. |
| `MAX_RETRIES` | No | `3` | Maximum retry attempts for L1 submission. |
| `RETRY_BASE_DELAY_MS` | No | `1000` | Base delay (ms) for exponential backoff on retries. |
| `L1_TX_CONFIRM_TIMEOUT_MS` | No | `120000` | Timeout (ms) for L1 transaction confirmation. Prevents indefinite hang on RPC failures. |
| `BATCH_LOOP_INTERVAL_MS` | No | `1000` | Interval (ms) for the batch monitoring loop tick. |
| `LOG_LEVEL` | No | `info` | Logging level (`debug`, `info`, `warn`, `error`). |

---

## 4. Backup and Recovery

### WAL (Write-Ahead Log)

The WAL directory (`WAL_DIR`, default `./data/wal/`) contains two critical files:

- `wal.jsonl` -- Append-only transaction log. Each line is a JSON entry or checkpoint marker.
- `smt-checkpoint.json` -- Serialized Sparse Merkle Tree state at the last confirmed batch.

**Back up this directory regularly.** The WAL is the primary recovery mechanism.

### Automatic Recovery on Startup

When the node starts, it calls `orchestrator.recover()` which:

1. Loads `smt-checkpoint.json` to restore the SMT to the last confirmed L1 state.
2. Replays `wal.jsonl` from the last checkpoint marker, re-enqueuing uncommitted transactions.
3. Transitions to `Receiving` state if recovered transactions exist, or `Idle` otherwise.

No manual intervention is needed for normal restarts. The WAL ensures no committed data is lost.

### WAL Compaction

Compaction removes committed entries (those before the last checkpoint) from the WAL file. This happens automatically after each batch is confirmed on L1. The WAL file grows only with uncommitted transactions.

### SMT Checkpoint

The SMT checkpoint is written atomically (write to temp file, then rename) after each batch is confirmed on L1. This ensures a consistent snapshot even if the node crashes during the write.

---

## 5. Security

### WAL HMAC Key

The `WAL_HMAC_KEY` protects checkpoint markers in the WAL from injection attacks (ADV-WAL-04). An attacker with write access to the WAL file cannot forge checkpoint markers without the key.

Generate a key:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Set it in `.env`:

```
WAL_HMAC_KEY=<64-character hex string>
```

When the HMAC key is configured, checkpoint markers without a valid HMAC are rejected during recovery. Without the key, checkpoint authentication is disabled (acceptable for development).

### API Key Authentication

The API server supports API key authentication for `POST /v1/transactions`. Keys are passed via:

- `Authorization: Bearer <key>` header, or
- `X-API-Key: <key>` header

Keys are stored as SHA-256 hashes (never plaintext). Authentication is configured programmatically via `AuthConfig` when creating the server. When authentication is disabled (default), all requests are allowed.

Generate an API key hash for registration:

```bash
node -e "console.log(require('crypto').createHash('sha256').update('<your-key>').digest('hex'))"
```

### Rate Limiting

The API server includes per-IP rate limiting:

- Burst capacity: 100 requests
- Sustained rate: 10 requests/second
- Returns HTTP 429 with `retryAfterMs` when exceeded

### Private Key

The `L1_PRIVATE_KEY` controls the L1 submitter wallet. Treat it as a critical secret:

- Never commit it to version control.
- Use environment variables or a secrets manager.
- The `.env` file is gitignored.
- In production, consider using a hardware security module (HSM) or cloud KMS.

### Transaction Deduplication

The API server rejects duplicate transactions (same `txHash`) within a 1-hour TTL window (bounded to 10,000 entries). This mitigates replay attacks.

### Input Validation

All API inputs are validated:

- `txHash` must be a 64-character hex string (SHA-256).
- `key` and `newValue` must be valid hex strings (max 128 characters).
- Request body size is limited to 1 MB.

---

## 6. Emergency Procedures

### Stuck Batch

**Symptom:** `validium_node_state` remains at 3 (Proving) or 4 (Submitting) for an extended period.

**Resolution:**

1. Check logs for error details.
2. Restart the node. The WAL recovery mechanism will replay uncommitted transactions.
3. The batch will be re-formed and re-processed from scratch.

### L1 RPC Failure

**Symptom:** `validium_l1_submissions_total{status="failure"}` increasing; logs show RPC connection errors.

**Resolution:**

1. The node retries L1 submissions with exponential backoff (`RETRY_BASE_DELAY_MS` * 2^attempt, up to `MAX_RETRIES` attempts).
2. After all retries fail, the node enters Error state and automatically recovers (restores SMT from checkpoint, replays WAL).
3. If the RPC endpoint is permanently down, update `L1_RPC_URL` in `.env` and restart.
4. The `L1_TX_CONFIRM_TIMEOUT_MS` setting (default 120s) prevents indefinite hang waiting for transaction confirmation.

### WAL Corruption

**Symptom:** Errors during startup recovery mentioning corrupted entries.

**Resolution:**

1. Corrupted entries (bad checksum or malformed JSON from partial writes during a crash) are automatically skipped during recovery.
2. The node logs the number of corrupted entries found.
3. No manual intervention is needed. Valid entries after the last checkpoint are replayed normally.
4. If the entire WAL is unreadable, delete `wal.jsonl` and the node will start fresh from the SMT checkpoint. Transactions between the last checkpoint and the crash are lost.

### Graceful Shutdown

**Signal:** Send `SIGTERM` (or `SIGINT`) to the node process.

**Behavior:**

1. The batch monitoring loop stops (no new batch cycles begin).
2. If a batch cycle is in progress, the node waits up to **30 seconds** for it to complete.
3. After the batch cycle completes (or the 30s timeout), the API server closes (finishes in-flight requests).
4. If the entire shutdown takes longer than **60 seconds**, the process force-exits with code 1.
5. Unprocessed transactions remain in the WAL and will be recovered on next startup.
6. The shutdown log reports the number of unprocessed transactions remaining.

```bash
# Graceful shutdown
kill -TERM <pid>

# Or if running in foreground
Ctrl+C
```

### Full State Reset

If you need to completely reset the node state (e.g., after a testnet reset):

1. Stop the node.
2. Delete the WAL directory: `rm -rf ./data/wal/`
3. Restart the node. It will initialize with an empty SMT and empty queue.

---

## 7. API Quick Reference

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/health` | GET | No | Health probe. Returns `{"healthy": true/false, "state": "...", "uptime": <ms>}`. |
| `/v1/status` | GET | No | Full node status (state, queue depth, batches, uptime, version). |
| `/v1/transactions` | POST | Yes | Submit an enterprise transaction. Returns `{"status":"accepted","walSeq":<n>,"txHash":"..."}`. |
| `/v1/batches` | GET | No | List all batch records (most recent first). |
| `/v1/batches/:id` | GET | No | Get a specific batch record by ID. |
| `/metrics` | GET | No | Prometheus metrics (OpenMetrics format). |

### Submit Transaction Example

```bash
curl -X POST http://localhost:3000/v1/transactions \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <your-key>" \
  -d '{
    "txHash": "a1b2c3d4e5f6...64 hex chars...",
    "key": "0a1b2c",
    "oldValue": "00",
    "newValue": "ff",
    "enterpriseId": "enterprise-001"
  }'
```

### HTTP Status Codes

| Code | Meaning |
|---|---|
| 200 | Success (GET requests). |
| 202 | Accepted (transaction queued for processing). |
| 400 | Bad request (invalid input format). |
| 401 | Unauthorized (missing or invalid API key). |
| 404 | Not found (batch ID does not exist). |
| 409 | Conflict (duplicate transaction hash). |
| 429 | Too many requests (rate limit exceeded). |
| 503 | Service unavailable (node in Error state or cannot accept transactions). |
