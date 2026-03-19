Formaliza la investigacion sobre State Database (SMT Poseidon para EVM) en TLA+.

CONTEXTO:
- Unidad: state-database en zkl2/specs/units/2026-03-state-database/0-input/
- Target: zkl2, Fecha: 2026-03-19
- Reutilizar y EXTENDER la formalizacion de Validium RU-V1 (SparseMerkleTree.tla)
- La referencia de RU-V1 esta en validium/specs/units/2026-03-sparse-merkle-tree/
- TLC tools: lab/2-logicist/tools/tla2tools.jar

QUE FORMALIZAR:
- Extender el SMT de RU-V1 para EVM account model (account trie + storage trie per contract)
- Operaciones: CreateAccount, UpdateBalance, SetStorage, GetStorage, SelfDestruct
- INVARIANTES:
  - ConsistencyInvariant (heredado de RU-V1): root = ComputeRoot(entries)
  - AccountIsolation: operaciones en cuenta A no afectan cuenta B
  - StorageIsolation: storage de contrato A aislado de contrato B
  - BalanceConservation: transferencias conservan balance total
- MODEL CHECK: 3 accounts (1 EOA + 2 contracts), 2 storage slots, 3 operations

OUTPUT en zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/

SESSION LOG: lab/2-logicist/sessions/2026-03-19_state-database.md
NO hagas commits. Comienza con /1-formalize
