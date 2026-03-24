# Enterprise zkEVM L2

The long-term evolution of Basis Network -- a full zero-knowledge EVM-compatible Layer 2 where each enterprise operates their own chain with dedicated sequencer, EVM executor, ZK prover, and data availability layer. Settles on the Basis Network L1 (Avalanche).

**Status:** Full E2E pipeline **verified on Basis Network L1 (Fuji)** on 2026-03-23. R&D pipeline complete (44/44 agents, 11 research units). Node binary operational with real EVM execution, PLONK-KZG proofs verified on-chain (291K gas, 5.8s), LevelDB state persistence, L1 synchronizer, and ProtoGalaxy aggregation. See [POST_ROADMAP_TODO.md](./docs/POST_ROADMAP_TODO.md) for detailed status.

## Quick Start

```bash
# Build the node binary
cd node && go build -o basis-l2 ./cmd/basis-l2/

# Run the node
./basis-l2 --version
./basis-l2 --log-level info

# Run all tests
cd node && go test ./... -count=1       # Go (7 packages, ~180 tests)
cd prover && cargo test                 # Rust (142 tests)
cd contracts && npx hardhat test        # Solidity (322 tests)
```

See [node/STARTUP.md](./node/STARTUP.md) for the full startup guide.

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

| Directory | Technology | Description | Tests | Status |
|-----------|-----------|-------------|-------|--------|
| [node/](./node/) | Go 1.24 | L2 node (binary, sequencer, executor, state DB, pipeline, DAC, cross-enterprise) | 246 Go | E2E verified on L1 |
| [prover/](./prover/) | Rust 1.83 | ZK prover (witness generation, PLONK circuit, aggregation) | 142 Rust | Real KZG proofs |
| [contracts/](./contracts/) | Solidity 0.8.24 | L1 settlement contracts (6+1 contracts) | 322 TS | Deployed on Fuji |
| [bridge/](./bridge/) | Go 1.24 | Cross-layer message relay with Merkle proofs | 33 Go | L1 client wired |
| [specs/](./specs/) | TLA+ | 11 formal specifications (all TLC-verified) | -- | Complete |
| [proofs/](./proofs/) | Coq | 107 formal verification files (0 Admitted) | -- | Complete |
| [tests/](./tests/) | -- | 11 adversarial reports (0 violations) | -- | Complete |
| [docs/](./docs/) | -- | Architecture, decisions, roadmap, integration plan | -- | Complete |

## L1 Settlement Contracts

| Contract | Purpose | Tests |
|----------|---------|-------|
| BasisRollup.sol | State root management + ZK proof verification | 88 |
| BasisBridge.sol | Deposit/withdrawal bridge with escape hatch | 40 |
| BasisDAC.sol | Data availability committee management | 68 |
| BasisHub.sol | Cross-enterprise hub-and-spoke settlement | 51 |
| BasisAggregator.sol | Proof aggregation for multi-enterprise batches | 27 |
| BasisVerifier.sol | PLONK/Groth16 verification + migration state machine | 48 |

## Test Summary

| Component | Tests | Status |
|-----------|-------|--------|
| Go node (7 packages) | 246 | All passing |
| Go bridge | 33 | All passing |
| Rust prover (3 crates) | 142 | All passing |
| Solidity contracts (6) | 322 | All passing |
| TLA+ specifications | 11 | All TLC-verified |
| Coq proofs | 107 files | All compiled (0 Admitted) |
| Adversarial reports | 11 | 0 violations |
| **Total** | **~677+** | |

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| L2 Node Language | Go | Geth heritage, goroutine concurrency, blockchain maturity |
| ZK Prover Language | Rust | Memory safety, zero-cost abstractions, native ZK libraries |
| Proof System | PLONK (target) | Universal setup, custom gates, 300K gas verification |
| Data Availability | Validium mode | Enterprise-managed, only proofs on L1 |
| State Tree | Poseidon SMT | 500x constraint reduction vs Keccak |
| Architecture | Per-enterprise chains | Maximum data sovereignty |

## Getting Started

```bash
# 1. Build Go node + Rust prover
cd node && go build -o basis-l2 ./cmd/basis-l2/
cd ../prover && cargo build --release

# 2. Configure
cd ../node && cp .env.example .env
# Edit .env: set L1_PRIVATE_KEY, contract addresses, PROVER_BINARY_PATH

# 3. Run with persistent state
./basis-l2 --log-level info --data-dir ./data

# 4. Verify
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

See [Startup Guide](./node/STARTUP.md) for full instructions and [Deployment Guide](./docs/DEPLOYMENT.md) for production deployment.

## Deployed Contracts (Fuji Testnet)

All contracts deployed on Basis Network L1 (Chain ID 43199):

| Contract | Address | Status |
|----------|---------|--------|
| EnterpriseRegistry | 0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5 | Active (L1) |
| Halo2VerifyingKey | 0x5a04689914cf2288e80d6829eb2Ee303E5361BB5 | Active |
| Halo2Verifier | 0x49a2Ad282b541BC20DFF616551F2104141D91936 | Active |
| Halo2PlonkVerifier | 0x1EdeB00f1420a6589Feb72d1CB1134D1d1A02FB8 | Active |
| BasisRollupV2 | 0xc028f04f477A53d64C181e3d9CC79A1e1b4Bd562 | Active |
| BasisBridge | 0xd0B4BeB95De33d6F49Bcc08fE5ce3b923e263a5b | Active |
| BasisDAC | 0x1E0c7C220c75E530E22BC066F8B5a98DeB6dfe9B | Active |
| BasisAggregator | 0xddfe844E347470F45D53bA6FFBA95034F45670a2 | Active |
| BasisHub | 0x6Faf689a6Dcb67a633b437774388F0358D882f0B | Active |
| BasisRollupHarness | 0x79279EDe17c8026412cD093876e8871352f18546 | Deprecated |

## Documentation

| Document | Description |
|----------|-------------|
| [Vision](./docs/VISION.md) | Long-term zkEVM L2 strategy |
| [Architecture](./docs/ARCHITECTURE.md) | 4-layer system design |
| [Technical Decisions](./docs/TECHNICAL_DECISIONS.md) | 9 justified ADRs |
| [Roadmap](./docs/ROADMAP.md) | 11 research units across 5 phases |
| [Startup Guide](./node/STARTUP.md) | How to build, configure, and run the node |
| [API Reference](./docs/API.md) | JSON-RPC endpoint documentation |
| [Deployment Guide](./docs/DEPLOYMENT.md) | Step-by-step deployment procedure |
| [Status Tracker](./docs/POST_ROADMAP_TODO.md) | Detailed completion status |

## Relationship to Validium MVP

The zkEVM L2 evolves from the validium MVP (`validium/`). Key upgrades:

- **TypeScript node** --> **Go node** (Geth heritage, goroutine concurrency)
- **Circom Groth16** --> **Rust PLONK** (universal setup, no per-circuit ceremony)
- **Application-specific execution** --> **Full EVM execution** (arbitrary smart contracts per enterprise)
- **Single DAC** --> **Per-enterprise DAC** with erasure coding
- **No bridge** --> **Full bridge** with forced inclusion and escape hatch
