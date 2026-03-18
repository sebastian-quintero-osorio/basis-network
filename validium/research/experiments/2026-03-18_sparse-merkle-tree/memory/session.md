# Session Memory: Sparse Merkle Tree Experiment

## Key Decisions
- Using circomlibjs Poseidon for BN128 compatibility with existing batch_verifier.circom
- Depth 32 chosen for ~4B addressable leaves
- Custom implementation over @iden3/js-merkletree for performance control
- TypeScript with BigInt arithmetic for field operations
- Binary tree (not quinary) -- simpler, better R1CS fit

## Important Constants
- BN128 field prime: 21888242871839275222246405745257275088548364400416034343698204186575808495617
- Poseidon constraints per hash: ~240 (Circom BN128)
- Existing circuit: batch_verifier.circom, 742 constraints, batch size 4
- Target: validium/node/src/state/ (Architect will implement production version)

## Measured Results (Stage 1)
- Poseidon 2-to-1 hash: 56.09 us/hash (17,830 hashes/s)
- MiMC hash: 278.55 us/hash (3,590 hashes/s)
- Poseidon/MiMC speedup: 4.97x
- Insert latency (100K entries): mean 1.825ms, P95 2.014ms
- Proof generation (100K entries): mean 0.018ms, P95 0.021ms
- Proof verification (100K entries): mean 1.744ms, P95 1.869ms
- Memory at 100K entries: 233.9 MB (1,712,112 nodes)
- All hypothesis targets: PASS

## Stage 2 Considerations
- Need 30+ reps per stochastic config with CI < 10% of mean
- Test sequential vs random key insertion patterns
- Test adversarial key patterns (all mapping to same subtree)
- Measure at intermediate sizes (500, 5000, 50000) for scaling curve
