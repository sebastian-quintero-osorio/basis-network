# Experiment Journal: basis-rollup

## Target: zkl2 | Domain: l2-architecture | Stage: 1 (Implementation)

---

### 2026-03-19 -- Iteration 0: Draft

**Context:**
- Extending validium StateCommitment.sol (RU-V3, 285K gas) to full zkEVM L2 rollup contract
- Prior work: RU-L1 (EVM executor), RU-L2 (sequencer), RU-L3 (witness generation), RU-L4 (state database) all complete
- This experiment addresses RU-L5 scope: L1 rollup contract design for enterprise zkEVM

**Design decisions:**

1. **Commit-prove-execute pattern** (zkSync Era model) chosen over single-phase submit:
   - Allows asynchronous proving (sequencer commits fast, prover catches up)
   - Enables batch revert if proof fails (without chain corruption)
   - Supports future proof aggregation (multiple batches per proof)
   - Standard in production: zkSync Era, Scroll, Polygon zkEVM all use variants

2. **Block-level tracking** added to batch metadata:
   - L2 blocks are produced every 1-2s (RU-L2 sequencer findings)
   - Batches aggregate N blocks (N = 10-100 depending on load)
   - Bridge withdrawals and forced inclusion reference L2 block numbers, not batch IDs
   - Block range stored in commit phase, not proven phase (cheaper)

3. **Per-enterprise state chains preserved** from validium:
   - Each enterprise has independent batch lifecycle
   - Enterprise isolation is structural (msg.sender mapping)
   - Global counters track cross-enterprise totals

4. **Priority operations queue** for censorship resistance:
   - Forced inclusion from L1 (RU-L2 sequencer design)
   - Sequencer must include priority ops within deadline
   - Bridge deposits flow through priority queue

**What would change my mind:**
- If commit phase alone exceeds 150K gas (storage is more expensive than estimated)
- If the 3-phase pattern requires >500K total gas (making it worse than competitors)
- If block-level tracking adds >50K gas over batch-only tracking

**Literature consulted:** See findings.md Published Benchmarks section.
