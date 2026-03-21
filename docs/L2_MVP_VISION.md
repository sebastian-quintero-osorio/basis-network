# Basis Network L2: Enterprise ZK Validium

## Status: COMPLETE

The Enterprise ZK Validium Node is fully operational, verified on-chain, and backed by formal verification. All 7 modules have been researched, formally specified (TLA+), implemented, adversarially tested, and mathematically verified (Coq).

## What We Built

An **Enterprise ZK Validium Node** -- an application-specific execution environment that allows each enterprise on the Basis Network to process transactions privately, generate zero-knowledge proofs of correctness, and submit those proofs to the Basis Network L1 (Avalanche Subnet-EVM) for on-chain verification.

This is NOT a general-purpose blockchain. It is a **privacy-preserving verification layer** tailored for Latin American enterprises that need auditability without data exposure.

## Why We Built It

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

## Current State

### Operational Components

| Component | Status | Details |
|-----------|--------|---------|
| **L1 Network** | Live on Fuji testnet | Chain ID 43199, near-zero-fee, permissioned |
| **Smart Contracts (7)** | Deployed | EnterpriseRegistry, TraceabilityRegistry, ZKVerifier, Groth16Verifier, StateCommitment, DACAttestation, CrossEnterpriseVerifier |
| **Enterprise Node** | Complete | 316 tests passing, 7 modules |
| **ZK Circuit** | Production | state_transition.circom (depth 32, batch 8, 274,291 constraints) |
| **ZK Pipeline** | Verified on-chain | 12.9s proof generation, 306K gas verification |
| **Sparse Merkle Tree** | Production | Poseidon hash, BN128 curve, 52 tests |
| **Transaction Queue + WAL** | Production | Crash-recovery proven, 66 tests |
| **Batch Aggregator** | Production | Size/time triggers, 45 tests |
| **DAC + Shamir SSS** | Production | Information-theoretic privacy, 67 tests |
| **Cross-Enterprise Verifier** | Production | Hub-and-spoke model, 19 tests |
| **Orchestrator** | Production | Pipelined state machine, 19 tests |
| **REST API** | Production | Fastify, rate-limited, authenticated |
| **Dashboard** | Live on Vercel | 6 pages including Validium view |
| **TLA+ Specifications** | Complete | 7 specs, 10.7M states explored, all invariants pass |
| **Coq Proofs** | Complete | 125+ theorems, 0 Admitted |
| **Adversarial Tests** | Complete | ~100 attack vectors, all rejected |
| **CI/CD** | Automated | GitHub Actions, 604+ tests |

## Architecture

### System Overview

```
Enterprise Systems                 Enterprise ZK Validium Node           Basis Network L1 (Avalanche)
+---------------+                +-------------------------+           +------------------------+
|   PLASMA      |---events--->   |  1. REST API (Fastify)  |           |                        |
|   (maint.)    |                |     Authenticated       |           |  StateCommitment.sol   |
+---------------+                |          |              |           |   - stateRoots[ent]    |
                                 |          v              |           |   - batchHistory[]     |
+---------------+                |  2. Transaction Queue   |           |                        |
|   Trace       |---events--->   |     WAL (crash-safe)    |           |  Groth16Verifier.sol   |
|   (ERP)       |                |          |              |           |   - verifyProof()      |
+---------------+                |          v              |           |                        |
                                 |  3. Batch Aggregator    |           |  DACAttestation.sol    |
+---------------+                |     Size/time triggers  |           |   - attestations       |
|   Future      |---events--->   |          |              |           |                        |
|   Systems     |                |          v              |  proof +  |  CrossEnterprise       |
+---------------+                |  4. Sparse Merkle Tree  |  state   |  Verifier.sol          |
                                 |     Poseidon, BN128     |  root    |   - cross-ref proofs   |
                                 |          |              |--------->|                        |
                                 |          v              |           |  EnterpriseRegistry    |
                                 |  5. ZK Prover           |           |   .sol                 |
                                 |     Groth16 (12.9s)     |           |   - permissions        |
                                 |          |              |           |                        |
                                 |  6. L1 Submitter        |           +------------------------+
                                 |     ethers.js v6        |
                                 |          |              |
                                 |  7. DAC (Shamir SSS)    |
                                 |     Data availability   |
                                 +-------------------------+
```

### Data Flow

1. **Enterprise systems** (PLASMA, Trace, future integrations) emit events when business operations occur.
2. **REST API** receives events, validates authentication (Bearer token + API key), applies rate limiting.
3. **Transaction Queue** persists events to a Write-Ahead Log (WAL) with SHA-256 checksums for crash recovery.
4. **Batch Aggregator** collects transactions until a batch threshold is reached (configurable: 8, 16, 64).
5. **Sparse Merkle Tree** updates state. Each transaction modifies a leaf in the Poseidon-based tree.
6. **ZK Prover** generates a Groth16 proof that the batch is valid:
   - Public inputs: previous state root, new state root, batch number, enterprise ID.
   - Private inputs: individual transaction data (never revealed).
7. **L1 Submitter** calls `StateCommitment.sol` to verify the proof via `Groth16Verifier.sol` and update the enterprise's state root.
8. **DAC Protocol** distributes data via Shamir (2,3) Secret Sharing for information-theoretic privacy.

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
| Enterprise Node | TypeScript (Node.js >= 18) | Team expertise, existing adapter layer, ethers.js/SnarkJS ecosystem |
| REST API | Fastify 4.x | 2-4x throughput advantage over Express |
| State Tree | Sparse Merkle Tree (circomlibjs Poseidon) | ZK-friendly hash, proven in production ZK systems |
| ZK Circuits | Circom 2.2.3 + SnarkJS 0.7.6 (Groth16) | Most gas-efficient on-chain verification |
| L1 Interaction | ethers.js v6 | Already in use across the project |
| L1 Contracts | Solidity 0.8.24 (evmVersion: cancun) | Avalanche constraint, existing infrastructure |
| Data Availability | Shamir (2,3) Secret Sharing | Information-theoretic privacy (unique in production validiums) |
| Formal Specification | TLA+ (TLC model checker) | Exhaustive state space exploration |
| Formal Verification | Coq/Rocq 9.0.1 | Mathematical correctness proofs |

## Key Innovations

### 1. Information-Theoretic Privacy via Shamir Secret Sharing

No production validium (StarkEx, Polygon CDK, Arbitrum Nova) provides data privacy. They give complete batch data to every DAC member. Basis Network uses Shamir (2,3)-SS to achieve information-theoretic privacy -- the strongest cryptographic guarantee. A single compromised DAC node reveals zero bits of enterprise data.

### 2. Formal Verification Catches Silent Data Loss

TLA+ model checking discovered a crash-recovery bug that 150+ empirical tests missed:
- **Bug**: WAL checkpoint at batch formation (not after processing)
- **Window**: 1.9-12.8 seconds during ZK proving (silent transaction loss on crash)
- **Fix**: Defer checkpoint to after batch processing
- **Result**: Verified with TLC model checking and Coq proofs

### 3. Zero Unproven Assumptions

The Coq verification of StateCommitment.sol required zero custom axioms. All 11 theorems derive from first principles. ChainContinuity, NoGap, NoReversal, and ProofBeforeState hold for all possible contract executions, not just tested scenarios.

## Competitive Positioning

| Feature | Basis Network | Rayls | ZKsync Prividium | Polygon CDK Enterprise |
|---------|---------------|-------|------------------|----------------------|
| Target Market | LATAM industry and commerce | Global financial institutions | Global financial institutions | Global institutions |
| ZK System | Groth16 (Circom) | Custom ZK + post-quantum | Custom ZK validity proofs | PLONK (custom prover) |
| Settlement Layer | Avalanche L1 | Commit chain | Ethereum | Ethereum |
| Cost Model | Zero-fee (subsidized) | Institutional pricing | Gas fees | Gas fees |
| Data Availability | DAC with Shamir SSS | Institution-managed | Operator-managed | DAC or on-chain |
| DA Privacy | Information-theoretic | None | None | None |
| Formal Verification | TLA+ + Coq (125+ theorems) | Unknown | Unknown | Unknown |
| Existing Products | PLASMA, Trace (in production) | Privacy Node | Prividium chains | CDK chains |
| Client Size | SMEs, mid-market, industrial | Tier 1 banks (JP Morgan) | Tier 1 banks (Deutsche Bank) | Large enterprises |

**Key differentiator**: Basis Network targets the underserved Latin American mid-market enterprise segment with zero-fee infrastructure, information-theoretic data privacy, formal verification, and existing production software (PLASMA, Trace), while competitors focus on global Tier 1 financial institutions.

## Success Criteria (All Met)

1. An enterprise can submit transactions to the node, which generates ZK proofs and verifies them on the L1. **DONE**
2. State roots form a verifiable chain on the L1 -- no gaps, no reversals. **DONE (proven in Coq)**
3. No private data is exposed at any point in the process. **DONE (information-theoretic guarantee)**
4. The system handles 8-transaction batches with proof generation under 15 seconds. **DONE (12.9s)**
5. Adversarial tests confirm that invalid proofs are rejected and replayed batches are detected. **DONE (~100 attack vectors)**
6. All modules formally specified in TLA+ and verified in Coq. **DONE (125+ theorems, 0 Admitted)**
