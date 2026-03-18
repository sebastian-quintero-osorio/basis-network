# Basis Network L2: MVP Vision Document

## What We Are Building

An **Enterprise ZK Validium Node** -- an application-specific execution environment that allows each enterprise on the Basis Network to process transactions privately, generate zero-knowledge proofs of correctness, and submit those proofs to the Basis Network L1 (Avalanche Subnet-EVM) for on-chain verification.

This is NOT a general-purpose blockchain. It is a **privacy-preserving verification layer** tailored for Latin American enterprises that need auditability without data exposure.

## Why We Are Building It

### The Problem

Latin American enterprises face a fundamental tension:

1. **They need immutable, auditable records** -- regulatory compliance, supply chain traceability, financial transparency.
2. **They cannot expose operational data** -- production volumes, pricing, supplier relationships, and maintenance records are competitive secrets.

Traditional blockchains force a binary choice: full transparency (public chains) or full isolation (private databases). Neither serves the enterprise market.

### The Solution

The ZK Validium architecture resolves this tension mathematically:

- **Enterprises execute transactions locally** -- in their existing systems (PLASMA for industrial maintenance, Trace for commercial ERP, or any future system).
- **A ZK proof is generated** -- proving that all transactions in a batch are valid without revealing any transaction data.
- **The proof is verified on the Basis Network L1** -- providing an immutable, publicly auditable record that the enterprise's operations are correct.

**Result**: Complete data privacy with cryptographic auditability. An auditor can verify that an enterprise processed 10,000 transactions correctly without learning what any of those transactions contained.

### Why Now

1. **We already have the infrastructure**: Basis Network L1 is live on Avalanche Fuji with 5 deployed contracts, zero-fee gas, and a working ZK verifier.
2. **We already have the clients**: PLASMA is deployed at Ingenio Sancarlos (sugar mill), Trace is generating revenue with SME clients.
3. **We already have the ZK pipeline**: Groth16 circuits, trusted setup, proof generation, and on-chain verification -- all working.
4. **The market demands it**: Rayls (Brazil) was selected by J.P. Morgan, ZKsync Prividiums are used by Deutsche Bank, Polygon CDK Enterprise powers institutional chains. Enterprise ZK privacy is not a hypothesis -- it is a validated market.

## Current State

### What Exists (Working)

| Component | Status | Details |
|-----------|--------|---------|
| **L1 Network** | Live on Fuji testnet | Chain ID 43199, 412+ blocks, zero-fee, permissioned |
| **EnterpriseRegistry.sol** | Deployed | 4 enterprises registered, role-based access control |
| **TraceabilityRegistry.sol** | Deployed | 9 events recorded, immutable audit trail |
| **PLASMAConnector.sol** | Deployed | Bridge for industrial maintenance data |
| **TraceConnector.sol** | Deployed | Bridge for commercial ERP data |
| **ZKVerifier.sol** | Deployed | Groth16 proof verification (~200K gas), working on-chain |
| **batch_verifier.circom** | Working | 742 constraints, batch size 4, Groth16 proof generation |
| **Adapter Layer** | Working | TypeScript adapters for PLASMA and Trace with transaction queue |
| **Dashboard** | Live on Vercel | 4 pages, real-time data, professional design |
| **CI/CD** | Automated | GitHub Actions, all 72 tests passing |

### What is Missing (MVP Scope)

| Component | Priority | Description |
|-----------|----------|-------------|
| **Sparse Merkle Tree** | Critical | State management for enterprise data with efficient proofs |
| **Batch Aggregator** | Critical | Groups transactions into provable batches (scale from 4 to 64+) |
| **State Root Chaining** | Critical | L1 contract tracking state root history per enterprise |
| **Enterprise Node Service** | Critical | Unified service combining sequencer, state, prover, submitter |
| **Enhanced Circuits** | High | Production-grade Circom circuits for larger batches and richer data |
| **Data Availability Layer** | High | Enterprise-managed DA with DAC attestation |
| **Cross-Enterprise Proofs** | Medium | Hub-and-spoke model for inter-enterprise verification |

## Architecture

### System Overview

```
Enterprise Systems                 Enterprise ZK Validium Node           Basis Network L1 (Avalanche)
+---------------+                +-------------------------+           +------------------------+
|   PLASMA      |---events--->   |  1. Transaction Queue   |           |                        |
|   (maint.)    |                |     Receives & orders   |           |  StateCommitment.sol   |
+---------------+                |          |              |           |   - stateRoots[ent]    |
                                 |          v              |           |   - batchHistory[]     |
+---------------+                |  2. State Machine       |           |                        |
|   Trace       |---events--->   |     Sparse Merkle Tree  |           |  ZKVerifier.sol        |
|   (ERP)       |                |     Update & track      |           |   - verifyProof()      |
+---------------+                |          |              |           |                        |
                                 |          v              |           |  EnterpriseRegistry    |
+---------------+                |  3. Batch Aggregator    |           |   .sol                 |
|   Future      |---events--->   |     Group into batches  |           |   - permissions        |
|   Systems     |                |          |              |           |   - authorization      |
+---------------+                |          v              |  proof +  |                        |
                                 |  4. ZK Prover           |  state   |  Bridge.sol            |
                                 |     Circom + SnarkJS    |  root    |   - deposits           |
                                 |     Generate Groth16    |--------->|   - withdrawals        |
                                 |          |              |           |                        |
                                 |  5. L1 Submitter        |           +------------------------+
                                 |     ethers.js v6        |
                                 +-------------------------+
```

### Data Flow

1. **Enterprise systems** (PLASMA, Trace, future integrations) emit events when business operations occur.
2. **Transaction Queue** receives events, validates format, and orders them chronologically.
3. **State Machine** maintains a Sparse Merkle Tree. Each transaction updates the tree.
4. **Batch Aggregator** collects transactions until a batch threshold is reached (configurable: 16, 64, 256).
5. **ZK Prover** generates a Groth16 proof that the batch is valid:
   - Public inputs: previous state root, new state root, batch size, enterprise ID.
   - Private inputs: individual transaction data (never revealed).
6. **L1 Submitter** calls the Basis Network L1 to verify the proof and update the enterprise's state root.

### What the L1 Stores Per Enterprise

```solidity
struct EnterpriseState {
    bytes32 currentStateRoot;     // Latest verified Merkle root
    bytes32 previousStateRoot;    // For chain verification
    uint256 batchCount;           // Total verified batches
    uint256 lastBatchTimestamp;   // When the last batch was verified
    bool isActive;                // Enterprise status
}
```

### Privacy Guarantee

The L1 contract sees ONLY:
- Enterprise ID (public -- already registered)
- Previous and new state roots (cryptographic hashes -- reveal nothing about content)
- Batch size (number of transactions -- not their content)
- ZK proof (mathematical object -- reveals nothing about private inputs)

Nobody on the L1 can determine: what the transactions were, who the counterparties were, what amounts were involved, or what business operations occurred.

## Technology Stack

| Component | Technology | Justification |
|-----------|------------|---------------|
| Enterprise Node | TypeScript (Node.js) | Team expertise, existing adapter layer, ethers.js/SnarkJS ecosystem |
| State Tree | Sparse Merkle Tree (circomlibjs Poseidon) | ZK-friendly hash, proven in production ZK systems |
| ZK Circuits | Circom 2.x + SnarkJS (Groth16) | Already working, constraint-level control, mature tooling |
| L1 Interaction | ethers.js v6 | Already in use across the project |
| L1 Contracts | Solidity 0.8.24 (evmVersion: cancun) | Avalanche constraint, existing infrastructure |

## Relationship to Existing Infrastructure

The MVP **extends** the current Basis Network, not replaces it:

- `l1/contracts/` -- Existing L1 contracts remain. New `StateCommitment.sol` is added.
- `validium/circuits/` -- Existing circuits are the foundation. Enhanced circuits replace `batch_verifier.circom`.
- `validium/adapters/` -- Existing adapters inform the enterprise node design. The node subsumes adapter functionality.
- `l1/dashboard/` -- Extended to show per-enterprise state roots, batch history, and proof status.

## Development Plan

The R&D pipeline (4-agent system in `lab/`) will research, formalize, implement, and verify each component. The pipeline produces production-grade code, not prototypes. All pipeline output is stored in `validium/`, not in `lab/`:

| Pipeline Stage | Agent | Output Location |
|---------------|-------|-----------------|
| Research | Scientist | `validium/research/experiments/` |
| Formal Specification | Logicist | `validium/specs/units/` |
| Implementation | Architect | `validium/node/`, `validium/circuits/` |
| Adversarial Testing | Architect | `validium/tests/adversarial/` |
| Verification | Prover | `validium/proofs/units/` |

The detailed execution plan is in [`validium/ROADMAP.md`](../validium/ROADMAP.md).

### Phase 1: State Management (Week 1)
- Sparse Merkle Tree implementation with Poseidon hash
- State root computation and update logic
- Merkle proof generation for individual entries

### Phase 2: Enhanced ZK Circuits (Week 1-2)
- Scale batch_verifier from 4 to 64 transactions
- Add state root chaining to circuit (previous root -> new root)
- Constraint optimization and benchmarking

### Phase 3: Enterprise Node (Week 2)
- Transaction queue with retry and ordering
- Batch aggregator with configurable thresholds
- L1 submitter with proof formatting
- Unified node service

### Phase 4: L1 Contracts (Week 2)
- StateCommitment.sol -- state root history and batch tracking
- Enhanced ZKVerifier.sol -- production-grade verification with state chaining
- Integration with EnterpriseRegistry for access control

### Phase 5: Integration and Testing (Week 3)
- End-to-end: PLASMA event -> enterprise node -> ZK proof -> L1 verification
- Adversarial testing: invalid proofs, replayed batches, state root manipulation
- Performance benchmarking: proof generation time, batch throughput

## Competitive Positioning

| Feature | Basis Network | Rayls | ZKsync Prividium | Polygon CDK Enterprise |
|---------|---------------|-------|------------------|----------------------|
| Target Market | LATAM industry & commerce | Global financial institutions | Global financial institutions | Global institutions |
| ZK System | Groth16 (Circom) | Custom ZK + post-quantum | Custom ZK validity proofs | PLONK (custom prover) |
| Settlement Layer | Avalanche L1 | Commit chain | Ethereum | Ethereum |
| Cost Model | Zero-fee (subsidized) | Institutional pricing | Gas fees | Gas fees |
| Data Availability | Enterprise-managed | Institution-managed | Operator-managed | DAC or on-chain |
| Existing Products | PLASMA, Trace (in production) | Privacy Node | Prividium chains | CDK chains |
| Client Size | SMEs, mid-market, industrial | Tier 1 banks (JP Morgan) | Tier 1 banks (Deutsche Bank) | Large enterprises |

**Key differentiator**: Basis Network targets the underserved Latin American mid-market enterprise segment with zero-fee infrastructure and existing production software (PLASMA, Trace), while competitors focus on global Tier 1 financial institutions.

## Success Criteria

The MVP is complete when:

1. An enterprise can submit transactions to the node, which generates ZK proofs and verifies them on the L1.
2. State roots form a verifiable chain on the L1 -- no gaps, no reversals.
3. No private data is exposed at any point in the process.
4. The system handles at least 64-transaction batches with proof generation under 60 seconds.
5. Adversarial tests confirm that invalid proofs are rejected and replayed batches are detected.
