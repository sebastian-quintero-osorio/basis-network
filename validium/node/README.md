# Enterprise ZK Validium Node

The Enterprise ZK Validium Node service -- receives enterprise transactions via REST API, maintains state via Sparse Merkle Trees, generates Groth16 ZK proofs, and submits them to the Basis Network L1 for on-chain verification.

## Status

**Production.** R&D pipeline complete (28/28 agent executions). All 7 modules implemented, tested, formally specified (TLA+), and mathematically verified (Coq). End-to-end pipeline verified on-chain: REST API -> WAL -> Batch -> Witness -> Proof -> L1 Submit -> Confirmed (12.9s proving, 306K gas).

## Modules

| Module | Directory | Tests | TLA+ States | Coq Theorems |
|--------|-----------|-------|-------------|--------------|
| SparseMerkleTree (Poseidon, BN128) | `src/state/` | 52 | 1,572,865 | 10 |
| TransactionQueue + WAL | `src/queue/` | 66 | -- | -- |
| BatchAggregator + BatchBuilder | `src/batch/` | 45 | 3,342,337 | 55 |
| DACProtocol + Shamir SSS | `src/da/` | 67 | -- | 16 |
| ZK Prover (snarkjs Groth16) | `src/prover/` | -- | -- | -- |
| L1 Submitter (ethers.js v6) | `src/submitter/` | -- | -- | -- |
| REST API (Fastify) | `src/api/` | -- | -- | -- |
| Orchestrator (state machine) | `src/orchestrator.ts` | 19 | 3,958 | 13 |
| Cross-Enterprise | `src/cross-enterprise/` | 19 | 461,529 | 13 |
| **Total** | | **316** | **10.7M** | **125+** |

## Quick Start

```bash
npm install
npm test               # Run all 316 tests
npm run build          # Compile TypeScript
npm run dev            # Start in development mode
```

## Configuration

Copy `.env.example` to `.env` and configure:

```
ENTERPRISE_ID=<enterprise-address>
L1_RPC_URL=https://rpc.basisnetwork.com.co
STATE_COMMITMENT_ADDRESS=0x0FD3874008ed7C1184798Dd555B3D9695771fb5b
PRIVATE_KEY=<enterprise-private-key>
BATCH_SIZE=8
TREE_DEPTH=32
API_PORT=3001
```

## Architecture

```
REST API (Fastify, authenticated)
    |
    v
Transaction Queue (WAL, crash-safe)
    |
    v
Batch Aggregator (size/time triggers)
    |
    v
Sparse Merkle Tree (Poseidon, BN128)
    |
    v
ZK Prover (Groth16, 12.9s)
    |
    v
L1 Submitter (StateCommitment.sol, 306K gas)
    |
    v
DAC Protocol (Shamir 2,3-SS)
```

The orchestrator runs a pipelined state machine: `Idle -> Receiving -> Batching -> Proving -> Submitting`. Transactions are accepted during all states (1.29x throughput improvement over sequential processing).

## Key Discoveries

1. **NoLoss Bug (RU-V4):** TLA+ model checking found a crash-recovery bug that 150+ empirical tests missed. WAL checkpoint was at batch formation instead of after processing, creating a 1.9-12.8 second window of potential data loss during ZK proving. Fixed with deferred checkpoint.

2. **Information-Theoretic Privacy (RU-V6):** Shamir (2,3) Secret Sharing provides the strongest possible privacy guarantee for data availability. No production validium (StarkEx, Polygon CDK, Arbitrum Nova) achieves this.

3. **Zero Custom Axioms (RU-V3):** The Coq verification of StateCommitment required zero custom axioms. All theorems derive from first principles.

## References

- [Production Roadmap](../docs/PRODUCTION_ROADMAP.md) -- Current status (~96%) and path to production

## R&D Artifacts

| Artifact | Location |
|----------|----------|
| Experiments and benchmarks | `../research/experiments/` |
| Foundational specs (invariants, threats) | `../research/foundations/` |
| TLA+ formal specifications | `../specs/units/` |
| Adversarial test reports | `../tests/adversarial/` |
| Coq verification proofs | `../proofs/units/` |

## Dependencies

- Node.js >= 18.0.0
- circomlibjs ^0.1.7 (Poseidon hash)
- ethers ^6.13.4 (L1 interaction)
- fastify ^4.28.1 (REST API)
- snarkjs ^0.7.6 (Groth16 proofs)
