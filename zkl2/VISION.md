# Basis Network zkEVM L2: Long-Term Vision

## Executive Summary

Basis Network evolves from a ZK Validium (MVP) into a **full zkEVM Layer 2** where each enterprise operates their own chain with complete EVM compatibility, generates ZK validity proofs, and settles on the Basis Network L1 (Avalanche). This is the enterprise blockchain infrastructure for Latin America.

## From MVP to zkEVM L2

### MVP (Enterprise ZK Validium Node)
- Application-specific enterprise node (TypeScript)
- Fixed transaction types (maintenance, sales, inventory)
- Groth16 proofs via Circom
- Data stays off-chain (validium mode)
- Single enterprise per node

### Long-term (Enterprise zkEVM L2)
- Full EVM execution environment per enterprise (Go node)
- Arbitrary Solidity smart contracts on the L2
- Advanced proof system (PLONK/STARK via Rust prover)
- Data availability via enterprise-managed DAC
- Cross-enterprise communication via hub-and-spoke
- Shared security anchored to Basis Network L1 on Avalanche

## Architecture

### System Layers

```
+------------------------------------------------------------------+
|                    ENTERPRISE L2 CHAINS                            |
|                                                                    |
|  +------------------+  +------------------+  +------------------+ |
|  | Enterprise A     |  | Enterprise B     |  | Enterprise C     | |
|  | (Sequencer)      |  | (Sequencer)      |  | (Sequencer)      | |
|  | (EVM Executor)   |  | (EVM Executor)   |  | (EVM Executor)   | |
|  | (Local State DB) |  | (Local State DB) |  | (Local State DB) | |
|  +--------|---------+  +--------|---------+  +--------|---------+ |
|           |                     |                     |            |
+-----------v---------------------v---------------------v------------+
            |                     |                     |
            |    ZK Proofs + State Roots               |
            v                     v                     v
+------------------------------------------------------------------+
|               BASIS NETWORK L1 (Avalanche Subnet-EVM)             |
|                                                                    |
|  +------------------+  +------------------+  +-----------------+  |
|  | BasisRollup.sol  |  | BasisBridge.sol  |  | BasisDAC.sol    |  |
|  | - State roots    |  | - Deposits       |  | - DA committee  |  |
|  | - Proof verify   |  | - Withdrawals    |  | - Attestations  |  |
|  | - Batch history  |  | - Asset transfer |  | - Challenges    |  |
|  +------------------+  +------------------+  +-----------------+  |
|                                                                    |
|  +------------------+  +------------------+                       |
|  | EnterpriseReg    |  | ZKVerifier.sol   |                       |
|  | .sol (existing)  |  | (upgraded)       |                       |
|  +------------------+  +------------------+                       |
+------------------------------------------------------------------+
            |
            | Avalanche Consensus (Snowman)
            v
+------------------------------------------------------------------+
|            AVALANCHE PRIMARY NETWORK (P-Chain, C-Chain)            |
+------------------------------------------------------------------+
```

### Core Components

#### 1. L2 Node (Go)

The enterprise L2 node is a complete blockchain node written in Go. Each enterprise runs their own instance.

**Modules:**

| Module | Responsibility |
|--------|---------------|
| `cmd/basis-l2` | Node binary entry point, CLI, configuration |
| `sequencer/` | Transaction ordering, block production, mempool management |
| `executor/` | EVM execution engine (forked from go-ethereum) |
| `statedb/` | State database (accounts, storage, nonces) with Merkle tree |
| `synchronizer/` | L1 state reading, deposit detection, forced inclusion |
| `batchbuilder/` | Aggregates executed transactions into provable batches |
| `rpc/` | JSON-RPC API (eth_*, basis_* namespaces) |
| `p2p/` | Peer-to-peer networking for enterprise node clusters |
| `da/` | Data availability interface (enterprise storage, DAC) |

**Why Go:**
- go-ethereum (Geth) is the reference EVM implementation, written in Go. Forking it gives us battle-tested EVM execution.
- Goroutine concurrency model is ideal for blockchain node operations (block processing, RPC handling, P2P).
- Polygon CDK, Scroll, and OP Stack all use Go for their node software.
- Strong blockchain ecosystem: libp2p, go-ethereum, Cosmos SDK all in Go.

#### 2. ZK Prover (Rust)

The prover generates ZK proofs that the L2 state transition is valid. Written in Rust for maximum performance.

**Modules:**

| Module | Responsibility |
|--------|---------------|
| `witness/` | Witness generation from L2 execution traces |
| `circuit/` | Arithmetic circuit definition (R1CS or custom) |
| `prover/` | Proof generation engine (Groth16, PLONK, or STARK) |
| `aggregator/` | Proof aggregation (multiple batches into one proof) |
| `gpu/` | GPU acceleration for field arithmetic (optional) |

**Why Rust:**
- Proof generation is the most computationally intensive operation. Rust's zero-cost abstractions and memory safety without garbage collection make it ideal.
- zkSync Era's prover is 87.7% Rust. Polygon zkEVM's prover is C++ (we prefer Rust for memory safety).
- RISC Zero and SP1 (leading zkVM frameworks) are both Rust-native.
- Cryptographic libraries (arkworks, bellman, halo2) are Rust-first.

**Proof System Decision:**

| System | Trusted Setup | Proof Size | Verify Cost | Prove Time | Recommendation |
|--------|--------------|------------|-------------|------------|----------------|
| Groth16 | Per-circuit | ~192 bytes | ~200K gas | Fast | MVP (current) |
| PLONK | Universal (1-time) | ~512 bytes | ~300K gas | Medium | Mid-term target |
| STARK | None | ~50KB | ~500K gas | Slow | Research only |
| Halo2 | None | ~5KB | ~400K gas | Medium | Long-term target |

**Recommendation**: Migrate from Groth16 (MVP) to **PLONK** (mid-term) for universal setup, then evaluate **Halo2** (long-term) for setup-free proofs. The prover architecture must be proof-system-agnostic to support this migration.

#### 3. L1 Settlement Contracts (Solidity)

Smart contracts on the Basis Network L1 that manage L2 state.

**Contracts:**

| Contract | Responsibility |
|----------|---------------|
| `BasisRollup.sol` | State root management, proof verification, batch finalization |
| `BasisBridge.sol` | L1<->L2 asset transfers, deposit/withdrawal queue, escape hatch |
| `BasisDAC.sol` | Data availability committee management, attestation verification |
| `BasisGovernance.sol` | Protocol parameter updates, emergency actions |

**BasisRollup.sol Core Interface:**

```solidity
interface IBasisRollup {
    /// @notice Submit a new batch with ZK proof
    /// @param enterpriseId The enterprise submitting the batch
    /// @param previousStateRoot The state root before the batch
    /// @param newStateRoot The state root after the batch
    /// @param batchSize Number of transactions in the batch
    /// @param proof The ZK proof (Groth16 or PLONK)
    function submitBatch(
        uint256 enterpriseId,
        bytes32 previousStateRoot,
        bytes32 newStateRoot,
        uint256 batchSize,
        bytes calldata proof
    ) external;

    /// @notice Force inclusion of an L1 transaction into the L2 (escape hatch)
    function forceInclusion(uint256 enterpriseId, bytes calldata txData) external;

    /// @notice Get the current state root for an enterprise
    function getStateRoot(uint256 enterpriseId) external view returns (bytes32);
}
```

#### 4. Bridge (Cross-Layer Communication)

| Component | Direction | Mechanism |
|-----------|-----------|-----------|
| Deposits | L1 -> L2 | User deposits to BasisBridge.sol. L2 synchronizer detects event. L2 credits user. |
| Withdrawals | L2 -> L1 | User initiates on L2. Batch with withdrawal is proved. User claims on L1. |
| Forced Inclusion | L1 -> L2 | If sequencer censors, user posts tx directly to L1. Sequencer MUST include. |
| Escape Hatch | L2 -> L1 | If L2 is offline, user provides Merkle proof of balance to withdraw from L1. |

## Technical Decisions

### TD-001: Go for the L2 Node

**Decision**: The L2 node software is written in Go.

**Alternatives Considered**:
- Rust (zkSync Era model): Higher performance but harder to fork Geth, smaller blockchain ecosystem in Rust for node software.
- TypeScript (MVP approach): Insufficient performance for production EVM execution, no mature EVM implementation.

**Justification**:
- go-ethereum is the most battle-tested EVM implementation (10+ years, billions of dollars secured).
- Forking Geth's EVM executor eliminates the need to implement EVM from scratch (1,000+ opcodes, gas metering, precompiles).
- Polygon CDK, Scroll, and OP Stack all validate this choice for production L2 nodes.
- Go's goroutine model naturally maps to concurrent blockchain operations.

### TD-002: Rust for the ZK Prover

**Decision**: The ZK prover is written in Rust.

**Alternatives Considered**:
- C++ (Polygon zkEVM prover model): Maximum performance but memory-unsafe, harder to maintain.
- Go (same as node): GC pauses unacceptable for proof generation, missing cryptographic libraries.

**Justification**:
- Proof generation is CPU-bound and memory-intensive. Rust's ownership model prevents memory leaks and data races without GC overhead.
- arkworks, bellman, and halo2 (leading ZK libraries) are Rust-native.
- RISC Zero and SP1 zkVM frameworks are Rust-first, enabling future zkVM migration.
- Safety guarantees are critical for cryptographic code where bugs can compromise proof soundness.

### TD-003: PLONK as Mid-Term Proof System

**Decision**: Migrate from Groth16 (MVP) to PLONK for the zkEVM version.

**Justification**:
- Groth16 requires a per-circuit trusted setup. Any circuit change requires a new ceremony. This is impractical for a zkEVM where circuits are complex and evolving.
- PLONK uses a universal Structured Reference String (SRS) -- one setup ceremony supports all circuits.
- PLONK supports custom gates and lookup tables, enabling efficient EVM opcode proving.
- PLONK verification cost (~300K gas) is acceptable on the zero-fee Basis Network L1.

### TD-004: Validium Mode (Off-Chain Data Availability)

**Decision**: Enterprise data is stored off-chain. Only proofs and state roots are posted to the L1.

**Alternatives Considered**:
- Rollup mode (data on L1): Maximum security but exposes enterprise data publicly. Unacceptable.
- Volition (hybrid): Complex, adds latency, unnecessary for permissioned enterprise use.

**Justification**:
- Enterprises will not accept public data exposure under any circumstances.
- The enterprise itself is the natural data availability provider -- they already store their operational data.
- A Data Availability Committee (DAC) composed of Base Computing + enterprise + auditor provides redundancy.
- Cost is lower (no calldata posting to L1), which aligns with the zero-fee model.

### TD-005: Per-Enterprise Chains (Not Shared L2)

**Decision**: Each enterprise operates their own L2 chain, not a shared chain.

**Alternatives Considered**:
- Shared L2 with privacy via ZK: Simpler infrastructure but weaker isolation.
- Shared sequencer with partitioned state: Compromise, but shared sequencer is a single point of failure.

**Justification**:
- Maximum data isolation: enterprise A cannot access enterprise B's state even at the node level.
- Regulatory compliance: each enterprise controls their own data residency and access policies.
- Operational independence: one enterprise's downtime does not affect others.
- Aligns with Avalanche's subnet philosophy of horizontal scaling via sovereign chains.

### TD-006: Hub-and-Spoke for Cross-Enterprise Communication

**Decision**: Cross-enterprise verification uses a hub-and-spoke model with the L1 as the hub.

**Mechanism**: Enterprise A proves a statement about its state. Enterprise B can verify this proof on the L1 without accessing A's data. Both enterprises submit proofs to the L1, and the L1 can verify cross-references without either enterprise revealing private data.

**Justification**:
- No direct L2-to-L2 communication needed (eliminates complex routing).
- The L1 already has proof verification infrastructure.
- Matches the Rayls architecture (validated by J.P. Morgan's Project EPIC).

## Development Roadmap

### Phase 1: Foundation (Months 1-2)
- Fork go-ethereum EVM executor
- Basic L2 node: sequencer + executor + state database
- L1 contracts: BasisRollup.sol, basic proof verification

### Phase 2: ZK Integration (Months 2-4)
- Rust prover with Groth16 (reusing MVP circuits as starting point)
- Witness generation from EVM execution traces
- End-to-end: L2 transaction -> EVM execution -> ZK proof -> L1 verification

### Phase 3: Bridge and DA (Months 4-5)
- BasisBridge.sol: deposits and withdrawals
- L2 synchronizer: detect L1 deposits
- DAC implementation: enterprise-managed data availability
- Escape hatch: forced withdrawal via Merkle proof

### Phase 4: Production Hardening (Months 5-6)
- PLONK migration (universal setup)
- Proof aggregation (multiple batches -> single proof)
- P2P networking for enterprise node clusters
- Monitoring, alerting, operational tooling

### Phase 5: Cross-Enterprise (Months 6+)
- Hub-and-spoke cross-enterprise proofs
- Inter-enterprise asset transfers
- Selective disclosure for auditors
- Recursive proof composition

## File Structure

```
zkl2/
|-- VISION.md                    # This document
|-- ROADMAP.md                   # Research units and execution plan
|-- ROADMAP_CHECKLIST.md         # Sequential agent execution checklist
|-- docs/
|   |-- ARCHITECTURE.md          # Detailed technical architecture
|   `-- TECHNICAL_DECISIONS.md   # Full ADR catalog
|-- research/                    # R&D pipeline output (Scientist)
|   |-- experiments/             # Self-contained experiment directories
|   `-- foundations/             # Living specs (invariants, threat models)
|-- specs/                       # R&D pipeline output (Logicist)
|   |-- units/                   # TLA+ formal specification units
|   `-- docs/                    # ADRs and glossary for specifications
|-- tests/                       # Security testing
|   `-- adversarial/             # Adversarial test reports (Architect)
|-- proofs/                      # R&D pipeline output (Prover)
|   |-- units/                   # Coq verification units
|   `-- docs/                    # ADRs and glossary for proofs
|-- node/                        # L2 Node (Go)
|   |-- cmd/
|   |   `-- basis-l2/            # Node binary
|   |-- sequencer/               # Block production
|   |-- executor/                # EVM execution (Geth fork)
|   |-- statedb/                 # State management
|   |-- synchronizer/            # L1 state reading
|   |-- batchbuilder/            # Batch aggregation
|   |-- rpc/                     # JSON-RPC server
|   |-- p2p/                     # Networking
|   |-- da/                      # Data availability
|   |-- go.mod
|   `-- go.sum
|-- prover/                      # ZK Prover (Rust)
|   |-- src/
|   |   |-- witness/             # Witness generation
|   |   |-- circuit/             # Circuit definitions
|   |   |-- prover/              # Proof engine
|   |   `-- aggregator/          # Proof aggregation
|   |-- Cargo.toml
|   `-- Cargo.lock
|-- contracts/                   # L1 Contracts (Solidity)
|   |-- BasisRollup.sol          # State + proof management
|   |-- BasisBridge.sol          # Cross-layer bridge
|   |-- BasisDAC.sol             # DA committee
|   `-- BasisGovernance.sol      # Protocol governance
`-- bridge/                      # Bridge infrastructure
    |-- relayer/                 # L1<->L2 message relay
    `-- sdk/                     # Bridge SDK for enterprises
```

## Competitive Advantage

1. **First mover in LATAM enterprise ZK infrastructure**: No competitor targets this market with this architecture.
2. **Existing client base**: PLASMA and Trace provide immediate users, not hypothetical demand.
3. **Zero-fee model**: Enterprises pay subscription, not per-transaction gas. Eliminates the biggest adoption barrier.
4. **Avalanche foundation**: Sub-second finality on L1 means faster batch confirmation than any Ethereum-based L2.
5. **AI-driven R&D pipeline**: 4-agent system (Scientist -> Logicist -> Architect -> Prover) accelerates development beyond what traditional teams achieve.
6. **Regulatory alignment**: Per-enterprise chains with enterprise-controlled DA satisfy data sovereignty requirements across LATAM jurisdictions.
