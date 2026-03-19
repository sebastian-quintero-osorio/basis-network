# Findings: L1-L2 Bridge Design for Enterprise zkEVM

## Experiment Identity

- **Target**: zkl2
- **Domain**: l2-architecture
- **Date**: 2026-03-19
- **Stage**: 1 (Implementation) -- Iteration 1

## Hypothesis

**H1**: A bridge contract can process deposits (L1->L2) in < 5 minutes and withdrawals
(L2->L1) in < 30 minutes, with an escape hatch that allows withdrawal via Merkle proof
directly on L1 if the sequencer is offline for > 24 hours.

**H0**: The bridge cannot achieve sub-5-minute deposit or sub-30-minute withdrawal latency
due to proof verification overhead, or the escape hatch mechanism introduces exploitable
double-spend vectors that compromise bridge solvency.

## Published Benchmarks (Literature Review)

### Production Bridge Performance

| System | Operation | Latency | Gas Cost (L1) | Source |
|--------|-----------|---------|---------------|--------|
| zkSync Era | Deposit (L1->L2) | ~5 min (batch inclusion) | ~50K gas (deposit tx) | zkSync docs |
| zkSync Era | Withdrawal (L2->L1) | 3h execution delay + finalization | ~100K gas (finalizeWithdrawal) | zkSync docs, L2BEAT |
| zkSync Era | Hard finality (L1 verified) | 10-20 min | N/A (batch-level) | arxiv 2506.00500 |
| Polygon zkEVM | Deposit (L1->L2) | 5-15 min (batch dependent) | ~60K gas (bridgeAsset) | Polygon docs |
| Polygon zkEVM | Withdrawal (L2->L1) | 30-60 min (proof finalization) | ~80K gas (claimAsset) | Polygon docs |
| Scroll | Deposit (L1->L2) | ~10-20 min (batch + proof) | ~50K gas | Scroll docs |
| Scroll | Withdrawal (L2->L1) | 3-5 hours (proof generation + finalization) | ~80-120K gas (relayMessageWithProof) | Scroll docs, L2BEAT |
| Arbitrum | Forced inclusion | Up to 24h delay | ~50K gas (force include) | Arbitrum docs |

### Escape Hatch Mechanisms in Production

| System | Mechanism | Timeout | Status | Source |
|--------|-----------|---------|--------|--------|
| zkSync Era | Forced L1 queue | No guaranteed processing | Active (operator can censor) | L2BEAT |
| Polygon zkEVM | Emergency State | 1 week (anyone can trigger) | Active (pessimistic proofs) | Polygon docs |
| Scroll | EnforcedTxGateway | 7 days (no batch finalization) | Active (permissionless prover) | L2BEAT, Scroll docs |
| Optimism/Arbitrum | Forced inclusion | 24h (Arbitrum), 12h (Optimism) | Active | L2BEAT |
| Zircuit (escape hatch paper) | Resolver + Merkle proof | T (configurable) | Research (2025) | arxiv 2503.23986 |

### Bridge Architecture Patterns

| Pattern | Used By | Description | Pros | Cons |
|---------|---------|-------------|------|------|
| Lock-Mint | zkSync, Polygon, Scroll | Lock on L1, mint on L2 | Simple, proven | Requires L2 token contracts |
| Shared Bridge | zkSync Era (v24+) | Unified liquidity across chains | Capital efficient | Complex governance |
| LxLy (Exit Trees) | Polygon CDK | Global exit tree for cross-chain | Multi-chain interop | Complex Merkle management |
| Withdraw Trie | Scroll | Binary Merkle tree of L2->L1 msgs | Simple proof verification | Per-batch finalization |

### Merkle Proof Verification Gas Costs

| Tree Type | Depth | Hash Function | Gas per Verify | Source |
|-----------|-------|---------------|----------------|--------|
| Binary Merkle | 20 | keccak256 | ~30K gas | OpenZeppelin MerkleProof |
| Binary Merkle | 32 | keccak256 | ~48K gas | Estimated (32 * ~1.5K per hash) |
| Sparse Merkle | 32 | keccak256 | ~48K gas (non-zero path) | attestate/indexed-sparse-merkle-tree |
| Sparse Merkle | 32 | Poseidon | ~160K gas (no precompile) | Estimated (Poseidon ~5K gas per hash in Solidity) |

**Critical insight**: Basis Network uses Poseidon SMT for L2 state (I-06, I-15). However,
for the bridge withdrawal trie, we should use keccak256 because:
1. Bridge Merkle proofs are verified on L1 in Solidity, where keccak256 is 6 bytes opcode
2. Poseidon in Solidity costs ~5K gas per hash vs ~30 gas for keccak256
3. The withdrawal trie is separate from the state trie -- it only records L2->L1 messages
4. This follows Scroll's design: separate Withdraw Trie with keccak256

### Avalanche-Specific Considerations

| Metric | Value | Source |
|--------|-------|--------|
| Snowman finality | < 2 seconds | Avalanche docs |
| Gas price on Basis L1 | 0 (zero-fee) | Basis Network config |
| Block time | ~2 seconds | Avalanche docs |
| L1 tx confirmation | ~2 seconds | Avalanche Fuji testnet |

**Critical advantage**: Zero-fee L1 + sub-2s finality means:
- Deposit confirmation: 1 L1 tx (~2s) + batch inclusion on L2 (~1-2 blocks = 1-2s) = **~4 seconds**
- Withdrawal finalization: batch proof on L1 + 1 claim tx = **seconds, not hours**
- No gas cost barrier for escape hatch operations

This is fundamentally different from Ethereum-based bridges where:
- L1 tx costs $5-50 in gas
- Block finality is 12-15 minutes
- Escape hatch gas costs are a real barrier

### Security Properties from Literature

| Property | Description | Enforced By | Source |
|----------|-------------|-------------|--------|
| NoDoubleSpend | Asset withdrawn once only | Nullifier mapping | zkopru, Polygon |
| BalanceConservation | L1 locked == L2 minted | Lock-mint accounting | All bridges |
| EscapeHatchLiveness | User can exit if operator fails | Time-based trigger + Merkle proof | arxiv 2503.23986 |
| MessageOrdering | L2->L1 messages processed in order | Withdrawal queue/trie | Scroll |
| ProofFinality | Withdrawal only after batch executed | Batch lifecycle gate | zkSync, BasisRollup |

### Double-Spend Prevention Strategies

| Strategy | Gas Cost | Complexity | Used By |
|----------|----------|------------|---------|
| Bitmap nullifier (256 per slot) | ~5K gas (warm) | Low | Optimized bridges |
| Mapping nullifier (bool per withdrawal) | ~20K gas (cold) | Minimal | Most bridges |
| Exit tree nullification | ~48K gas (tree update) | Medium | Polygon LxLy |

### Formal Analysis Results

Chaliasos et al. (CCS'25) formalized rollup bridge safety using Alloy specification language:
- Identified forced queue ordering pitfalls in existing designs
- Model-checked correctness of enhanced queue design
- Key finding: L2s susceptible to multisig attacks leading to total fund loss
- Recommendation: forced transaction queues as primary censorship resistance

Figueira (arxiv 2503.23986) proposed practical escape hatch design:
- Time-based trigger (configurable timeout T)
- Resolver contracts for asset location in L2 state
- Nullifiers prevent double-escape
- Limitation: escape triggers force chain hard fork (bridge balances diverge from L2 state)
- Limitation: non-keccak hash functions increase escape hatch gas costs

## Design Recommendations for BasisBridge

### Architecture: Lock-Mint with Keccak256 Withdraw Trie

Based on the literature review, the recommended design is:

1. **Deposit (L1->L2)**: Lock assets in BasisBridge.sol on L1, emit DepositInitiated event.
   Relayer picks up event and mints/credits on L2. With Avalanche sub-2s finality and
   zero-fee gas, deposits can complete in < 10 seconds (not minutes).

2. **Withdrawal (L2->L1)**: Burn/lock on L2, append to L2 Withdraw Trie (keccak256, depth 32).
   After batch containing withdrawal is executed on L1 (via BasisRollup), user submits
   Merkle proof to BasisBridge.sol to claim. With E2E pipeline at 14s (default), withdrawal
   can complete in < 30 seconds.

3. **Escape Hatch**: If no batch is executed on L1 for > 24 hours (configurable), anyone can
   trigger escape mode. Users submit Merkle proof of their balance in the last finalized
   L2 state root to withdraw directly from BasisBridge.sol. Nullifier mapping prevents
   double-withdrawal.

### Key Integration Points with BasisRollup.sol

- `isExecutedRoot(enterprise, batchId, root)` -- verify batch is finalized
- `getLastL2Block(enterprise)` -- check if sequencer is live
- `enterprises[enterprise].currentRoot` -- last finalized state root for escape hatch
- Batch lifecycle: Committed -> Proven -> Executed gates withdrawal claims

### Gas Budget (Zero-Fee L1)

Even though Basis L1 is zero-fee, gas limits still apply for computation:

| Operation | Estimated Gas | Notes |
|-----------|---------------|-------|
| deposit() | ~60K | Lock ETH/tokens, emit event, update deposit counter |
| claimWithdrawal() | ~80K | Verify Merkle proof (32 hashes), nullifier check, transfer |
| escapeWithdraw() | ~120K | Verify state proof, nullifier check, escape mode check, transfer |
| activateEscapeHatch() | ~30K | Check timeout, set escape mode flag |

All well within block gas limit. Zero-fee means no economic barrier.

### Latency Budget

| Phase | Deposit (L1->L2) | Withdrawal (L2->L1) |
|-------|-------------------|----------------------|
| L1 tx confirmation | ~2s | N/A |
| Relayer pickup | ~2s | N/A |
| L2 inclusion | ~1-2s | N/A |
| L2 tx execution | N/A | ~1s |
| Batch aggregation | N/A | ~10-60s (batch interval) |
| E2E pipeline (prove) | N/A | ~14s (100-tx default) |
| L1 claim tx | N/A | ~2s |
| **Total** | **~5-6s** | **~30-80s** |

Both well within hypothesis targets (< 5 min deposit, < 30 min withdrawal).

## Benchmark Reconciliation

### Deposit Latency

Our estimate of ~5s is 60x faster than zkSync Era (~5 min) and 180x faster than Scroll
(~15 min). This is consistent because:
- Avalanche finality (2s) vs Ethereum (12+ min)
- Zero-fee means no gas optimization/batching pressure
- Enterprise context means low contention

### Withdrawal Latency

Our estimate of ~30-80s is 130-200x faster than zkSync Era (3h) and 180-360x faster than
Scroll (3-5h). This is consistent because:
- Avalanche finality (2s) vs Ethereum (12+ min)
- Our pipeline proves 100-tx batches in 14s (enterprise-grade, simpler circuits)
- No additional security delay needed (zero-fee, permissioned network)

### Divergence Check

No estimate diverges >10x from what is physically possible given Avalanche consensus
properties. The large speedup vs Ethereum-based bridges is entirely explained by the
consensus layer difference. PASS.

## References

1. Figueira, F. "A Practical Rollup Escape Hatch Design." arxiv 2503.23986, March 2025.
2. Chaliasos, S., Firsov, D., Livshits, B. "Towards a Formal Foundation for Blockchain Rollups." CCS'25, 2024.
3. Chaliasos, S. et al. "Analyzing and Benchmarking ZK-Rollups." IACR ePrint 2024/889. AFT'24.
4. zkSync Era Bridge Documentation. docs.zksync.io/zksync-protocol/rollup/bridging-assets
5. Polygon LxLy Unified Bridge. docs.polygon.technology/zkEVM/architecture/unified-LxLy/
6. Scroll L1 and L2 Bridging. docs.scroll.io/en/developers/l1-and-l2-bridging/
7. Scroll Withdraw Gateways. docs.scroll.io/en/technology/bridge/withdraw-gateways/
8. L2BEAT zkSync Era Risk Assessment. l2beat.com/scaling/projects/zksync-era
9. L2BEAT Scroll Risk Assessment. l2beat.com/scaling/projects/scroll
10. L2BEAT Polygon zkEVM Risk Assessment. l2beat.com/scaling/projects/polygonzkevm
11. L2BEAT Bridge Risk Framework. forum.l2beat.com/t/l2bridge-risk-framework/31
12. Ethereum Foundation. "Zero-Knowledge Rollups." ethereum.org/developers/docs/scaling/zk-rollups/
13. OpenZeppelin MerkleProof.sol. github.com/OpenZeppelin/openzeppelin-contracts
14. Zkopru Merkle Trees. docs.zkopru.network/how-it-works/merkle-trees
15. Avalanche Snowman Consensus. build.avax.network/docs/primary-network/avalanche-consensus
16. Quantstamp L2 Security Framework. github.com/quantstamp/l2-security-framework
17. Scaling DeFi with ZK Rollups. arxiv 2506.00500, 2025.
18. push0: Scalable and Fault-Tolerant ZK Proof Orchestration. arxiv 2602.16338, 2025.
19. Ethical Risk Analysis of L2 Rollups. arxiv 2512.12732, 2025.
20. Basis Network E2E Pipeline Experiment. zkl2/research/experiments/2026-03-19_e2e-pipeline/
21. Basis Network BasisRollup Experiment. zkl2/research/experiments/2026-03-19_basis-rollup/
