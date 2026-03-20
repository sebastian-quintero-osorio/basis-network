Implementa la especificacion verificada de migracion a PLONK (halo2-KZG).

SAFETY LATCH: TLC log en implementation-history/prover-plonk-migration/tlc-evidence/ muestra PASS (3.98M distinct states).

CONTEXTO:
- TLA+ spec: implementation-history/prover-plonk-migration/specs/PlonkMigration.tla
- Scientist research: implementation-history/prover-plonk-migration/research/findings.md
- Scientist code: implementation-history/prover-plonk-migration/research/code/ (halo2_bench.rs, groth16_bench.rs)
- Existing witness gen: zkl2/prover/witness/ (Rust)
- Existing contracts: zkl2/contracts/contracts/BasisRollup.sol
- Decision: halo2-KZG (Axiom fork) selected for BN254 field compatibility

QUE IMPLEMENTAR:

1. zkl2/prover/circuit/ (Rust, halo2-KZG):
   - circuit.rs: Main PLONK circuit definition with custom gates for EVM operations
   - gates.rs: Custom gates (AddGate, MulGate, PoseidonGate, MemoryGate, StackGate)
   - columns.rs: Advice, instance, and fixed column definitions
   - prover.rs: Proof generation pipeline (keygen, prove, verify)
   - verifier.rs: Proof verification (matches on-chain verifier)
   - srs.rs: Universal SRS management (KZG setup)
   - types.rs: Shared types and error handling
   - lib.rs: Module exports
   - tests.rs: Comprehensive test suite

   KEY INVARIANTS FROM TLA+:
   - MigrationSafety: no batch lost during migration
   - BackwardCompatibility: Groth16 accepted during dual period
   - Soundness: no false positives
   - NoGroth16AfterCutover: Groth16 rejected after PLONK-only phase

2. zkl2/contracts/contracts/BasisVerifier.sol (Solidity 0.8.24, evmVersion cancun):
   - Dual verification support (Groth16 + PLONK during migration period)
   - PLONK-only verification after cutover
   - Migration phase management (groth16_only -> dual -> plonk_only)
   - Rollback capability
   - Integration with BasisRollup.sol

3. Tests:
   - PLONK circuit: prove + verify for simple EVM operations (ADD, MUL, storage R/W)
   - Custom gates: constraint reduction verification
   - Dual verification: both proof types accepted during dual period
   - Migration cutover: Groth16 rejected after PLONK-only phase
   - Rollback: migration rollback preserves batch integrity
   - Adversarial: invalid proof rejection, malformed proof, replay

4. ADVERSARIAL-REPORT.md
5. Session log

NO hagas commits. Comienza con /implement
