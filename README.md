# Basis Network

**Enterprise-grade Avalanche L1 for Latin American industries.**

Basis Network is a sovereign, permissioned blockchain deployed as an Avalanche L1 (Subnet-EVM). It provides companies with zero-fee transactions, data privacy via ZK proofs, and native interoperability with the Avalanche ecosystem.

Built by [Base Computing S.A.S.](https://basecomputing.com.co) — a Colombian deep tech startup with products in production serving real enterprise clients.

---

## The Problem

Latin American enterprises in agribusiness, manufacturing, and logistics need immutable, auditable records of their operations. Current solutions fail:

- **Public blockchains** (Ethereum, Polygon): expensive per-transaction fees and expose proprietary data.
- **Private blockchains** (Hyperledger): isolated silos with no interoperability.
- **No existing blockchain** was designed for the regulatory, linguistic, or operational reality of the region.

## The Solution

Basis Network is an independent Avalanche L1 that gives enterprises their own blockchain infrastructure:

- **Zero-fee transactions** — no gas costs; sustainability via SaaS subscriptions.
- **Permissioned access** — only KYC/KYB-verified enterprises can transact.
- **Privacy by design** — sensitive data stays off-chain; only ZK proofs and hashes are stored on-chain.
- **Interoperable** — native cross-chain communication via Avalanche Warp Messaging (AWM).
- **EVM-compatible** — any Solidity developer can build integrations.

---

## Architecture

```
+----------------------------------------------------------+
|              AVALANCHE PRIMARY NETWORK                    |
|   X-Chain    P-Chain (Validators)    C-Chain (DeFi)       |
|                  |                       |                |
|        Validator Registry      Avalanche Warp Messaging   |
|                  |                       |                |
|   +--------------+-----------------------+-------------+  |
|   |           BASIS NETWORK L1                         |  |
|   |   Custom Subnet-EVM (Zero-Fee, Permissioned)       |  |
|   |                                                    |  |
|   |   Smart Contracts:                                 |  |
|   |   - EnterpriseRegistry (onboarding, permissions)   |  |
|   |   - TraceabilityRegistry (immutable event log)     |  |
|   |   - PLASMAConnector (maintenance traceability)     |  |
|   |   - TraceConnector (commercial traceability)       |  |
|   |   - ZKVerifier (zero-knowledge proof validation)   |  |
|   +----------------------------------------------------+  |
+----------------------------------------------------------+
```

### Enterprise Data Flow

```
PLASMA / Trace (off-chain)  --->  Blockchain Adapter Layer  --->  Basis Network L1
     (existing apps)              (ethers.js, queue, retry)       (immutable record)
```

The adapter uses a **dual-write pattern**: existing applications continue writing to their databases without disruption, while the adapter simultaneously writes critical events on-chain as an immutable audit trail.

---

## Repository Structure

```
basis-network/
├── contracts/              # Smart contracts (Hardhat + Solidity 0.8.24)
│   ├── contracts/
│   │   ├── core/           # EnterpriseRegistry, TraceabilityRegistry
│   │   ├── connectors/     # PLASMAConnector, TraceConnector
│   │   └── verification/   # ZKVerifier
│   ├── test/               # Unit tests (>85% coverage target)
│   └── scripts/            # Deployment scripts
├── l1-config/              # Avalanche L1 genesis and node configuration
├── adapter/                # Blockchain Adapter Layer (Node.js + ethers.js v6)
│   └── src/
│       ├── plasma-adapter/ # PLASMA -> on-chain bridge
│       ├── trace-adapter/  # Trace -> on-chain bridge
│       └── common/         # Shared queue, provider, retry logic
├── prover/                 # ZK proof generation (Circom + SnarkJS)
│   ├── circuits/           # Circom circuits
│   └── scripts/            # Proof generation and setup scripts
├── dashboard/              # Network explorer (Next.js + Tailwind CSS)
└── docs/                   # Technical documentation
```

---

## Tech Stack

| Component | Technology |
|---|---|
| L1 Framework | Subnet-EVM (Avalanche) |
| Consensus | Snowman (sub-second finality) |
| Smart Contracts | Solidity 0.8.24 (EVM target: Cancun) |
| Contract Framework | Hardhat + TypeScript |
| Blockchain Interaction | ethers.js v6 |
| ZK Proofs (PoC) | Circom + SnarkJS (Groth16) |
| Dashboard | Next.js + Tailwind CSS |
| Hosting | Vercel |
| Network | Avalanche Fuji Testnet |

---

## Quick Start

### Prerequisites

- Node.js >= 18
- npm >= 9
- Avalanche CLI ([installation guide](https://build.avax.network/docs/tooling/avalanche-cli))

### Smart Contracts

```bash
cd contracts
npm install
npx hardhat compile
npx hardhat test
```

### Dashboard

```bash
cd dashboard
npm install
npm run dev
```

### ZK Prover

```bash
cd prover
npm install
npm run setup    # One-time trusted setup
npm run prove    # Generate a proof
npm run verify   # Verify the proof locally
```

---

## ZK Validium Architecture

Basis Network implements a **ZK validium** model for enterprise privacy:

1. Enterprises process transactions off-chain (in their own infrastructure or Base Computing hosted nodes).
2. A prover generates ZK proofs (Groth16 via Circom/SnarkJS) that attest to the validity of a batch of transactions without revealing their content.
3. The proof is submitted to `ZKVerifier.sol` on the L1, which verifies it on-chain.
4. The L1 records that "Enterprise X processed N valid transactions" without knowing the details.

This architecture evolves toward full ZK rollups with per-enterprise sequencers and provers, developed through Base Computing's AI-automated R&D pipeline.

### Why Circom/SnarkJS for the PoC

- **Groth16 proofs** are the most gas-efficient to verify on-chain (~200K gas per verification).
- **Circom** is the most mature and battle-tested circuit language in the ZK ecosystem.
- **SnarkJS** provides a complete JavaScript pipeline: compile, setup, prove, verify, and export Solidity verifiers.
- **EVM-native**: the exported Solidity verifier deploys directly to Subnet-EVM without modifications.
- Widely used in production systems (Polygon zkEVM, Iden3, Semaphore, Tornado Cash).

The production roadmap includes migration to more performant proving systems as the R&D pipeline matures.

---

## Key Features for Judges

| Feature | Status | Description |
|---|---|---|
| Avalanche L1 on Fuji | Deployed | Custom Subnet-EVM with zero-fee gas model |
| Permissioned Access | Implemented | Allowlist-controlled transactions and deployments |
| Enterprise Registry | Deployed | On-chain enterprise onboarding and management |
| Industrial Traceability | Deployed | Immutable event recording for maintenance and commerce |
| PLASMA Integration | Working | Real maintenance data from production client on-chain |
| Trace Integration | Working | Commercial transaction data on-chain |
| ZK Verifier PoC | Working | Groth16 proof generation and on-chain verification |
| Network Dashboard | Live | Real-time network activity and enterprise metrics |

---

## Real-World Traction

Basis Network is not a hackathon-only project. It is built on top of real products with real clients:

- **PLASMA** is deployed at Ingenio Sancarlos (one of Colombia's largest sugar mills), delivering 75-91% operational efficiency gains and 300M COP in documented savings.
- **Trace** is a live ERP serving SME clients at ~3M COP/year per client.
- Base Computing generates 50M+ COP in revenue before its first year.

---

## Roadmap

| Phase | Timeline | Milestone |
|---|---|---|
| MVP (current) | Build Games 2026 | L1 on Fuji, smart contracts, ZK verifier PoC, dashboard |
| Mainnet | Months 1-2 post-competition | Migrate to Avalanche Mainnet, production validators |
| First Production Client | Months 3-4 | Ingenio Sancarlos (PLASMA) on mainnet |
| ZK Rollup Evolution | Months 6-12 | Per-enterprise sequencers and provers via R&D pipeline |
| Regional Expansion | Year 2+ | Open infrastructure for LATAM enterprise market |

---

## Business Model

The blockchain is infrastructure, not the product. Revenue streams:

1. **SaaS subscriptions** — PLASMA and Trace (already generating revenue)
2. **Enterprise onboarding** — setup fee + monthly infrastructure subscription
3. **Node hosting** — managed validator nodes for enterprises
4. **BaaS** — API access for third-party developers
5. **Consulting** — custom smart contract development and integration

---

## Team

**Base Computing S.A.S.** — Colombian deep tech startup, founded September 2024.

- Winner of Gen N 2025 "Next" category (Ruta N Medellin)
- "Joven Referente 2026" and Innovation Ambassador (District of Medellin)
- Top 50 / 1,300+ in Nestle Young Creators Challenge 2025
- 20+ hackathon participations with consistent wins
- Accepted into Avalanche Build Games 2026 ($1M prize pool)

---

## License

Business Source License 1.1 — See [LICENSE](./LICENSE) for details.

Copyright (c) 2026 Base Computing S.A.S. All rights reserved.
