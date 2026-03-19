Implementa la especificacion verificada de la State Database para el L2 zkEVM.

SAFETY LATCH: TLC log en zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/experiments/StateDatabase/MC_StateDatabase.log muestra PASS.

CONTEXTO:
- TLA+ spec: zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/specs/StateDatabase/StateDatabase.tla
- Scientist code: zkl2/specs/units/2026-03-state-database/0-input/code/ (Go SMT con gnark-crypto)
- Destino: zkl2/node/statedb/
- Target: zkl2 (produccion completa)
- Go esta instalado (Go 1.26.1)

QUE IMPLEMENTAR:

1. zkl2/node/statedb/smt.go:
   - SparseMerkleTree con Poseidon hash (gnark-crypto)
   - Insert, Update, Delete, GetProof, VerifyProof
   - BN254 field arithmetic

2. zkl2/node/statedb/state_db.go:
   - StateDB wrapping two-level SMT (account trie + storage tries)
   - CreateAccount, GetBalance, SetBalance, GetStorage, SetStorage
   - StateRoot computation

3. zkl2/node/statedb/account.go:
   - Account type: nonce, balance, storageRoot, codeHash

4. zkl2/node/statedb/types.go

5. Tests en zkl2/node/statedb/statedb_test.go:
   - Account creation, balance transfer, storage operations
   - AccountIsolation: ops on A don't affect B
   - StorageIsolation: contract A's storage isolated from B
   - Adversarial: invalid proofs, overflow, nonexistent accounts

6. ADVERSARIAL-REPORT.md en zkl2/tests/adversarial/state-database/

7. Session log: lab/3-architect/sessions/2026-03-19_state-database.md

NO hagas commits. Comienza con /implement
