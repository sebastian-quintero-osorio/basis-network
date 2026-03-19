# Session Memory: Production DAC (RU-L8)

## Key Decisions

1. **Hybrid AES+RS+Shamir chosen over pure Shamir**: 2.77x storage improvement, 36x
   faster attestation, 2,600x faster recovery. Trade-off: computational privacy (AES)
   instead of information-theoretic (Shamir on data). Key secrecy remains
   information-theoretic via Shamir on the 32-byte AES key.

2. **klauspost/reedsolomon selected**: Production-proven (MinIO, Storj, CockroachDB),
   SIMD-optimized, MIT license. Alternative vivint/infectious considered but less maintained.

3. **AES key reduction mod BN254 prime**: Critical implementation detail. Random 32-byte
   keys exceed 254-bit BN254 scalar field ~75% of the time. Must reduce modulo prime
   before Shamir sharing. Retains 254 bits of entropy (sufficient for AES-256-GCM).

4. **ECDSA for prototype, BLS for production**: ECDSA simpler for benchmarking. BLS
   aggregation provides constant-size on-chain attestation (48 bytes vs 455 bytes for
   7 ECDSA signatures). BN254 pairing precompiles available on Subnet-EVM.

## Performance Baselines

- Attestation: ~9 us/KB (linear scaling)
- Recovery: ~0.95 us/KB (linear scaling, RS decode)
- Storage: 1.40x (converges to 7/5 = 1.4x for large batches)
- Key operations: ~0.02 ms total (Shamir split + recover for single 32-byte element)

## Open Questions

- Network latency impact at 7 nodes (RTT to all nodes, not simulated)
- KZG commitment generation cost for real batch sizes
- BLS verification cost on Subnet-EVM (pairing precompile performance)
- Byzantine node behavior with malicious/corrupt chunks
