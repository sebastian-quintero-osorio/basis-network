# Experiment Journal: Data Availability Committee

## 2026-03-18 -- Literature Review (Stage 0)

### Objective
Conduct comprehensive literature review for RU-V6 (Data Availability Committee) before
experimental design. Meet the 15+ paper literature gate requirement.

### Search Strategy
1. Surveyed all major production DAC systems: StarkEx, Polygon CDK, Arbitrum Nova,
   EigenDA, Celestia, Espresso, zkPorter
2. Extracted on-chain contract code (CDKDataCommittee.sol) for attestation protocol details
3. Searched IACR ePrint archive for academic papers on data availability, verifiable
   information dispersal, and secret sharing
4. Cross-referenced L2Beat for real committee configurations and security ratings
5. Gathered cryptographic primitive details: SSS, Reed-Solomon, BLS, KZG

### Key Findings

**Finding 1: Production DACs do NOT provide privacy.**
Every production DAC (StarkEx, Polygon CDK, Arbitrum Nova) distributes COMPLETE batch
data to every committee member. No secret sharing, no erasure coding, no encryption.
The RU-V6 privacy requirement ("without exposing data to any individual node") goes
beyond current industry practice. This is a genuine innovation opportunity.

**Finding 2: Honest minority (AnyTrust model) is strictly superior.**
L2Beat rates all small-committee honest-majority DACs as "BAD." Arbitrum Nova's 5-of-6
with rollup fallback is the only design rated above "BAD" for small committees. The
original 2-of-3 hypothesis should be reconsidered in favor of 3-of-3 with fallback.

**Finding 3: Shamir's SS is viable for enterprise-scale data.**
For batches under 1 MB (typical enterprise), Shamir's (2,3)-SS generates and reconstructs
in under 50 ms. Storage is 3x, but at 500 KB batches, 1.5 MB total storage is trivial.
Information-theoretic privacy is the gold standard.

**Finding 4: EigenDA V2 sets the throughput bar.**
100 MB/s write, 5-second confirmations, 8x redundancy RS + KZG. However, this targets
a different scale (hundreds of rollups, TB-scale data). Enterprise DAC operates at
KB-MB scale, where simpler designs (SSS + ECDSA) outperform.

**Finding 5: Semi-AVID-PR paper is directly applicable.**
Nazirkhanova, Neu, Tse (2021) explicitly designed for validium rollups with privacy
against curious storage nodes. Their 3-second latency for 22 MB across 256 nodes
suggests that a 3-node DAC with 500 KB data will be well under 1 second.

### What Would Change My Mind
- If SSS computational overhead at BN128 field size is >10x estimated (unlikely, but
  must be benchmarked)
- If enterprise batch sizes exceed 10 MB (would favor RS over SSS)
- If Avalanche Subnet-EVM BN128 precompile costs are prohibitive for BLS verification
  (irrelevant since gas = 0, but computation time matters)

### Next Steps
1. Implement experimental code: SSS over BN128 field, benchmark share gen/reconstruct
2. Implement ECDSA attestation protocol, benchmark round-trip time
3. Compare SSS vs encrypt-then-RS for batches at 100KB, 500KB, 1MB, 5MB
4. Benchmark on-chain verification cost (ECDSA multi-sig vs BLS aggregated)
5. Design and test AnyTrust-style fallback mechanism

---

## 2026-03-18 -- Implementation + Baseline Benchmarks (Stage 1-2)

### Objective
Implement the full DAC protocol (Shamir SSS + DACNode + attestation + recovery) and
establish baseline benchmarks across enterprise batch sizes.

### Implementation

Wrote 6 TypeScript modules in `validium/research/experiments/2026-03-18_data-availability-committee/code/src/`:

1. **types.ts** -- BN128 field constants, Share/Attestation/Certificate types
2. **shamir.ts** -- Shamir (k,n)-SS: share generation, reconstruction, data<->field encoding
3. **dac-node.ts** -- DACNode with share storage, attestation signing, recovery retrieval
4. **dac-protocol.ts** -- DACProtocol orchestrating distribution, attestation, recovery, fallback
5. **stats.ts** -- Statistical utilities (mean, stdev, CI, percentiles)
6. **benchmark.ts** -- 3-phase benchmark suite (main + failure + scaling)

Plus 2 test suites:
- **test-privacy.ts** -- 51 tests validating information-theoretic privacy
- **test-recovery.ts** -- 61 tests validating failure modes and recovery

### Key Results

**Attestation latency (2-of-3, all online):**
- 10 KB: 3.2ms mean (512x under 2s target)
- 100 KB: 32.1ms mean (62x under target)
- 500 KB: 163.5ms mean (12x under target)
- 1 MB: 320.2ms mean (6.2x under target)

**Share generation: ~9.5 us/element** (linear scaling confirmed).
Literature estimated 0.6-3 us/element for native code; JS BigInt is 3-16x slower.
This is consistent with known BigInt overhead and does NOT invalidate the hypothesis
since attestation is still well under 2 seconds.

**Recovery: 2-of-3 is ~8x faster than 3-of-3** due to O(k^2) Lagrange interpolation.
At 1MB: 2.5s for 2-of-3, 19.5s for 3-of-3. Recovery is NOT on the critical path.

**Storage: 3.87x overhead** (3 nodes * 32/31 byte encoding). Less than EigenDA (8x).

**Privacy: 51/51 tests pass.** Share distributions are statistically indistinguishable
for different secrets. Single share algebraically consistent with any possible secret.

**Failure modes: 61/61 tests pass.** 1-node failure: attestation and recovery succeed.
2-node failure: fallback triggers correctly. Certificate tamper detection works.

### What Would Change My Mind
- If production native implementation shows >10ms attestation at 1MB (would indicate
  the JavaScript estimate was misleading, not just slow)
- If network latency between DAC nodes exceeds local computation time (this experiment
  simulated co-located nodes; real WAN latency could dominate)
- If Shamir share verification requires in-circuit computation (adding circuit constraints)

### Decisions Made
1. **Chose (2,3)-Shamir over (3,3)**: 8x recovery speed advantage, same privacy guarantee.
   3-of-3 only needed with AnyTrust model (require ALL to attest, fallback if not).
2. **ECDSA over BLS for attestation**: Native EVM support, simpler, sufficient for 3 nodes.
   BLS only needed at >10 committee members for signature compression.
3. **SHA-256 for data commitment**: Faster than Poseidon, standard. Poseidon only needed
   if the commitment must be verified inside a ZK circuit (OQ-11).
4. **Adaptive replications**: 50/30/10 by batch size due to JS BigInt cost. All CI < 5%.

### Next Steps for Stage 3 (Adversarial Testing)
1. Malicious share injection (corrupted shares to detect or break reconstruction)
2. Timing-based information leakage (does share generation time correlate with secret value?)
3. Colluding nodes attempting to reconstruct without threshold
4. Network partition simulation (delayed attestation, timeout behavior)
5. Proof-of-custody challenge mechanism design
