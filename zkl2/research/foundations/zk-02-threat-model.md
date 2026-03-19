# zkL2 Threat Model

> Living document. Updated after each completed experiment.
> Accumulates threat knowledge from experiments and literature.

## System Boundaries

```
+-------------------+     +------------------+     +------------------+
| Enterprise User   | --> | L2 Sequencer     | --> | L1 Basis Network |
| (Solidity DApp)   |     | (Go node)        |     | (Avalanche)      |
+-------------------+     +------------------+     +------------------+
                               |                         |
                          +----v-----+              +----v-----+
                          | ZK Prover|              | Verifier |
                          | (Rust)   |              | Contract |
                          +----------+              +----------+
```

## Trust Assumptions

| Component | Trust Level | Assumption |
|-----------|------------|------------|
| Avalanche L1 | Trustless | Snowman consensus, decentralized validators |
| ZK Proof | Trustless | Cryptographic soundness (Groth16/PLONK) |
| Sequencer | Trusted (enterprise-operated) | Honest sequencing; mitigated by forced inclusion |
| Prover | Trustless | Cannot produce false proofs (soundness) |
| DAC | Semi-trusted | k-of-n honest minority for data availability |
| EVM Executor | Trustless | Execution correctness proved by ZK proof |

## Threat Categories

### T-01: Malicious Sequencer

**Threat:** Enterprise sequencer censors transactions or reorders for MEV.
**Impact:** User transactions excluded or front-run.
**Mitigation:** Forced inclusion via L1 (24h max delay). Enterprise context makes MEV
unlikely but censorship possible.
**Status:** Addressed in architecture (RU-L2).

### T-02: Invalid State Transition

**Threat:** Sequencer submits batch with incorrect execution results.
**Impact:** Fraudulent state committed to L1.
**Mitigation:** ZK validity proof. L1 verifier rejects invalid proofs. This is the
primary security guarantee.
**Status:** Core of the system design.

### T-03: EVM Incompatibility

**Threat:** Geth fork diverges from Ethereum EVM specification.
**Impact:** Solidity contracts behave differently on L2 vs mainnet. Potential fund loss
or incorrect business logic.
**Mitigation:** (a) Use official Geth modules (10+ years of testing), (b) run Ethereum
state tests against the fork, (c) track upstream security patches.
**Source:** RU-L1 experiment findings.

### T-04: Trace Incompleteness

**Threat:** Execution trace misses state-modifying operations.
**Impact:** Witness generation produces incomplete witness. Proof either fails
(safety-preserving) or proves incorrect state transition (catastrophic).
**Mitigation:** (a) Use Geth's core/tracing hooks which are tested in production,
(b) verify trace completeness with differential testing against known-good execution,
(c) formal verification of trace-to-witness mapping (RU-L3, Prover).
**Source:** RU-L1 experiment.

### T-05: KECCAK256 Constraint Explosion

**Threat:** Contracts using KECCAK256 extensively (e.g., mappings, ERC20 balanceOf)
cause circuit size explosion.
**Impact:** Proof generation takes too long or exceeds circuit capacity.
**Mitigation:** (a) Preimage oracle with lookup tables for known Keccak values,
(b) limit Keccak invocations per batch, (c) replace with Poseidon where possible
(e.g., state trie).
**Estimated cost:** ~150K R1CS constraints per KECCAK256 invocation.
**Source:** RU-L1 literature review, Polygon zkevm-rom.

### T-06: State Trie Mismatch

**Threat:** Poseidon SMT state trie produces different state roots than Ethereum's MPT.
**Impact:** State roots not compatible with Ethereum tools expecting MPT proofs.
**Mitigation:** This is a known, accepted trade-off (TD-008). Basis L2 state proofs
use Poseidon SMT. A compatibility layer converts between formats if needed for
cross-chain verification.
**Source:** TD-008, RU-V1.

### T-07: Geth Dependency Supply Chain

**Threat:** Vulnerability in go-ethereum dependency or upstream change breaks L2.
**Impact:** Security vulnerability or consensus-breaking change.
**Mitigation:** (a) Pin specific Geth version, (b) monitor Geth security advisories,
(c) Strategy A (import as module) allows selective upgrades, (d) maintain test suite
that catches breaking changes.
**Source:** RU-L1 architecture analysis.

### T-08: Prover Soundness Break

**Threat:** Bug in ZK circuit allows false proofs.
**Impact:** Invalid state transitions accepted by L1 verifier.
**Mitigation:** (a) Formal verification of circuit (Prover agent), (b) multiple
independent prover implementations, (c) trusted setup ceremony for Groth16,
(d) migration to PLONK eliminates trusted setup risk.
**Source:** System-level.

### T-09: Data Availability Failure

**Threat:** DAC nodes go offline, transaction data lost.
**Impact:** Users cannot prove their balance for withdrawal via escape hatch.
**Mitigation:** (a) k-of-n redundancy, (b) AnyTrust fallback (post data on-chain),
(c) enterprise stores own data. Detailed in RU-V6 and RU-L8.
**Source:** RU-V6, TD-004.

### T-10: Bridge Double-Spend

**Threat:** Attacker withdraws same funds on L1 twice.
**Impact:** Value creation out of thin air, bridge insolvency.
**Mitigation:** (a) Withdrawal requires valid Merkle proof of L2 state, (b) proof
verified against committed state root on L1, (c) nullifier set prevents replay.
**Source:** RU-L7 (Bridge).

## ZK-Specific Opcodes: Threat Matrix

| Opcode | Threat | Severity | Mitigation |
|--------|--------|----------|------------|
| KECCAK256 | Constraint explosion | HIGH | Preimage oracle, batch limits |
| BLOCKHASH | Requires chain state not in proof | MEDIUM | Block hash oracle, lookup table |
| SELFDESTRUCT | Complex state changes | LOW | Restricted in Cancun (EIP-6780) |
| CREATE/CREATE2 | Recursive execution in proof | HIGH | Dedicated sub-circuit, depth limits |
| CALL/DELEGATECALL | Context switches, value transfer | HIGH | Stack-based proving |
| EXP | Variable-cost exponentiation | MEDIUM | Cost bounds, bit-length limits |
| Precompile 0x08 | ecPairing ~100K constraints | HIGH | Limit pairings per batch |

## Experiment Log

| Date | Experiment | Threats Discovered/Updated | Update |
|------|-----------|---------------------------|--------|
| 2026-03-19 | RU-L1: EVM Executor | T-03 through T-07 | Initial creation from literature review |
