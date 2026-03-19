Verifica la implementacion del Witness Generator contra su especificacion TLA+.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: witness-generation

INPUTS:
1. TLA+ spec: zkl2/specs/units/2026-03-witness-generation/.../specs/WitnessGeneration/WitnessGeneration.tla
2. Rust impl: zkl2/prover/witness/src/ (generator.rs, arithmetic.rs, storage.rs, call_context.rs, types.rs, error.rs)
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-witness-generation/

ENFOQUE:
- Probar Completeness: witness contiene toda info necesaria
- Probar Soundness: witness invalido -> proof invalido
- Probar Determinism: mismo trace -> mismo witness
- Modela Rust Result<T,E> como option type

SESSION LOG: lab/4-prover/sessions/2026-03-19_witness-generation.md
NO hagas commits. Comienza con /verify
