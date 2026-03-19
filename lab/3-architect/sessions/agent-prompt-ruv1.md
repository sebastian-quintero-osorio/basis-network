Implementa la especificacion verificada del Sparse Merkle Tree.

CONTEXTO:
- Los materiales verificados del Logicist estan en validium/specs/units/2026-03-sparse-merkle-tree/
- La especificacion TLA+ esta en 1-formalization/v0-analysis/specs/SparseMerkleTree/SparseMerkleTree.tla
- El TLC log (Certificate of Truth) esta en 1-formalization/v0-analysis/experiments/SparseMerkleTree/MC_SparseMerkleTree.log -- VERIFICAR QUE DICE "No error has been found"
- El codigo de referencia del Scientist esta en 0-input/code/smt-implementation.ts
- El destino del codigo de produccion es validium/node/src/state/
- Target: validium (MVP)
- Fecha: 2026-03-18

SAFETY LATCH (OBLIGATORIO):
1. Lee el TLC log y verifica que dice "Model checking completed. No error has been found."
2. Si NO dice eso, ABORTA y reporta: "Input validation failed: Specification not proven."
3. Solo si PASS, procede con la implementacion.

ESPECIFICACION TLA+ VERIFICADA:
- Operaciones: Insert(k,v), Delete(k), ProofSiblings(e,k), VerifyProofOp(root, leafHash, siblings, pathBits)
- Invariantes VERIFICADOS:
  - ConsistencyInvariant: root = ComputeRoot(entries) -- la raiz es deterministica
  - SoundnessInvariant: no false-positive proof verification
  - CompletenessInvariant: toda posicion tiene un proof valido
- Hash: Poseidon 2-to-1 sobre campo BN128

QUE IMPLEMENTAR:

1. CLASE SparseMerkleTree en validium/node/src/state/sparse-merkle-tree.ts:
   - Usar Poseidon de circomlibjs
   - Toda la aritmetica sobre campo BN128 (p = 21888242871839275222246405745257275088548364400416034343698204186575808495617)
   - insert(key: bigint, value: bigint): Promise<bigint> -- retorna new root
   - update(key: bigint, value: bigint): Promise<bigint> -- retorna new root
   - delete(key: bigint): Promise<bigint> -- retorna new root
   - getProof(key: bigint): MerkleProof
   - verifyProof(root: bigint, key: bigint, leafHash: bigint, proof: MerkleProof): boolean
   - static verifyProofStatic(...): verificacion standalone
   - serialize() / deserialize(): para persistencia
   - Cada funcion debe referenciar la accion TLA+ correspondiente con tag:
     // [Spec: validium/specs/units/2026-03-sparse-merkle-tree/SparseMerkleTree.tla]

2. TYPES en validium/node/src/state/types.ts:
   - MerkleProof interface
   - SMTStats interface
   - FieldElement type (branded bigint)

3. INDEX en validium/node/src/state/index.ts:
   - Export principal del modulo

4. TESTS en validium/node/src/state/__tests__/sparse-merkle-tree.test.ts:
   - Tests unitarios exhaustivos:
     - Insert y verificar root cambio
     - Insert multiple entries y verificar consistency
     - Delete y verificar root vuelve a estado anterior
     - GetProof y VerifyProof roundtrip
     - Non-membership proofs (key no existente)
   - Tests ADVERSARIALES:
     - Proof falsificado (siblings incorrectos)
     - Valor incorrecto en proof
     - Root incorrecto
     - Entradas duplicadas (mismo key con diferente value)
     - Arbol vacio (proofs para arbol sin entradas)
     - Overflow de profundidad (key > 2^32)
     - Proofs para entradas inexistentes

5. ADVERSARIAL-REPORT.md en validium/tests/adversarial/sparse-merkle-tree/:
   - Summary, Attack Catalog, Findings, Verdict

6. PACKAGE.JSON en validium/node/:
   - Si no existe, crearlo con: typescript, circomlibjs, jest, ts-jest, @types/jest
   - tsconfig.json con strict: true
   - Scripts: build, test, test:coverage

CALIDAD:
- TypeScript strict (strict: true, NO any type)
- Todos los tests deben PASAR (ejecutar npx jest)
- JSDoc en toda funcion publica
- No emojis, no fluff, precision only
- Cada decision arquitectural documentada

GIT:
NO hagas commits, el orquestador se encarga.

SESSION LOG:
Escribe lab/3-architect/sessions/2026-03-18_sparse-merkle-tree.md al finalizar.

Comienza con /implement
