# Enterprise zkEVM L2

The long-term evolution of Basis Network -- a full zero-knowledge EVM-compatible Layer 2 where each enterprise operates their own chain with dedicated sequencer, EVM executor, ZK prover, and data availability layer. Settles on the Basis Network L1 (Avalanche).

**Status:** Architecture 80% complete. EVM Executor implemented (1,748 lines Go). 386 contract tests. Built in days via the AI-driven R&D pipeline.

## Architecture

```
Enterprise DApp --> Sequencer --> EVM Executor --> State DB (Poseidon SMT)
                                                        |
                                                  Witness Generator
                                                        |
                                                  ZK Prover (Rust, PLONK)
                                                        |
                                              L1 Settlement (BasisRollup.sol)
                                                        |
                                                  Bridge + DAC
```

## Components

| Directory | Technology | Description | Status |
|-----------|-----------|-------------|--------|
| [node/](./node/) | Go | L2 node (sequencer, EVM executor, state DB) | In development |
| [prover/](./prover/) | Rust | ZK prover (witness generation, circuit, aggregation) | In development |
| [contracts/](./contracts/) | Solidity | L1 settlement contracts (386 tests) | In development |
| [bridge/](./bridge/) | Go | Cross-layer message relay | Planned |
| [specs/](./specs/) | TLA+ | Formal specifications | In progress |
| [proofs/](./proofs/) | Coq | Formal verification | In progress |
| [research/](./research/) | -- | R&D experiments | In progress |
| [tests/](./tests/) | -- | Adversarial test reports | In progress |
| [docs/](./docs/) | -- | Architecture, decisions, roadmap | Complete |

## L1 Settlement Contracts

| Contract | Purpose |
|----------|---------|
| BasisRollup.sol | State root verification + ZK proof verification |
| BasisBridge.sol | Deposit/withdrawal bridge with escape hatch |
| BasisDAC.sol | Data availability committee management |
| BasisGovernance.sol | Protocol parameter updates |

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| L2 Node Language | Go | Geth heritage, goroutine concurrency, blockchain maturity |
| ZK Prover Language | Rust | Memory safety, zero-cost abstractions, native ZK libraries |
| Proof System | PLONK (target) | Universal setup, custom gates, 300K gas verification |
| Data Availability | Validium mode | Enterprise-managed, only proofs on L1 |
| State Tree | Poseidon SMT | 500x constraint reduction vs Keccak |
| Architecture | Per-enterprise chains | Maximum data sovereignty |

## Roadmap

| Phase | Research Units | Focus |
|-------|---------------|-------|
| 1. L2 Foundation | RU-L1 to RU-L4 | EVM Executor, Sequencer, State DB |
| 2. ZK Proving | RU-L3, RU-L5, RU-L6 | Witness generation, L1 settlement, E2E pipeline |
| 3. Bridge & DA | RU-L7, RU-L8 | Bridge with escape hatch, production DAC |
| 4. Production Hardening | RU-L9, RU-L10 | PLONK migration, proof aggregation |
| 5. Enterprise Features | RU-L11 | Cross-enterprise hub-and-spoke verification |

## Documentation

| Document | Description |
|----------|-------------|
| [Vision](./docs/VISION.md) | Long-term zkEVM L2 strategy |
| [Architecture](./docs/ARCHITECTURE.md) | 4-layer system design |
| [Technical Decisions](./docs/TECHNICAL_DECISIONS.md) | 9 justified ADRs |
| [Roadmap](./docs/ROADMAP.md) | 11 research units across 5 phases |

## Relationship to Validium MVP

The zkEVM L2 evolves from the validium MVP (`validium/`). Key upgrades:

- **TypeScript node** --> **Go node** (Geth heritage, goroutine concurrency)
- **Circom Groth16** --> **Rust PLONK** (universal setup, no per-circuit ceremony)
- **Application-specific execution** --> **Full EVM execution** (arbitrary smart contracts per enterprise)
- **Single DAC** --> **Per-enterprise DAC** with erasure coding
- **No bridge** --> **Full bridge** with forced inclusion and escape hatch
