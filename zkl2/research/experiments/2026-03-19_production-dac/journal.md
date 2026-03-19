# Experiment Journal: Production DAC with Erasure Coding

## 2026-03-19 -- Stage 1: Implementation

### Iteration 1: Full Benchmark Suite

**What was done:**
1. Created experiment structure extending RU-V6 (Validium DAC) to production scale
2. Wrote comprehensive literature review (19 references, 8 production systems)
3. Implemented hybrid AES-256-GCM + Reed-Solomon (5,7) + Shamir (5,7) in Go
4. Ran 7 benchmark suites with 50+ replications each

**Key design decisions:**
- **Hybrid architecture** (AES+RS+Shamir): Combines computational data privacy (AES),
  storage-efficient redundancy (RS 1.4x vs Shamir 3.87x), and information-theoretic key
  secrecy (Shamir for the 32-byte AES key only)
- **Key reduction modulo BN254 prime**: Random 32-byte AES keys can exceed the 254-bit BN254
  scalar field. Fix: reduce key mod prime before Shamir sharing (254-bit entropy retained)
- **klauspost/reedsolomon**: Production RS library (MinIO, Storj, CockroachDB), SIMD-optimized

**What surprised me:**
- The 5-of-7 configuration is actually **slightly faster** than 2-of-3 at 500KB (0.95x ratio).
  This is because RS encoding/decoding is O(n log n) regardless of k, and the encryption
  overhead (AES) is identical for both configurations. The extra Shamir operations for k=5
  are negligible (single field element).
- Storage overhead at 1.40x is better than the 2-of-3 Shamir approach (1.50x for the hybrid),
  despite having 7 nodes instead of 3. RS distributes data more efficiently.
- Recovery is sub-millisecond. The RS decode is so fast that the bottleneck is memory
  allocation, not computation. This is 2,600x faster than RU-V6 Lagrange interpolation.

**What would change my mind (anti-confirmation bias):**
- If network latency (not simulated here) dominates, the 7-node configuration would show
  higher latency due to waiting for 5 signatures vs 2. This is the main unknown.
- If a production deployment shows AES-GCM key management complexity (nonce reuse,
  key rotation) exceeding the simplicity of pure Shamir, the hybrid might not be worth it.
- If KZG commitment generation turns out to be >100ms for enterprise batch sizes,
  the total latency budget may be tighter than measured here.

**Bugs fixed:**
1. AES key > BN254 prime causing ~75% Shamir Split failures. Fixed with mod-prime reduction.
2. Unexported Node fields accessed from benchmark runner. Fixed with GetStored() public method.

**Next steps:**
- Stage 2: Add network latency simulation (50-100ms RTT per node)
- Stage 2: KZG commitment generation benchmarks
- Stage 3: Adversarial scenarios (malicious node sends corrupt chunk, Byzantine behavior)
- Stage 4: Ablation (remove AES, remove RS, remove Shamir -- measure individual contributions)
