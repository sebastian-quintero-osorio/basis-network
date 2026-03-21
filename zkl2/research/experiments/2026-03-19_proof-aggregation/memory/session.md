# Session Memory: Proof Aggregation (RU-L10)

## Key Decisions
- Selected ProtoGalaxy + Groth16 decider as production target based on:
  best gas efficiency (220K), best proof size (128B), reasonable aggregation time (~12s for N=8)
- Phased approach: binary tree accumulation first (proven at Scroll), then migrate to folding
- Used halo2-KZG inner proofs (640 bytes) to match RU-L9 stack decision

## Important Parameters
- Inner proof: 640 bytes, 19.7ms prove time (8-step Poseidon-like circuit)
- Folding: ~250ms per fold step, 10s Groth16 decider compression
- Binary tree: ~60s per level (halo2 accumulation circuit is 500K-1M constraints)
- SnarkPack: O(log N) overhead but cannot produce recursive aggregation

## Trade-offs Noted
- Folding (ProtoGalaxy) vs Accumulation (snark-verifier): folding is 2x cheaper gas
  but requires Groth16 trusted setup for decider circuit
- Binary tree arity: k=2 maximizes parallelism but deepens tree;
  k=4-8 reduces depth but increases per-node circuit size
- SnarkPack is fastest to aggregate (200ms for N=8) but has highest gas (450K)

## Risks
- Sonobe library is experimental, not audited
- Sirius (Snarkify) was archived March 2025 -- halo2-native folding tooling is limited
- Groth16 decider introduces per-circuit trusted setup (one-time but still ceremony)

## Literature Index
- 27 sources in findings.md covering all major approaches
- Most relevant production system: Scroll (halo2-KZG, same as our stack)
- Most relevant folding paper: ProtoGalaxy (Eagen, Gabizon 2023)
