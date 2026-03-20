Verifica la implementacion de agregacion de proofs contra su especificacion TLA+.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: proof-aggregation

INPUTS:
1. TLA+ spec: verification-history/2026-03-proof-aggregation/specs/ProofAggregation.tla
2. Rust impl: verification-history/2026-03-proof-aggregation/impl/ (aggregator.rs, pool.rs, tree.rs, verifier_circuit.rs, types.rs, lib.rs)
3. Solidity: verification-history/2026-03-proof-aggregation/impl/BasisAggregator.sol
4. TLC evidence: verification-history/2026-03-proof-aggregation/tlc-evidence/
5. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-proof-aggregation/

ENFOQUE:
- Probar AggregationSoundness: proof agregado valido sii todos los componentes son validos
- Probar IndependencePreservation: proofs validos nunca se pierden
- Probar OrderIndependence: resultado independiente del orden de inputs
- Modelar binary tree folding como reduccion asociativa

SESSION LOG: lab/4-prover/sessions/2026-03-19_proof-aggregation.md
NO hagas commits. Comienza con /verify
