Implementa la especificacion verificada del Witness Generator en Rust.

SAFETY LATCH: TLC log en zkl2/specs/units/2026-03-witness-generation muestra PASS.

CONTEXTO:
- TLA+ spec: zkl2/specs/units/2026-03-witness-generation/.../specs/WitnessGeneration/WitnessGeneration.tla
- Scientist Rust code: zkl2/specs/units/2026-03-witness-generation/0-input/code/src/
- Destino: zkl2/prover/witness/
- Target: zkl2 (produccion completa)
- Rust esta instalado (cargo disponible)

QUE IMPLEMENTAR:

1. zkl2/prover/witness/src/lib.rs -- library entry
2. zkl2/prover/witness/src/types.rs -- TraceEntry, WitnessRow, WitnessTable types
3. zkl2/prover/witness/src/generator.rs -- WitnessGenerator: consume trace, produce witness
4. zkl2/prover/witness/src/arithmetic.rs -- arithmetic opcode witness module
5. zkl2/prover/witness/src/storage.rs -- storage opcode witness module (Merkle proofs)
6. zkl2/prover/witness/src/call_context.rs -- CALL/CREATE witness module
7. zkl2/prover/Cargo.toml -- workspace setup

8. Tests: determinism, completeness, soundness, adversarial (invalid trace, missing fields)
9. ADVERSARIAL-REPORT.md en zkl2/tests/adversarial/witness-generation/
10. Session log: lab/3-architect/sessions/2026-03-19_witness-generation.md

CALIDAD:
- Rust idiomatico: Result<T, E>, no unwrap() en produccion
- Custom error types per module (thiserror)
- #[cfg(test)] mod tests en cada modulo
- Documentation con /// comments
- No unsafe

NO hagas commits. Comienza con /implement
