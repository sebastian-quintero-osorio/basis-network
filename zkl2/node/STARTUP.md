# Basis L2 Node -- Startup Guide

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Go | 1.24+ | Node binary compilation |
| Rust | 1.83+ | ZK prover compilation |
| Node.js | 22+ | L1 contract deployment and testing |
| Docker | 24+ | Containerized deployment (optional) |

## Quick Start (Development)

### 1. Build the Node Binary

```bash
cd zkl2/node
go build -o basis-l2 ./cmd/basis-l2/
```

### 2. Configure Environment

```bash
cp .env.example .env
# Edit .env with your configuration:
# - L1_RPC_URL: Basis Network L1 endpoint
# - L1_PRIVATE_KEY: Deployer private key (hex, no 0x prefix)
# - Contract addresses (after deployment)
```

### 3. Start the Node

```bash
./basis-l2 --log-level info
```

The node will output structured JSON logs:

```json
{"time":"...","level":"INFO","msg":"starting basis-l2 node","version":"0.1.0","l2_chain_id":431990}
{"time":"...","level":"INFO","msg":"state database initialized","account_depth":32,"storage_depth":32}
{"time":"...","level":"INFO","msg":"sequencer initialized","mempool_capacity":10000}
{"time":"...","level":"INFO","msg":"basis-l2 node started","rpc_addr":"0.0.0.0:8545"}
```

### 4. Verify the Node is Running

```bash
# Check version
./basis-l2 --version

# Check logs (the node produces blocks every 2 seconds)
# Empty blocks are skipped (no transactions in mempool)
```

### 5. Stop the Node

Press Ctrl+C. The node handles SIGINT/SIGTERM gracefully:

```json
{"time":"...","level":"INFO","msg":"received shutdown signal","signal":"interrupt"}
{"time":"...","level":"INFO","msg":"basis-l2 node stopped"}
```

## Configuration

### Command-Line Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--config` | (none) | Path to JSON configuration file |
| `--version` | - | Print version and exit |
| `--log-level` | info | Override log level (debug, info, warn, error) |
| `--data-dir` | (none) | Directory for LevelDB state persistence |

### Configuration File (JSON)

All values have safe defaults. Only override what you need:

```json
{
  "l1": {
    "rpc_url": "https://rpc.basisnetwork.com.co",
    "chain_id": 43199,
    "poll_interval": "5s"
  },
  "l2": {
    "chain_id": 431990,
    "block_interval": "2s",
    "batch_size": 100,
    "gas_limit": 30000000
  },
  "rpc": {
    "host": "0.0.0.0",
    "port": 8545
  },
  "log": {
    "level": "info",
    "format": "json"
  }
}
```

### Environment Variables

Sensitive values are loaded from environment variables:

| Variable | Description |
|----------|-------------|
| `L1_PRIVATE_KEY` | Hex-encoded private key for L1 transactions |

## Docker Deployment

### Build

```bash
# From repository root:
docker build -t basis-l2 -f zkl2/node/Dockerfile .
```

### Run

```bash
docker run -d \
  --name basis-l2-node \
  -p 8545:8545 \
  --env-file zkl2/node/.env \
  basis-l2
```

### Docker Compose

```bash
# Start L2 node:
docker compose up -d l2-node

# Start L2 node + local L1 (development):
docker compose --profile dev up -d
```

## Build from Source

### Go Node

```bash
cd zkl2/node
go build -ldflags="-s -w" -o basis-l2 ./cmd/basis-l2/
```

### Rust Prover

```bash
cd zkl2/prover
cargo build --release
```

### Run Tests

```bash
# Go tests (node + bridge):
cd zkl2/node && go test ./... -count=1
cd zkl2/bridge && go test ./... -count=1

# Rust tests (prover):
cd zkl2/prover && cargo test

# Solidity tests (contracts):
cd zkl2/contracts && npx hardhat test
```

## Current Status (Updated 2026-03-23)

The node is fully operational with E2E pipeline verified on Basis Network L1 (Fuji):

- **JSON-RPC API**: 12+ eth_* methods implemented (MetaMask/Hardhat compatible)
- **Production pipeline**: Real EVM execution traces -> Rust prover IPC -> L1 submission
- **State persistence**: LevelDB backend (use `--data-dir ./data`). Restart recovery verified.
- **L1 synchronizer**: Polls for forced inclusion, deposit events, DAC attestations
- **Contracts**: All 6 contracts + PlonkVerifier deployed on Fuji testnet
- **ZK proofs**: Real PLONK-KZG proofs (86ms, 1376 bytes) verified on-chain (291K gas)

See `docs/POST_ROADMAP_TODO.md` for remaining work (bridge E2E, DAC E2E, security hardening).

## Monitoring

The node outputs structured JSON logs. Use any JSON-aware log aggregator
(Loki, Elasticsearch, CloudWatch) for production monitoring.

Key log fields:

| Field | Description |
|-------|-------------|
| `component` | Source component (sequencer, pipeline, executor) |
| `number` | L2 block number |
| `tx_count` | Transactions in block |
| `batch_id` | Pipeline batch identifier |
