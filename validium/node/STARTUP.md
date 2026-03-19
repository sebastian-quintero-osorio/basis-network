# Enterprise Validium Node -- Startup Guide

## Prerequisites

| Requirement | Version | Purpose |
|---|---|---|
| Node.js | >= 18.0 | Runtime |
| npm | >= 9.0 | Package manager |
| Circom | 2.2.3 | Circuit compilation (setup only) |
| SnarkJS | 0.7.6 | Proof generation |

## Quick Start

```bash
# 1. Install dependencies
cd validium/node
npm install

# 2. Copy and configure environment
cp .env.example .env
# Edit .env with your enterprise credentials and contract addresses

# 3. Build
npm run build

# 4. Start the node
npm start

# The node will:
#   - Load configuration from .env
#   - Initialize Sparse Merkle Tree (depth=32)
#   - Initialize Transaction Queue with WAL
#   - Recover from any previous crash (WAL replay)
#   - Start API server on configured port
#   - Start batch processing loop
```

## Configuration

All configuration is via environment variables. See `.env.example` for the complete list.

### Required Variables

| Variable | Description |
|---|---|
| `ENTERPRISE_ID` | Enterprise identifier (assigned by admin) |
| `L1_RPC_URL` | Basis Network L1 RPC endpoint |
| `L1_PRIVATE_KEY` | Private key for L1 transactions (hex, 0x prefix) |
| `STATE_COMMITMENT_ADDRESS` | StateCommitment contract on L1 |
| `CIRCUIT_WASM_PATH` | Path to compiled circuit WASM |
| `PROVING_KEY_PATH` | Path to Groth16 proving key (zkey) |

### Key Defaults

| Variable | Default | Notes |
|---|---|---|
| `MAX_BATCH_SIZE` | 8 | Must match circuit batchSize |
| `SMT_DEPTH` | 32 | Must match circuit depth |
| `MAX_WAIT_TIME_MS` | 30000 | 30s timeout for partial batches |
| `API_PORT` | 3000 | REST API port |
| `DAC_THRESHOLD` | 2 | 2-of-3 Shamir threshold |

## Docker

```bash
# Build image
docker build -t basis-validium-node .

# Run with environment file
docker run --env-file .env -p 3000:3000 \
  -v $(pwd)/data:/app/data \
  -v $(pwd)/../circuits/build/production/state_transition_js/state_transition.wasm:/app/circuits/state_transition.wasm:ro \
  -v $(pwd)/../circuits/build/production/state_transition_final.zkey:/app/circuits/state_transition_final.zkey:ro \
  basis-validium-node

# Or use docker-compose
docker-compose up -d
```

## API Endpoints

| Method | Path | Description |
|---|---|---|
| POST | `/v1/transactions` | Submit enterprise transaction |
| GET | `/v1/status` | Node health and metrics |
| GET | `/v1/batches` | List all batches |
| GET | `/v1/batches/:id` | Get batch by ID |
| GET | `/health` | Lightweight health probe |

### Submit Transaction

```bash
curl -X POST http://localhost:3000/v1/transactions \
  -H "Content-Type: application/json" \
  -d '{
    "txHash": "abc123...64hexchars",
    "key": "0001",
    "oldValue": "0",
    "newValue": "002a",
    "enterpriseId": "enterprise-001"
  }'
```

### Check Status

```bash
curl http://localhost:3000/v1/status
```

## State Machine

The node operates a pipelined finite state machine:

```
Idle -> Receiving -> Batching -> Proving -> Submitting -> Idle
                                                    \-> Error -> Idle (via Retry)
```

- **Idle**: No transactions, waiting for input
- **Receiving**: Accepting transactions (pipelined during Proving/Submitting)
- **Batching**: Forming batch + building ZK witness
- **Proving**: Generating Groth16 proof via snarkjs
- **Submitting**: Sending proof to L1 StateCommitment contract
- **Error**: Automatic recovery via WAL replay

## Crash Recovery

On startup (or after error), the node:
1. Loads SMT from last checkpoint (if exists)
2. Replays WAL from last checkpoint sequence
3. Rebuilds in-memory queue with uncommitted transactions
4. Resumes normal operation

No transactions are lost due to the deferred checkpoint design (v1-fix).

## Circuit Setup

The ZK circuit must be compiled and set up before the node can generate proofs.
See `validium/circuits/` for the full build pipeline.

Production parameters: depth=32, batch=8 (274,291 constraints, Groth16/BN254).

## Security

- **Rate limiting**: Per-IP token bucket (100 burst, 10/sec sustained)
- **API authentication**: Bearer or X-API-Key header (configurable)
- **Transaction deduplication**: LRU set rejects duplicate txHash
- **Input validation**: Hex format, SHA-256 hash format, length limits
- **WAL integrity**: SHA-256 checksums on every entry
