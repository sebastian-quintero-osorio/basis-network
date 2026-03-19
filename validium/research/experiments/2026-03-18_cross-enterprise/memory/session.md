# Session Memory -- Cross-Enterprise Verification

## Key Decisions

- Three verification approaches: Sequential, Batched Pairing, Aggregated (Hub)
- MVP targets Sequential approach (simplest, < 2x overhead achievable)
- Cross-reference circuit: dual Merkle path verification + interaction predicate
- Privacy preserved: only state roots (already public) + interaction commitment exposed

## Literature Anchors

- SnarkPack (FC 2022): 8192 proofs in 8.7s, crossover at 32 proofs
- Nebra UPA (2024): 75-85% gas savings, formula: 350K/N + 7K gas/proof
- Groth16 gas: (181 + 6*L) kgas for L public inputs
- RU-V3 baseline: 285,756 gas per enterprise batch submission
- Constraint formula: 1,038 * (depth+1) * batchSize per Merkle path

## Design Constraints

- Groth16 proof aggregation NOT efficient below 32 proofs (SnarkPack crossover)
- For 2-10 enterprises, batched pairing verification is optimal
- Cross-reference circuit ~69K constraints = ~4.5s snarkjs, ~0.45s rapidsnark
