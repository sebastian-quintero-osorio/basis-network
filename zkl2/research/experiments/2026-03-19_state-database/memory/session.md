# Session Memory: State Database (RU-L4)

## Key Decisions

- Used gnark-crypto Poseidon2 (not original Poseidon) for maximum Go performance
- Poseidon2 produces DIFFERENT hashes than circomlibjs Poseidon -- not cross-compatible
- Architect must align hash function choice with prover circuit library
- Depth 32 tested for RU-V1 comparison; EVM needs 160-256 in production
- Batch update benchmark is the correct measure for hypothesis (not full tree build)

## Performance Summary

- Poseidon2 hash: 4.46 us/hash in Go (12.6x faster than JS)
- Insert: 125-183 us (10-14x faster than TypeScript)
- Proof verify: 151 us (11.4x faster than TypeScript)
- Batch 100tx on 10K tree: 18.77ms (PASS < 50ms)
- Batch 250tx on 10K tree: 46.05ms (PASS < 50ms, barely)
- Batch 500tx on 10K tree: 91.07ms (FAIL)

## Critical Warnings for Architect

1. At depth 160 (EVM addresses), all operations are 5x slower than depth 32
2. 100-tx batch at depth 160 would be ~94ms -- FAILS 50ms target
3. Must implement compact SMT or batch optimization for production
4. Memory: ~2.9 KB/entry at depth 32, scales with depth
5. Persistent storage (LevelDB/Pebble) required for >100K entries

## Library Recommendation

- vocdoni/arbo: best for circom compatibility (original Poseidon)
- gnark-crypto: best for performance (Poseidon2, assembly-optimized)
- Choice depends on prover framework: circom/snarkjs vs gnark/halo2
