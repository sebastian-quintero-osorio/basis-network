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
**Mitigation:** Forced inclusion via L1 (Arbitrum-style DelayedInbox, 24h FIFO queue).
Enterprise context with zero-fee model eliminates MEV, but censorship remains possible.
FIFO queue ordering prevents selective censorship (delaying one = delaying all).
**Status:** VALIDATED in RU-L2. Prototype demonstrates 100% forced inclusion with FIFO ordering.
**Residual risk:** On rich-state chains, sequencer can cause forced txs to fail by modifying
shared state before inclusion (ref: "Practical Limitations on Forced Inclusion" 2025).
Enterprise context mitigates this (enterprise controls both sequencer and contracts).

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

### T-11: Sequencer Liveness Failure

**Threat:** Sequencer stops producing blocks (crash, resource exhaustion, operator error).
**Impact:** L2 chain halts. No new transactions processed. Forced inclusion deadline
begins ticking but no blocks to include them in.
**Mitigation:** (a) Block production liveness invariant I-12 requires production even when
empty, (b) L1 monitoring detects stall, (c) enterprise can restart sequencer from last
committed batch, (d) escape hatch allows L1 withdrawal via Merkle proof.
**Source:** RU-L2 experiment.

### T-12: Mempool Overflow Under Burst Load

**Threat:** Burst of transactions exceeds mempool capacity, causing drops.
**Impact:** Legitimate enterprise transactions silently rejected.
**Mitigation:** (a) Configurable mempool capacity (default 10K), (b) backpressure signaling
via JSON-RPC error, (c) enterprise load is predictable and bounded (not DeFi-style bursts),
(d) measured: mempool handles 2.8M inserts/s, well above enterprise target.
**Source:** RU-L2 experiment (capacity enforcement test: 100% accurate).

### T-13: Forced Inclusion State Manipulation

**Threat:** Sequencer modifies L2 state to cause forced transactions to revert, effectively
achieving censorship without violating forced inclusion deadline.
**Impact:** Transaction included but fails execution (out-of-gas, revert).
**Mitigation:** (a) Enterprise context: sequencer and contract deployer are same entity,
(b) forced txs can target immutable contracts, (c) audit log on L1 records inclusion
attempts, (d) L1 monitoring can detect pattern of forced tx reverts.
**Source:** "Practical Limitations on Forced Inclusion Mechanisms" (2025), RU-L2 literature review.
**Severity:** LOW for enterprise (sequencer is enterprise-operated), MEDIUM for general case.

### T-14: State Root Computation Timeout

**Threat:** Block contains too many state-modifying transactions, causing state root
computation to exceed block time budget.
**Impact:** Sequencer falls behind, block production stalls, forced inclusion deadlines
may be missed.
**Mitigation:** (a) Configurable transaction limit per block (max 250 for depth-32 SMT),
(b) per-update cost is constant (~183 us at depth 32), so limit is deterministic,
(c) batch optimization reduces per-update cost for deep trees,
(d) block builder should enforce tx count limit before sealing block.
**Source:** RU-L4 experiment (measured: 46ms for 250 tx, 91ms for 500 tx at depth 32).
**Severity:** MEDIUM -- preventable with proper block size limits.

### T-15: Hash Function Mismatch Between State DB and Prover

**Threat:** State database uses Poseidon2 (gnark-crypto) but ZK circuit expects original
Poseidon (circomlibjs/circom), or vice versa. Different hash functions produce different
roots, making all proofs invalid.
**Impact:** Complete system failure -- no valid proofs can be generated.
**Mitigation:** (a) Architectural decision: align state DB hash with prover circuit hash
from the start, (b) integration test: verify state root from DB matches circuit output,
(c) document hash function choice in technical decisions.
**Source:** RU-L4 library analysis (Poseidon vs Poseidon2 compatibility).
**Severity:** HIGH -- catastrophic if undetected, trivially preventable with testing.

### T-16: Deep Tree Performance Degradation

**Threat:** EVM requires depth 160-256 for address/storage space. All operations scale
linearly with depth: depth-160 is 5x slower than depth-32.
**Impact:** At depth 160, a 100-tx block takes ~94ms (exceeds 50ms target). At depth
256, it takes ~150ms.
**Mitigation:** (a) Compact SMT with path compression (effective depth << nominal depth
for sparse trees), (b) batch update optimization (arXiv:2310.13328),
(c) parallel subtree updates via goroutines, (d) Poseidon assembly optimization.
**Source:** RU-L4 depth sensitivity analysis.
**Severity:** HIGH -- must be addressed before production deployment.

### T-17: Witness Completeness Gap

**Threat:** Witness generator drops trace entries for certain operation types, producing
an incomplete witness that omits state transitions.
**Impact:** Omitted state transitions are unproven. The circuit either rejects the proof
(safety-preserving) or accepts a proof that does not cover all state changes (catastrophic
if the circuit does not enforce completeness).
**Mitigation:** (a) Unit test: total witness rows >= total trace entries, (b) circuit
enforces that every trace entry has a corresponding witness row via global counter,
(c) Coq proof of completeness (Prover agent, item [16]).
**Source:** RU-L3 experiment.
**Severity:** HIGH -- completeness is a security-critical property.

### T-18: Witness Non-Determinism

**Threat:** Witness generator produces different output for the same input trace due to
non-deterministic container ordering, concurrency, or platform-dependent behavior.
**Impact:** Prover and verifier disagree on witness. Proofs generated on one machine
cannot be verified on another. Distributed proving becomes impossible.
**Mitigation:** (a) Use BTreeMap (sorted) instead of HashMap everywhere, (b) sequential
processing preserving trace execution order, (c) no floating-point arithmetic (all field
arithmetic is exact), (d) determinism verified experimentally (PASS, n=30 runs).
**Source:** RU-L3 experiment.
**Severity:** HIGH -- non-determinism breaks the entire proving pipeline.

### T-19: IPC Latency for Merkle Proof Retrieval

**Threat:** In production, the Rust witness generator must query the Go state DB via
gRPC/IPC to retrieve actual Merkle proof siblings. IPC latency could dominate witness
generation time, especially for storage-heavy batches.
**Impact:** Witness generation time increases 10-50x from prototype measurements,
potentially approaching seconds for 1000 tx batches.
**Mitigation:** (a) Batch DB queries: request all Merkle proofs for a batch in one call,
(b) local proof cache for repeated slot accesses within a batch, (c) Go state DB exposes
batch proof API, (d) measured prototype: 13.37 ms for 1000 tx, so even 50x overhead
= 668 ms (still well under 3s budget from I-19).
**Source:** RU-L3 architectural analysis.
**Severity:** MEDIUM -- significant overhead but large margin available.

### T-20: JSON Serialization Bottleneck

**Threat:** JSON parsing of execution traces from Go executor becomes a bottleneck at
scale (>1000 tx per batch or complex contract interactions).
**Impact:** JSON parsing overhead (5-10x vs binary) could dominate witness generation.
**Mitigation:** (a) Use protobuf or flatbuffers for Go-to-Rust trace serialization,
(b) streaming deserialization to avoid loading entire trace into memory,
(c) measured: JSON parsing is already fast for 1000 tx; address when needed.
**Source:** RU-L3 performance analysis.
**Severity:** LOW -- optimization opportunity, not a blocker.

### T-21: Batch Commitment Front-Running

**Threat:** An attacker observes a sequencer's commitBatch transaction in the mempool
and submits a conflicting batch with the same block range, front-running the legitimate
sequencer.
**Impact:** Legitimate batch rejected due to block range conflict (INV-R4 MonotonicBlockRange).
**Mitigation:** (a) msg.sender authorization ensures only the registered enterprise can
commit batches for its own chain, (b) permissioned L1 (zero-fee) reduces front-running
incentive, (c) enterprise isolation means attackers cannot target other enterprises' chains.
**Source:** RU-L5 design analysis.
**Severity:** LOW -- structural mitigation via per-enterprise msg.sender isolation.

### T-22: Stale Proof Submission

**Threat:** A prover submits a valid proof for a committed batch, but the batch was
reverted by admin between commitment and proof submission. The proof passes verification
but references a no-longer-committed batch.
**Impact:** Wasted gas (proof verified but batch no longer exists).
**Mitigation:** (a) Sequential proving counter (totalBatchesProven) ensures only the next
expected batch can be proven, (b) reverting a batch resets the committed counter, making
the old batch ID unreachable, (c) reverted batch's StoredBatchInfo is deleted (status = None).
**Source:** RU-L5 experiment, revert mechanism analysis.
**Severity:** LOW -- structural protection via sequential counters and batch deletion.

### T-23: Gas Exhaustion on First Batch

**Threat:** The first batch for an enterprise costs ~493K gas (projected with Groth16),
leaving only ~7K margin under the 500K target. If Subnet-EVM precompile costs differ
from mainnet EIP-197, the first batch could exceed the gas budget.
**Impact:** First batch fails; requires gas limit increase or contract optimization.
**Mitigation:** (a) Measure real Groth16 verification gas on Basis Network Fuji testnet,
(b) steady-state cost is 425K (75K margin) so only first batch is at risk,
(c) batch range proving (future) would amortize verification across multiple batches,
(d) can optimize first batch by pre-warming storage via initializeEnterprise.
**Source:** RU-L5 gas benchmark analysis.
**Severity:** MEDIUM -- first batch has tight margin; steady state is safe.

### T-24: Cross-Enterprise State Poisoning via Batch Revert

**Threat:** Admin reverts enterprise A's batch. If global counters are decremented
incorrectly, enterprise B's state could be affected.
**Impact:** Global counter desynchronization, breaking GlobalCountIntegrity invariant.
**Mitigation:** (a) Global counters are always incremented/decremented alongside per-enterprise
counters atomically, (b) revertBatch only modifies the target enterprise's state plus
global counters, (c) enterprise B's mapping entries are never touched, (d) verified by
adversarial test: GlobalCountIntegrity maintained across enterprises.
**Source:** RU-L5 adversarial testing.
**Severity:** LOW -- verified by test suite (61/61 passing).

### T-25: Bridge Double Spend via Proof Replay

**Threat:** Attacker obtains a valid Merkle proof for a withdrawal and submits it multiple
times to claim the same funds repeatedly.
**Impact:** Bridge insolvency -- more ETH released than deposited.
**Mitigation:** (a) Nullifier mapping: withdrawalNullifier[enterprise][withdrawalHash] tracks
each unique withdrawal, (b) checks-effects-interactions pattern: nullifier set BEFORE transfer,
(c) withdrawal hash includes enterprise, batchId, recipient, amount, and index -- all must match.
**Source:** RU-L7 literature review (zkopru, Polygon LxLy).
**Severity:** CRITICAL -- primary bridge vulnerability. Mitigated by nullifier design.

### T-26: Escape Hatch Premature Activation

**Threat:** Attacker triggers escape mode while sequencer is still operational by
manipulating the lastBatchExecutionTime tracking.
**Impact:** Users withdraw via escape hatch while L2 is live, creating state inconsistency.
**Mitigation:** (a) lastBatchExecutionTime is only updated by admin (relayer), (b) escape
timeout is 24 hours -- enough time for enterprise to recover from most failures, (c) even
if escape activates prematurely, the state root is still valid (last finalized root on L1),
(d) enterprise can deploy new sequencer and resume from last executed batch.
**Source:** arxiv 2503.23986 (Practical Escape Hatch Design).
**Severity:** MEDIUM -- premature escape causes L2 hard fork but does not lose funds.

### T-27: Escape Hatch State Root Staleness

**Threat:** The escape hatch uses the last finalized state root on L1. If the sequencer
failed after committing but before executing batches, the escape root may not include
recent transactions.
**Impact:** Users who deposited or transacted after the last executed batch lose those funds.
**Mitigation:** (a) Commit-prove-execute ensures only proven transitions are finalized, (b)
users can see their last finalized balance via L1 before deciding to escape, (c) unexecuted
batches can be replayed by a new sequencer (state is deterministic from executed root), (d)
24h timeout gives enterprise time to execute pending batches before escape activates.
**Source:** arxiv 2503.23986, Chaliasos et al. CCS'25.
**Severity:** HIGH -- potential loss of unfinalized transactions. Mitigated by 24h window.

### T-28: Withdraw Root Manipulation

**Threat:** Compromised admin/relayer submits a fabricated withdraw root that includes
unauthorized withdrawals.
**Impact:** Attacker creates fake withdrawals and claims them with valid Merkle proofs.
**Mitigation:** (a) Admin is enterprise-operated (same trust model as sequencer), (b) withdraw
root submission requires batch to be in Executed state on BasisRollup, (c) in production:
withdraw root can be derived from L2 state by any full node, enabling verification, (d) future:
withdraw root can be included in the ZK proof itself, eliminating admin trust.
**Source:** RU-L7 design analysis.
**Severity:** HIGH for general case, LOW for enterprise (admin IS the enterprise).

### T-29: Bridge Reentrancy via ETH Transfer

**Threat:** Malicious recipient contract re-enters claimWithdrawal() or escapeWithdraw()
during the ETH transfer to claim funds multiple times.
**Impact:** Bridge drained via reentrancy.
**Mitigation:** (a) Checks-effects-interactions pattern: nullifier set BEFORE transfer, (b)
second call to claim reverts with AlreadyClaimed/AlreadyEscaped, (c) state updates (nullifier,
totalWithdrawn) all happen before external call.
**Source:** Standard Solidity security (OWASP, SWC-107).
**Severity:** CRITICAL if unmitigated, LOW with checks-effects-interactions.

### T-30: Bridge Liquidity Fragmentation

**Threat:** Per-enterprise bridge accounting fragments liquidity. Enterprise A's deposits
cannot be used to fund Enterprise B's withdrawals.
**Impact:** Enterprise with high withdrawal volume may deplete its bridge balance even if
the overall bridge has sufficient ETH.
**Mitigation:** (a) Per-enterprise accounting is intentional for isolation (I-23), (b) enterprise
controls its own deposit/withdrawal flow, (c) admin can provide liquidity injection if needed,
(d) zero-fee model means enterprise can deposit additional liquidity at no cost.
**Source:** RU-L7 design analysis.
**Severity:** LOW -- enterprise-managed liquidity is a feature, not a bug.

### T-31: Relayer Liveness Failure

**Threat:** Relayer goes offline, preventing deposit crediting on L2 and withdraw root
submission on L1.
**Impact:** Deposits not credited on L2 (delayed, not lost). Withdrawals cannot be claimed
(delayed, not lost). After 24h, escape hatch activates.
**Mitigation:** (a) Deposits are locked on L1 and can be refunded by admin if relayer fails
permanently, (b) withdrawals are recorded in L2 state and can be claimed once a new relayer
submits the withdraw root, (c) escape hatch provides ultimate fallback, (d) enterprise can
restart relayer from last processed event.
**Source:** RU-L7 design analysis.
**Severity:** MEDIUM -- service disruption but no fund loss.

### T-32: Proof System Migration Gap

**Threat:** During migration from Groth16 to PLONK/halo2-KZG, a batch is committed with
one proof system but the verifier only accepts the other, creating a window where no valid
proof can be submitted.
**Impact:** Batches stuck in Committed state, unable to advance to Proven/Executed.
**Mitigation:** (a) Dual verification router: BasisRollup accepts both Groth16 AND PLONK
proofs during transition period, (b) per-enterprise migration flag allowing controlled
rollout, (c) migration can be rolled back by re-enabling legacy verifier.
**Source:** RU-L9 PLONK Migration research.
**Severity:** MEDIUM -- operational disruption if migration is not carefully coordinated.

### T-33: Universal SRS Compromise

**Threat:** The universal Structured Reference String (Powers-of-Tau) ceremony is compromised
-- all MPC participants collude or leak their toxic waste.
**Impact:** Attacker can forge proofs for any circuit using the SRS, breaking soundness.
**Mitigation:** (a) Use PSE perpetual-powers-of-tau ceremony (71+ participants; only 1 honest
participant needed), (b) SRS is updateable: any party can add randomness post-ceremony,
(c) for maximum security, Basis Network can contribute its own participant to the ceremony,
(d) enterprise context: the attacker would need to forge proofs AND control the sequencer.
**Source:** RU-L9 PLONK Migration, PLONK paper (IACR 2019/953).
**Severity:** LOW -- 71+ participants makes total compromise extremely unlikely.

### T-34: Custom Gate Soundness Error

**Threat:** A custom gate's polynomial constraint does not correctly encode the intended
EVM operation. The gate accepts invalid witnesses, allowing false state transitions.
**Impact:** Invalid state transitions pass proof verification. Potential fund theft via
forged proofs.
**Mitigation:** (a) halo2 MockProver detects constraint violations during development,
(b) formal verification of each gate via Coq (RU-L9 Prover step), (c) extensive test
vectors comparing gate output against reference EVM execution, (d) production zkEVMs
(Scroll, Taiko) have validated the halo2 custom gate approach.
**Source:** RU-L9 PLONK Migration research.
**Severity:** HIGH -- soundness bugs are the most critical ZK vulnerability. Mitigated
by formal verification and extensive testing.

### T-35: halo2 Library Dependency Risk

**Threat:** The selected halo2 fork (Axiom or PSE) introduces a regression, vulnerability,
or becomes unmaintained.
**Impact:** Security vulnerability in the proving system, or inability to update dependencies.
**Mitigation:** (a) PSE fork is in maintenance mode (bug fixes), providing a stable fallback,
(b) Axiom fork is actively maintained and production-grade, (c) halo2 API is stable; switching
forks requires minimal code changes, (d) Basis Network can fork the library if needed.
**Source:** RU-L9 PLONK Migration research (PSE maintenance mode announcement Jan 2025).
**Severity:** MEDIUM -- library risk is real but mitigated by ecosystem breadth.

## Experiment Log

| Date | Experiment | Threats Discovered/Updated | Update |
|------|-----------|---------------------------|--------|
| 2026-03-19 | RU-L1: EVM Executor | T-03 through T-07 | Initial creation from literature review |
| 2026-03-19 | RU-L2: Sequencer | T-01 (updated), T-11 through T-13 | Sequencer-specific threats from literature + experiment |
| 2026-03-19 | RU-L4: State Database | T-14 through T-16 | State root timeout, hash mismatch, deep tree degradation |
| 2026-03-19 | RU-L3: Witness Generation | T-17 through T-20 | Witness completeness, determinism, IPC latency, JSON bottleneck |
| 2026-03-19 | RU-L5: Basis Rollup | T-21 through T-24 | L1 rollup contract threats: front-running, stale proofs, gas exhaustion, cross-enterprise revert |
| 2026-03-19 | RU-L7: Bridge | T-10 (updated), T-25 through T-31 | Bridge security threats: double-spend, escape hatch, reentrancy, relayer failure |
| 2026-03-19 | RU-L9: PLONK Migration | T-32 through T-35 | Migration gap, SRS compromise, custom gate soundness, library dependency |
| 2026-03-20 | RU-L11: Hub-and-Spoke | T-36 through T-42 | Cross-enterprise attacks: false cross-ref, stale root, commitment replay, front-running, hub manipulation, timeout griefing, topology leak |

---

## Cross-Enterprise Hub-and-Spoke Threats (RU-L11)

### T-36: False Cross-Enterprise Reference

**Threat:** Attacker fabricates a cross-enterprise reference claiming an interaction
that never occurred between enterprises A and B.
**Impact:** False business claim recorded on L1 (e.g., fake invoice verification).
**Mitigation:** Hub contract verifies ZK proof against both enterprises' state roots
(independently verified on L1). Forging requires breaking either: (a) ZK proof
soundness (128-bit security on BN254), or (b) Poseidon preimage resistance (128-bit).
Both are computationally infeasible.
**Source:** RU-L11 Hub-and-Spoke research. Extended from RU-V7 ATK-CE1.
**Severity:** CRITICAL -- false cross-references could cause real financial damage.

### T-37: Stale State Root in Cross-Reference

**Threat:** Enterprise submits cross-reference proof against an old (but once-valid)
state root, referencing data that has since been updated or deleted.
**Impact:** Cross-reference based on outdated enterprise state.
**Mitigation:** Hub contract verifies state root against CURRENT on-chain root in
StateCommitment contract. Stale roots are always rejected. Measured: 100% rejection
rate in 30/30 tests.
**Source:** RU-L11 Hub-and-Spoke research. Extended from RU-V7 ATK-CE2.
**Severity:** HIGH -- stale references could validate outdated claims.

### T-38: Cross-Reference Commitment Replay

**Threat:** Replay a valid commitment from a previous cross-enterprise transaction.
**Impact:** Duplicate cross-enterprise record without new underlying interaction.
**Mitigation:** Per-enterprise-pair nonce tracked on-chain. Each nonce can only be
used once. Replay attempts are rejected with "nonce already processed". Nullifier
set prevents cross-nonce replay.
**Source:** RU-L11 Hub-and-Spoke research. Extended from RU-V7 ATK-CE3.
**Severity:** HIGH -- replay could cause double-counting of interactions.

### T-39: Cross-Enterprise Front-Running

**Threat:** Observer detects pending cross-enterprise transaction in mempool and
extracts relationship information or front-runs the transaction.
**Impact:** Information leakage or transaction manipulation.
**Mitigation:** (a) Commitment hides data content (Poseidon 128-bit). Only 1 bit
of information available (interaction exists). (b) Basis Network is permissioned --
only authorized submitters can send transactions. (c) Zero-fee model eliminates
MEV incentive. (d) Enterprise sequencers can use private mempools.
**Source:** RU-L11 Hub-and-Spoke research. Extended from RU-V7 ATK-CE4.
**Severity:** LOW on permissioned network. MEDIUM on public network.

### T-40: Hub Coordinator Manipulation

**Threat:** Hub coordinator (off-chain aggregation service) selectively excludes,
delays, or reorders cross-enterprise messages for profit or sabotage.
**Impact:** Censorship of cross-enterprise transactions; delayed settlement.
**Mitigation:** (a) Enterprises can bypass the coordinator and submit directly to
L1 using sequential verification (1.41x overhead but functional). (b) Hub
coordinator is an optimization, not a requirement. (c) Multiple competing
coordinators can exist. (d) On-chain inclusion is permissionless.
**Source:** RU-L11 Hub-and-Spoke research. Extended from RU-V7 ATK-CE5.
**Severity:** MEDIUM -- degraded performance but no data loss or security breach.

### T-41: Atomic Settlement Timeout Griefing

**Threat:** Enterprise A submits one side of an atomic cross-enterprise transaction
and never submits the second side, intentionally blocking Enterprise B's resources.
**Impact:** Enterprise B's cross-enterprise slot is locked until timeout.
**Mitigation:** (a) Timeout mechanism (T blocks, default 100 = ~200 seconds).
After timeout, either party can unilaterally revert. (b) No funds are locked during
the prepare phase -- only a logical slot is reserved. (c) Enterprise reputation
system can penalize repeat griefers.
**Source:** RU-L11 Hub-and-Spoke research (new threat, not in RU-V7).
**Severity:** LOW -- bounded by timeout. No financial loss, only temporary delay.

### T-42: Network Topology Information Leakage

**Threat:** Observer reconstructs the enterprise interaction graph from on-chain
cross-enterprise events, revealing business relationships.
**Impact:** Competitive intelligence extraction (who trades with whom, how often).
**Mitigation:** (a) Enterprise IDs are public by design (registered on L1). This is
known and accepted. (b) Interaction frequency can be masked by batching multiple
interactions or padding with null interactions. (c) Commitment content is hidden;
only existence is visible. (d) For maximum privacy, enterprises can use intermediate
relay enterprises to break linkability.
**Source:** RU-L11 Hub-and-Spoke research (new threat, not in RU-V7).
**Severity:** MEDIUM -- business relationship patterns are sensitive for enterprise users.
Future work: evaluate k-anonymity approaches for interaction graph privacy.
