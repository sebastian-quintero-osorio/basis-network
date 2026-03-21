# Technical Decisions

This document records the key technical decisions made for Basis Network and the reasoning behind each.

---

## TD-001: Avalanche L1 (Subnet-EVM) as the Base Layer

**Decision:** Deploy Basis Network as an Avalanche L1 using a modified Subnet-EVM.

**Alternatives considered:**
- Ethereum L2 (Optimism, Arbitrum): high gas costs on L1 for proof submission, no sovereign control.
- Hyperledger Fabric: no interoperability with public DeFi, isolated silo.
- Cosmos SDK appchain: smaller ecosystem, weaker enterprise tooling.
- Standalone chain: no interoperability, must build everything from scratch.

**Rationale:**
- Full sovereignty over gas model, validator set, and access control.
- EVM compatibility means any Solidity developer can build on the network.
- Native interoperability with Avalanche C-Chain via AWM (DeFi, stablecoins).
- Sub-second finality via Snowman consensus.
- Post-Avalanche9000, L1 validator costs dropped from ~$40K to ~$20-200 USD.
- Largest ecosystem support for enterprise L1s (Evergreen, Spruce, etc.).

---

## TD-002: Near-Zero-Fee Gas Model

**Decision:** Configure `minBaseFee: 1` (1 wei) with `minBlockGasCost: 0` and `maxBlockGasCost: 1000000`.

**Alternatives considered:**
- True zero fee (`minBaseFee: 0`): Subnet-EVM v0.8.0 rejects `baseFee == 0` during `BuildBlock`, causing the chain to stall. This was discovered during production deployment and required recreating the L1.
- Sponsored transactions (ERC-4337): adds complexity, requires paymaster infrastructure.

**Rationale:**
- Enterprise clients expect predictable costs. A 1-wei base fee is effectively free (~$0.000000000000000001 per transaction) while avoiding the Subnet-EVM edge case.
- Revenue comes from SaaS subscriptions, not gas. The blockchain is infrastructure.
- The 1-wei minimum prevents the dynamic baseFee from decaying to 0, which the fee calculation logic cannot handle.
- Allowlist controls prevent spam (only authorized addresses can transact), mitigating the abuse vector that near-zero-fee normally introduces.

**Lesson learned:** Never set `minBaseFee` to 0 on Subnet-EVM. The chain will produce blocks initially but stall once the dynamic fee algorithm attempts to compute with a zero base fee.

---

## TD-003: Permissioned Access via Allowlists

**Decision:** Use Subnet-EVM precompiled contracts for transaction and deployer allowlists.

**Rationale:**
- Enforced at the VM level, not just the contract level. Cannot be bypassed.
- Multi-tier permission system (Admin, Manager, Enabled, None) provides granular control.
- Aligns with enterprise compliance requirements (KYC/KYB).
- Native to Subnet-EVM; no custom code required.

---

## TD-004: Solidity 0.8.24 with EVM Target Cancun

**Decision:** Use Solidity 0.8.24 and explicitly set `evmVersion: "cancun"` in Hardhat.

**Rationale:**
- Avalanche Subnet-EVM currently supports up to the Cancun hard fork.
- Solidity versions >= 0.8.30 default to Pectra, which Avalanche does NOT support.
- Setting `evmVersion: "cancun"` explicitly prevents compilation issues and opcode incompatibilities.
- 0.8.24 is stable, well-tested, and includes all features we need.

---

## TD-005: Circom + SnarkJS for ZK Proof of Concept

**Decision:** Use Circom for circuit definition and SnarkJS for proof generation and verification.

**Alternatives considered:**
- SP1 (Succinct zkVM): more powerful but requires Rust toolchain; heavier setup.
- Halo2: no trusted setup needed, but steeper learning curve and less EVM tooling.
- RISC Zero: similar to SP1; Rust-native, overkill for a PoC.
- Noir (Aztec): promising but less mature ecosystem.

**Rationale:**
- **Gas efficiency:** Groth16 proofs cost ~200K gas to verify on-chain. This is the most efficient option, critical even with zero-fee since block gas limits still apply.
- **Maturity:** Circom is the most battle-tested circuit language. Used in production by Polygon zkEVM, Iden3, Semaphore, and others.
- **JavaScript pipeline:** SnarkJS provides compile, setup, prove, verify, and Solidity verifier export entirely in JavaScript/Node.js. Matches our backend stack.
- **EVM-native verifier:** `snarkjs zkey export solidityverifier` generates a Solidity contract that deploys directly to Subnet-EVM with no modifications.
- **Ecosystem:** extensive documentation, tutorials, and community support.
- **Migration path:** the verifier contract interface is standard. Swapping the proving backend (to SP1, Halo2, etc.) later only requires changing the off-chain prover while keeping the same on-chain verifier interface.

---

## TD-006: Dual-Write Integration Pattern

**Decision:** Integrate PLASMA and Trace via a dual-write pattern rather than replacing their databases.

**Rationale:**
- Zero disruption to existing production systems (PLASMA is live at Ingenio Sancarlos).
- The blockchain is an additive audit trail, not a replacement for operational databases.
- If the blockchain is temporarily unavailable, applications continue functioning normally.
- Queue-based architecture with retry logic ensures eventual consistency.

---

## TD-007: Next.js + Tailwind CSS for Dashboard

**Decision:** Build the network dashboard with Next.js and Tailwind CSS.

**Alternatives considered:**
- React (CRA): no SSR, slower initial load, worse SEO.
- Vue/Nuxt: smaller ecosystem for Web3 tooling.
- Svelte/SvelteKit: less mature ecosystem.

**Rationale:**
- Server-side rendering for fast initial load (important for demo impressions).
- Optimized for Vercel deployment (our hosting target).
- Tailwind CSS provides rapid UI development with consistent design.
- Largest ecosystem of Web3-compatible libraries and examples.
- Scales well from MVP dashboard to full-featured network explorer.

---

## TD-008: Business Source License 1.1

**Decision:** License the codebase under BSL 1.1 with a 4-year change date to Apache 2.0.

**Rationale:**
- Basis Network is proprietary enterprise infrastructure and the core IP of Base Computing S.A.S.
- BSL allows source availability (judges can review all code) while preventing unauthorized commercial use.
- Used by established companies: CockroachDB, Sentry, MariaDB, HashiCorp.
- The 4-year sunset to Apache 2.0 demonstrates long-term commitment to the ecosystem.
- Balances investor expectations (protected IP) with ecosystem participation (visible source).

---

## TD-009: L1 as Generic Settlement Layer (Remove Application Connectors)

**Decision:** Remove `PLASMAConnector.sol` and `TraceConnector.sol` from the L1. Make `TraceabilityRegistry` fully application-agnostic by removing hardcoded event type constants.

**Previous state:**
- 2 connector contracts (`PLASMAConnector`, `TraceConnector`) on the L1, each with application-specific structs, mappings, and logic.
- 6 hardcoded event type constants in `TraceabilityRegistry` (`MAINTENANCE_ORDER`, `SUPPLY_CHAIN_CHECKPOINT`, etc.).

**Alternatives considered:**
- Keep connectors as optional middleware: adds complexity, connectors still couple L1 to specific apps.
- Move connectors to a separate "middleware" layer: over-engineered for the current scale.

**Rationale:**
- **Separation of concerns:** The L1 is a settlement/verification layer. Application logic belongs at the adapter/L2 level.
- **Scalability:** Adding a new SaaS product no longer requires deploying a new contract on the L1. Adapters define their own event types as `keccak256` of strings.
- **Consistency with validium model:** Enterprise validium nodes will call `TraceabilityRegistry.recordEvent()` directly; connectors were redundant.
- **Reduced L1 surface area:** Fewer contracts to audit, deploy, and maintain.

**Migration:**
- Adapters now call `TraceabilityRegistry.recordEvent()` directly with application-defined event types.
- Event type strings (e.g., `"ORDER_CREATED"`, `"SALE_CREATED"`) are defined at the adapter level, not the contract level.
- The on-chain event data is identical; only the indirection through connector contracts is removed.
