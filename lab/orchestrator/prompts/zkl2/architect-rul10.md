Implementa la especificacion verificada de agregacion de proofs.

SAFETY LATCH: TLC log en implementation-history/prover-aggregation/tlc-evidence/ muestra PASS.

CONTEXTO:
- TLA+ spec: implementation-history/prover-aggregation/specs/ProofAggregation.tla
- Scientist research: implementation-history/prover-aggregation/research/findings.md
- Existing circuit: zkl2/prover/circuit/ (Rust halo2-KZG from RU-L9)
- Existing contracts: zkl2/contracts/contracts/BasisVerifier.sol, BasisRollup.sol

QUE IMPLEMENTAR:

1. zkl2/prover/aggregator/ (Rust):
   - aggregator.rs: Binary tree accumulation pipeline (snark-verifier pattern)
   - tree.rs: Proof tree structure for N-proof aggregation
   - verifier_circuit.rs: Recursive verifier circuit (verifies inner proof inside outer circuit)
   - pool.rs: Proof pool management (collect from enterprises, deduplicate)
   - types.rs: Shared types
   - lib.rs: Module exports
   - tests.rs: Comprehensive test suite

   KEY INVARIANTS:
   - AggregationSoundness: aggregated proof valid iff ALL components valid
   - IndependencePreservation: valid proofs never lost
   - OrderIndependence: same components => same validity

2. zkl2/contracts/contracts/BasisAggregator.sol (Solidity 0.8.24, evmVersion cancun):
   - On-chain verification of aggregated proofs
   - Integration with BasisVerifier.sol for dual-mode support
   - Gas accounting (per-enterprise cost tracking)
   - Events for indexing

3. Tests:
   - Aggregation of 2, 4, 8 proofs
   - Invalid proof in middle position
   - Duplicate proof rejection
   - Partial aggregation (subset of enterprises)
   - Order independence verification
   - E2E: generate -> aggregate -> verify on-chain

4. ADVERSARIAL-REPORT.md
5. Session log

NO hagas commits. Comienza con /implement
