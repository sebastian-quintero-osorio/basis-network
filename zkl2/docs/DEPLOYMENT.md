# zkEVM L2 -- Deployment Guide

## Overview

Deploying the zkEVM L2 system involves three components:
1. **L1 Contracts** -- Solidity contracts deployed to Basis Network L1 (Fuji)
2. **L2 Node** -- Go binary that runs the sequencer, prover, and RPC server
3. **Rust Prover** -- ZK proof generation binary (called by the node via IPC)

## Prerequisites

| Tool | Version | Installation |
|------|---------|-------------|
| Go | 1.24+ | https://go.dev/dl/ |
| Rust | 1.83+ | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| Node.js | 18+ | https://nodejs.org/ |
| Git | 2.30+ | https://git-scm.com/ |

## Step 1: Deploy L1 Contracts

### 1.1 Configure

```bash
cd zkl2/contracts
cp .env.example .env
```

Edit `.env`:
```
DEPLOYER_KEY=<hex-private-key-no-0x-prefix>
L1_RPC_URL=https://rpc.basisnetwork.com.co
ENTERPRISE_REGISTRY_ADDRESS=0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5
```

### 1.2 Install Dependencies and Compile

```bash
npm install
npx hardhat compile
```

### 1.3 Deploy

```bash
npx hardhat run scripts/deploy.ts --network fuji
```

This deploys 6 contracts in order:
1. BasisVerifier.sol (proof verification)
2. BasisRollup.sol (state root management, linked to BasisVerifier)
3. BasisBridge.sol (deposit/withdrawal bridge)
4. BasisDAC.sol (data availability committee)
5. BasisAggregator.sol (proof aggregation)
6. BasisHub.sol (cross-enterprise settlement)

Record the deployed addresses from the output.

### 1.4 Deploy PlonkVerifier (if using PLONK proofs)

```bash
npx hardhat run scripts/deploy-plonk-verifier.ts --network fuji
```

## Step 2: Build the Rust Prover

```bash
cd zkl2/prover
cargo build --release
```

The binary is at `target/release/basis-prover`. Verify:
```bash
./target/release/basis-prover --help
```

## Step 3: Build and Configure the L2 Node

### 3.1 Build

```bash
cd zkl2/node
go build -o basis-l2 ./cmd/basis-l2/
```

### 3.2 Configure

```bash
cp .env.example .env
```

Edit `.env` with:
- `L1_PRIVATE_KEY`: Operator private key (same as deployer or separate)
- `BASIS_ROLLUP_ADDRESS`: From Step 1.3 output
- `BASIS_BRIDGE_ADDRESS`: From Step 1.3 output
- `BASIS_DAC_ADDRESS`: From Step 1.3 output
- `BASIS_HUB_ADDRESS`: From Step 1.3 output
- `BASIS_AGGREGATOR_ADDRESS`: From Step 1.3 output
- `BASIS_VERIFIER_ADDRESS`: From Step 1.3 output
- `PROVER_BINARY_PATH`: Absolute path to `basis-prover` binary from Step 2

### 3.3 Initialize Enterprise

Before the node can submit batches, the enterprise must be registered on L1:

```bash
go build -o init-enterprise ./cmd/init-enterprise/
./init-enterprise \
  --l1-rpc https://rpc.basisnetwork.com.co \
  --rollup <BASIS_ROLLUP_ADDRESS> \
  --key <private-key-hex> \
  --enterprise <enterprise-address>
```

## Step 4: Run the L2 Node

```bash
./basis-l2 --log-level info --data-dir ./data
```

The node will:
1. Initialize StateDB with Poseidon SMT
2. Start the sequencer (block production every 2s)
3. Start the JSON-RPC server on port 8545
4. Start the L1 synchronizer (polls for forced inclusion/deposits)
5. Process transactions through the proving pipeline

## Step 5: Verify Deployment

```bash
# Check RPC
curl -s http://localhost:8545 -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'

# Run E2E contract test
go build -o e2e-contract-test ./cmd/e2e-contract-test/
./e2e-contract-test --rpc http://localhost:8545
```

## Docker Deployment

### Build

```bash
docker build -t basis-l2 -f zkl2/node/Dockerfile .
```

### Run

```bash
docker run -d \
  --name basis-l2-node \
  -p 8545:8545 \
  -v $(pwd)/data:/data \
  --env-file zkl2/node/.env \
  -e DATA_DIR=/data \
  basis-l2
```

### Docker Compose

```bash
cd zkl2
docker compose up -d
```

## Fuji Testnet Reference

| Resource | Value |
|----------|-------|
| L1 RPC | https://rpc.basisnetwork.com.co |
| L1 Chain ID | 43199 |
| L2 Chain ID | 431990 |
| Token | LITHOS (smallest unit: Tomo) |
| Gas model | Near-zero fee (minBaseFee: 1 wei) |
| EnterpriseRegistry | 0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5 |

## Production Considerations

- Always use `--data-dir` for state persistence
- Configure `L1_PRIVATE_KEY` via environment variable, never in config files
- Use a reverse proxy (Nginx) for TLS termination on the RPC endpoint
- Monitor node logs for `error` level messages
- Set up the Rust prover binary path as an absolute path
- Ensure the operator account has sufficient LITHOS for L1 gas
