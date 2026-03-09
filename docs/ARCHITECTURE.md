# Architecture

## System Overview

Basis Network is a three-layer architecture built on Avalanche:

### Layer 1 — Avalanche Primary Network

The global Avalanche network provides security, interoperability, and validator infrastructure. Basis Network anchors to the P-Chain for validator registration and uses Avalanche Warp Messaging (AWM) for cross-chain communication with the C-Chain.

### Layer 2 — Basis Network L1

A customized Subnet-EVM blockchain with:

- **Zero-fee gas model** (`minBaseFee: 0`, `minBlockGasCost: 0`, `maxBlockGasCost: 0`)
- **Transaction allowlist** — only authorized enterprise wallets can send transactions
- **Contract deployer allowlist** — only admin addresses can deploy smart contracts
- **Permissioned validators** — participating enterprises validate the network

Smart contracts deployed on this layer handle enterprise registration, event recording, product-specific connectors, and ZK proof verification.

### Layer 3 — Enterprise Instances (Future)

Each enterprise gets a private execution environment implemented as a ZK validium:

- Transactions are processed off-chain in enterprise infrastructure
- ZK proofs attest to transaction validity without revealing data
- Proofs are verified on-chain by `ZKVerifier.sol`
- The L1 records "Enterprise X processed N valid transactions" with no content exposure

This evolves toward full ZK rollups with per-enterprise sequencers and provers.

---

## Component Architecture

### Smart Contract Layer

```
EnterpriseRegistry.sol          TraceabilityRegistry.sol
    |                                   |
    | (authorization check)             | (event recording)
    v                                   v
PLASMAConnector.sol             TraceConnector.sol
    |                                   |
    | (maintenance events)              | (commercial events)
    v                                   v
                ZKVerifier.sol
                    |
                    | (batch proof verification)
                    v
              On-chain state root
```

**EnterpriseRegistry** manages enterprise onboarding and permissions. Only the network admin (Base Computing) can register or deactivate enterprises. Enterprises can update their own metadata.

**TraceabilityRegistry** records immutable, timestamped operational events. It supports predefined event types: maintenance orders, supply chain checkpoints, quality certifications, equipment inspections, and inventory movements.

**PLASMAConnector** bridges the PLASMA industrial maintenance platform to the blockchain. It records work order creation, completion, and equipment inspections.

**TraceConnector** bridges the Trace ERP platform. It records sales, inventory movements, and supplier transactions.

**ZKVerifier** verifies Groth16 zero-knowledge proofs on-chain. It validates that a batch of enterprise transactions is correct without accessing the underlying data.

### Blockchain Adapter Layer

```
PLASMA Backend  ----\
                     +---> Transaction Queue ---> ethers.js Provider ---> L1 RPC
Trace Backend   ----/          |
                          Retry Logic
                          Batch Processing
                          Error Handling
```

The adapter implements a **dual-write pattern**:

1. Existing applications (PLASMA, Trace) continue writing to their databases normally.
2. The adapter listens for relevant events and writes them on-chain simultaneously.
3. If the blockchain is temporarily unavailable, events are queued and synced when connectivity is restored.

This design ensures zero disruption to existing operations.

### ZK Prover Pipeline

```
Enterprise Transactions (off-chain)
    |
    v
Circom Circuit (batch_verifier.circom)
    |
    v
SnarkJS (Groth16 proof generation)
    |
    v
Proof + Public Signals
    |
    v
ZKVerifier.sol (on-chain verification)
    |
    v
Verification result recorded on L1
```

### Dashboard

```
Next.js Application
    |
    +---> ethers.js ---> Basis Network L1 RPC
    |         |
    |         +---> Contract ABIs ---> Read on-chain data
    |         +---> Block/Tx queries ---> Network stats
    |
    +---> Server-side rendering ---> Vercel deployment
```

The dashboard displays:
- Registered enterprises and their status
- Real-time transaction activity
- Event breakdown by type (maintenance, sales, inventory, etc.)
- Network metrics (block height, gas price confirmation of zero-fee)
- ZK proof verification status

---

## Data Flow

### On-Chain Data (stored on L1)

- Enterprise registration records (address, name, metadata hash, status)
- Event hashes and metadata (event type, asset ID, timestamp, enterprise)
- Maintenance order IDs, equipment IDs, priorities, completion status
- Sale IDs, product IDs, quantities, amounts
- ZK proof verification results (proof hash, verification status, batch size)

### Off-Chain Data (stays in enterprise databases)

- Detailed text descriptions (work order details, notes)
- Photos, attachments, documents
- User interface data, session management
- Real-time sensor data (high frequency)
- Personally identifiable information (PII)

This separation ensures compliance with data privacy regulations while maintaining an immutable audit trail.

---

## Network Configuration

| Parameter | Value | Rationale |
|---|---|---|
| `minBaseFee` | 0 | Zero-fee model; costs covered by SaaS subscriptions |
| `gasLimit` | 15,000,000 | Standard EVM block gas limit |
| `targetBlockRate` | 2 seconds | Balance between throughput and finality |
| `txAllowList` | Enabled | Only authorized enterprises can transact |
| `contractDeployerAllowList` | Enabled | Only admins can deploy contracts |
| `allowFeeRecipients` | false | No fee distribution needed with zero-fee model |

---

## Security Model

1. **Network level:** Permissioned validators, transaction allowlist, deployer allowlist.
2. **Contract level:** Role-based access control (Admin, Enterprise roles).
3. **Data level:** Sensitive data never touches the blockchain. Only hashes and ZK proofs.
4. **Cross-chain level:** AWM provides native, validator-secured communication (no third-party bridges).
