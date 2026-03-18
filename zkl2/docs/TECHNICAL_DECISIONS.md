# zkEVM L2 Technical Decisions

## TD-001: Go for L2 Node Software

**Context**: The L2 node must execute EVM transactions, manage state, and interface with the L1.

**Decision**: Go

**Alternatives**: Rust (zkSync Era), TypeScript (insufficient performance), C++ (memory unsafe)

**Rationale**:
- go-ethereum (Geth) is the reference EVM implementation. Forking it provides 10+ years of battle-tested EVM execution logic, including all 1,000+ opcodes, gas metering, and precompiles.
- Polygon CDK (Go, 94.2%), Scroll (Go, 87.5%), and OP Stack (Go) validate this choice for production L2 nodes.
- Go's goroutine concurrency model naturally maps to concurrent blockchain operations: RPC serving, block execution, P2P networking, L1 synchronization.
- Go's garbage collector is acceptable for node operations (not proof generation).

**Consequences**: Proof generation must be delegated to the Rust prover via IPC/gRPC, not embedded in the Go process.

---

## TD-002: Rust for ZK Prover

**Context**: Proof generation is the most computationally intensive operation.

**Decision**: Rust

**Alternatives**: C++ (Polygon zkEVM, memory unsafe), Go (GC pauses, missing crypto libs)

**Rationale**:
- Memory safety without garbage collection eliminates GC pauses during proof generation (which can take minutes of sustained computation).
- arkworks, bellman, and halo2 (leading ZK cryptography libraries) are Rust-native.
- RISC Zero and SP1 (leading zkVM frameworks) are Rust-first, enabling future zkVM migration.
- Zero-cost abstractions allow high-level code with C-level performance.

**Consequences**: Node-prover communication via gRPC. Prover runs as a separate process.

---

## TD-003: PLONK as Target Proof System

**Context**: Groth16 (current MVP) requires per-circuit trusted setup.

**Decision**: PLONK for mid-term, evaluate Halo2 for long-term.

**Alternatives**: Continue Groth16 (per-circuit setup), STARK (large proofs, high verify cost)

**Rationale**:
- PLONK uses a universal Structured Reference String (SRS) -- one ceremony for all circuits.
- Custom gates and lookup tables enable efficient EVM opcode proving.
- ~300K gas verification cost is acceptable on zero-fee Basis Network L1.
- Clear upgrade path to Halo2 (no trusted setup, polynomial commitment-based).

**Consequences**: Prover architecture must be proof-system-agnostic (trait-based in Rust).

---

## TD-004: Validium Mode (Off-Chain DA)

**Context**: Enterprise data cannot be posted on-chain.

**Decision**: Validium mode with enterprise-managed Data Availability Committee (DAC).

**Alternatives**: Rollup (data on-chain, privacy violated), Volition (hybrid, complex)

**Rationale**:
- Enterprises will not accept public data exposure. Period.
- The enterprise itself stores operational data in their existing systems.
- DAC composition: Base Computing + enterprise + independent auditor.
- Zero-fee L1 eliminates the cost argument for rollup mode.

**Consequences**: Escape hatch mechanism required for withdrawal if DAC fails. Users must be able to prove their balance via Merkle proof.

---

## TD-005: Per-Enterprise Chains

**Context**: Multiple enterprises need isolation.

**Decision**: Each enterprise operates their own L2 chain.

**Alternatives**: Shared L2 with ZK privacy, shared sequencer with partitioned state

**Rationale**:
- Maximum data isolation at the infrastructure level.
- Each enterprise controls their own data residency and access policies.
- Operational independence: one enterprise's downtime does not affect others.
- Aligns with Avalanche's horizontal scaling philosophy.

**Consequences**: Cross-enterprise communication requires hub-and-spoke model via L1.

---

## TD-006: Hub-and-Spoke Cross-Enterprise Model

**Context**: Enterprises need to verify inter-company transactions without exposing data.

**Decision**: L1 serves as the hub for cross-enterprise proof verification.

**Rationale**:
- No direct L2-to-L2 communication needed.
- L1 already has proof verification infrastructure.
- Validated by Rayls (J.P. Morgan's Project EPIC).

**Consequences**: Cross-enterprise proofs are more expensive (two L1 transactions) but simpler and more secure.

---

## TD-007: Geth Fork for EVM Execution

**Context**: The L2 needs EVM compatibility.

**Decision**: Fork go-ethereum's EVM executor.

**Alternatives**: Build from scratch (years of work), use evmone (C++, integration complexity)

**Rationale**:
- Geth's EVM has processed trillions of dollars in transactions.
- Complete opcode coverage including latest Cancun updates.
- Precompile support including BN254 pairing (needed for ZK verification).
- Established testing suite (Ethereum state tests).

**Consequences**: Must track Geth upstream for security patches. Must modify state management to use ZK-friendly Merkle tree.

---

## TD-008: Poseidon Hash for State Tree

**Context**: The L2 state tree must be provable in ZK circuits.

**Decision**: Poseidon hash function.

**Alternatives**: Keccak (EVM native but ZK-expensive), MiMC (fewer constraints but less studied), Pedersen (curve-dependent)

**Rationale**:
- ~300 R1CS constraints per hash vs ~150,000 for Keccak. This is a 500x reduction in circuit size.
- Widely used in production ZK systems (Polygon zkEVM, Zcash Sapling, Filecoin).
- Algebraically defined over the BN254 scalar field (native to Groth16/PLONK on EVM).
- Security: 128-bit security margin against algebraic attacks (Grassi et al., 2021).

**Consequences**: State proofs are not directly compatible with Ethereum's Keccak-based proofs. A compatibility layer may be needed for cross-chain verification.

---

## TD-009: Solidity 0.8.24 with Cancun EVM for L1 Contracts

**Context**: L1 contracts must run on Avalanche Subnet-EVM.

**Decision**: Solidity 0.8.24, evmVersion: cancun.

**Rationale**:
- Avalanche Subnet-EVM does NOT support Pectra (Solidity >= 0.8.30 defaults to Pectra).
- 0.8.24 is the latest version that reliably targets Cancun.
- Existing contract infrastructure (EnterpriseRegistry, ZKVerifier) already uses this version.
- BN254 precompiles (ecAdd, ecMul, ecPairing) at addresses 0x06, 0x07, 0x08 are available and confirmed working.

**Consequences**: Cannot use Solidity features introduced after 0.8.24 until Avalanche supports newer EVM versions.
