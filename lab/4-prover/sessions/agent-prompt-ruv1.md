Verifica la implementacion del Sparse Merkle Tree contra su especificacion TLA+.

CONTEXTO:
- Target: validium (MVP)
- Fecha: 2026-03-18
- Unidad: sparse-merkle-tree

INPUTS:
1. TLA+ spec: validium/specs/units/2026-03-sparse-merkle-tree/1-formalization/v0-analysis/specs/SparseMerkleTree/SparseMerkleTree.tla
2. TLC log (PASS): validium/specs/units/2026-03-sparse-merkle-tree/1-formalization/v0-analysis/experiments/SparseMerkleTree/MC_SparseMerkleTree.log
3. TypeScript implementation: validium/node/src/state/sparse-merkle-tree.ts
4. Type definitions: validium/node/src/state/types.ts

ESTRUCTURA DE OUTPUT:
Crear en validium/proofs/units/2026-03-sparse-merkle-tree/:

```
0-input-spec/     -- Snapshot READ-ONLY del TLA+ (copiar SparseMerkleTree.tla)
0-input-impl/     -- Snapshot READ-ONLY de la implementacion (copiar sparse-merkle-tree.ts, types.ts)
1-proofs/         -- Tus archivos Coq
  Common.v        -- Biblioteca estandar (tipos, tacticas)
  Spec.v          -- Traduccion fiel del TLA+ a Coq
  Impl.v          -- Modelo abstracto de la implementacion TypeScript
  Refinement.v    -- Prueba de que la implementacion refina la especificacion
2-reports/
  verification.log  -- Log de compilacion Coq
  SUMMARY.md        -- Resumen con veredicto: VERIFIED / INCOMPLETE / FAILED
```

QUE PROBAR:

1. Spec.v -- Traduccion fiel de SparseMerkleTree.tla a Coq:
   - Tipos: entries como funcion Key -> Value (con EMPTY como None)
   - Operaciones: insert, delete como transiciones de estado
   - Invariantes: ConsistencyInvariant, SoundnessInvariant, CompletenessInvariant
   - Hash modelado como funcion abstracta sobre Z (enteros modulo primo BN128)

2. Impl.v -- Modelo abstracto de sparse-merkle-tree.ts:
   - SparseMerkleTree como record Coq con nodes (Map), depth, entryCount
   - insert, delete, getProof, verifyProof como funciones Coq
   - Map modelado como lista de pares (key, value)

3. Refinement.v -- La prueba central:
   - Mapping functions: map_state que convierte Impl.State a Spec.State
   - Theorem refinement: para todo step de Impl, existe un step correspondiente de Spec
   - Enfocate en probar que insert y getProof preservan ConsistencyInvariant
   - Modela hashes Poseidon como funciones abstractas inyectivas

HERRAMIENTAS:
- Coq esta instalado en: C:\Rocq-Platform~9.0~2025.08\bin\coqc
- Ejecuta coqc directamente para compilar los archivos .v
- Compila en orden: Common.v -> Spec.v -> Impl.v -> Refinement.v

RIGOR:
- NO uses Admitted en la version final (solo durante desarrollo)
- Si no puedes probar un teorema, documenta por que y clasifica como INCOMPLETE
- Constructive proofs preferidos sobre classical
- Todo teorema debe tener un comentario explicando la estrategia de prueba

SESSION LOG:
Escribe lab/4-prover/sessions/2026-03-18_sparse-merkle-tree.md al finalizar.

GIT:
NO hagas commits, el orquestador se encarga.

Comienza con /verify
