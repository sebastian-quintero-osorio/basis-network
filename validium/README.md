# Enterprise ZK Validium

[![CI](https://github.com/sebastian-quintero-osorio/basis-network/actions/workflows/ci.yml/badge.svg)](https://github.com/sebastian-quintero-osorio/basis-network/actions/workflows/ci.yml)

Production-grade ZK validium system for Basis Network. Each enterprise operates a private validium node that processes transactions off-chain, generates Groth16 zero-knowledge proofs, and submits them to the Basis Network L1 for on-chain verification.

**Status:** Fully operational and verified on-chain. All 7 modules implemented, tested, formally specified (TLA+), and mathematically verified (Coq).

## Components

| Directory | Description | Status |
|-----------|-------------|--------|
| [node/](./node/) | Enterprise validium node service (TypeScript) | Production (316 tests) |
| [circuits/](./circuits/) | ZK circuits (Circom 2.2.3 + SnarkJS 0.7.6) | Production (274K constraints) |
| [adapters/](./adapters/) | Blockchain adapter layer (ethers.js v6) | Working |
| [specs/](./specs/) | TLA+ formal specifications (model-checked) | Complete (10.7M states) |
| [proofs/](./proofs/) | Coq verification proofs | Complete (125+ theorems, 0 Admitted) |
| [research/](./research/) | R&D experiments and foundational specs | Complete (7 experiments) |
| [tests/](./tests/) | Adversarial test reports | Complete (~100 attack vectors) |
| [docs/](./docs/) | Roadmap, checklist, pipeline report | Complete |

## Pipeline

```
Enterprise App --> REST API --> WAL --> Batch Aggregator --> Sparse Merkle Tree
                                                                    |
                                                             ZK Prover (12.9s)
                                                                    |
                                                            L1 Submit (306K gas)
                                                                    |
                                                          DAC (Shamir SSS)
```

## Node Modules

| Module | Description | Tests |
|--------|-------------|-------|
| SparseMerkleTree | Poseidon-based state management (BN128) | 52 |
| TransactionQueue + WAL | Durable transaction ordering with crash recovery | 66 |
| BatchAggregator + BatchBuilder | Configurable batching with Circom witness generation | 45 |
| DACProtocol + Shamir SSS | Data availability with information-theoretic privacy | 67 |
| ZK Prover | Groth16 proof generation via snarkjs | -- |
| L1 Submitter | On-chain submission via ethers.js v6 | -- |
| REST API | Fastify-based authenticated enterprise API | -- |
| Orchestrator | Pipelined state machine | 19 |
| Cross-Enterprise | Hub-and-spoke cross-reference builder | 19 |

## Formal Verification

Every module is backed by three layers of verification:

| Layer | Tool | Metric |
|-------|------|--------|
| Formal specification | TLA+ (TLC model checker) | 10.7M states explored, all invariants pass |
| Mathematical proof | Coq/Rocq 9.0.1 | 125+ theorems, 0 Admitted (zero unproven assumptions) |
| Adversarial testing | Custom attack scenarios | ~100 attack vectors, all rejected |

**Key discovery:** TLA+ model checking found a crash-recovery bug (NoLoss invariant violation) that 150+ empirical tests missed. The fix was verified in both TLA+ and Coq.

## ZK Circuit

| Parameter | Value |
|-----------|-------|
| Circuit | `state_transition.circom` (depth=32, batch=8) |
| Constraints | 274,291 |
| Proof system | Groth16 (BN128) |
| Trusted setup | Powers of Tau 2^19 |
| Proof generation | 12.9 seconds |
| On-chain verification | 306K gas |

## Quick Start

```bash
# Node
cd node && npm install && npm test

# Circuits (requires Circom installed)
cd circuits && npm install && npm run setup && npm run prove && npm run verify
```

## Documentation

| Document | Description |
|----------|-------------|
| [Production Roadmap](./docs/PRODUCTION_ROADMAP.md) | Current status (~96% complete) and path to production |
| [Objectives & Invariants](./research/foundations/zk-01-objectives-and-invariants.md) | System safety and liveness properties |
| [Threat Model](./research/foundations/zk-02-threat-model.md) | 60+ attack vectors catalogued |
