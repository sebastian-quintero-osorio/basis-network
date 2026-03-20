Verifica la implementacion de la migracion a PLONK contra su especificacion TLA+.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: plonk-migration

INPUTS:
1. TLA+ spec: verification-history/2026-03-plonk-migration/specs/PlonkMigration.tla
2. Rust impl: verification-history/2026-03-plonk-migration/impl/ (circuit.rs, gates.rs, columns.rs, prover.rs, verifier.rs, srs.rs, types.rs, lib.rs)
3. Solidity: verification-history/2026-03-plonk-migration/impl/BasisVerifier.sol
4. TLC evidence: verification-history/2026-03-plonk-migration/tlc-evidence/
5. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-plonk-migration/

ENFOQUE:
- Probar que la migracion preserva Soundness: el cambio de proof system no introduce falsos positivos
- Probar MigrationSafety: ningun batch sin verificar durante migracion
- Probar BackwardCompatibility: Groth16 proofs aceptados durante periodo dual
- Probar NoGroth16AfterCutover: Groth16 rechazado despues del corte
- Modelar proof systems como verificadores abstractos con propiedades Soundness/Completeness
- Modelar fases de migracion como transiciones de estado

SESSION LOG: lab/4-prover/sessions/2026-03-19_plonk-migration.md
NO hagas commits. Comienza con /verify
