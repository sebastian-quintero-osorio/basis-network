Formaliza la investigacion sobre Sparse Merkle Trees en una especificacion TLA+.

CONTEXTO:
- La unidad de investigacion es sparse-merkle-tree
- Los materiales del Scientist estan en validium/specs/units/2026-03-sparse-merkle-tree/0-input/
- El target es validium (MVP)
- Fecha: 2026-03-18

MATERIALES DISPONIBLES EN 0-input/:
- README.md: contexto y objetivos de formalizacion
- REPORT.md: findings completos del Scientist (18 referencias, benchmarks reales)
- code/smt-implementation.ts: implementacion de referencia del SMT (SparseMerkleTree class)
- code/smt-benchmark.ts: suite de benchmarks
- results/: resultados de benchmarks JSON

OPERACIONES A FORMALIZAR:
1. Insert(key, value) -- inserta o actualiza un par key-value en el arbol
2. Update(key, value) -- actualiza un valor existente (equivalente a Insert)
3. Delete(key) -- elimina una entrada (equivale a Insert con value = 0)
4. GetProof(key) -- genera un Merkle proof para una key
5. VerifyProof(root, key, value, proof) -- verifica un Merkle proof

INVARIANTES CRITICOS:
1. ConsistencyInvariant: la raiz siempre refleja el contenido real del arbol. Dos arboles con las mismas entradas DEBEN tener la misma raiz.
2. SoundnessInvariant: un proof invalido NUNCA es aceptado como valido. Si un proof verifica, el par key-value EXISTE en el arbol.
3. CompletenessInvariant: toda entrada existente tiene un proof valido. Si key-value esta en el arbol, GetProof(key) produce un proof que VerifyProof acepta.

MODEL CHECK:
- Arbol de profundidad 4 (2^4 = 16 posibles hojas)
- 8 entradas maximo
- Claves y valores: elementos de un campo finito pequeno (modelar como enteros 0..15)
- Este espacio finito es suficiente para exponer bugs sin explosion de estados
- TLC debe terminar con PASS

ESTRUCTURA DE OUTPUT (en validium/specs/units/2026-03-sparse-merkle-tree/):
```
1-formalization/
  v0-analysis/
    specs/SparseMerkleTree/
      SparseMerkleTree.tla       -- Especificacion principal
    experiments/SparseMerkleTree/
      MC_SparseMerkleTree.tla    -- Instancia del modelo (constantes finitas)
      MC_SparseMerkleTree.cfg    -- Configuracion de TLC
      MC_SparseMerkleTree.log    -- Output de TLC (certificado de verdad)
    PHASE-1-FORMALIZATION_NOTES.md
    PHASE-2-AUDIT_REPORT.md
```

PROTOCOLO DE TRAZABILIDAD:
Cada definicion TLA+ debe tener un comentario [Source: 0-input/REPORT.md, Section X] mapeandola a la fuente.

REGLAS:
- Lee TODOS los materiales de 0-input/ ANTES de escribir una sola linea de TLA+
- NUNCA modifiques archivos en 0-input/ -- son READ-ONLY
- Si la fuente es insuficiente para formalizar, reporta: "Input validation failed"
- NUNCA debilites un invariante para que el model checking pase
- Si TLC falla, analiza el counterexample como un descubrimiento valioso
- Si v0 falla: crea v1-fix/ con la correccion y reportes PHASE-4 y PHASE-5

HERRAMIENTAS:
- Para ejecutar TLC: busca java en el sistema y ejecuta TLC directamente. Si no encuentras tla2tools.jar, descargalo de https://github.com/tlaplus/tlaplus/releases o instala via npm (tla-toolbox-runner o similar).
- Alternativa: escribe el spec y ejecuta TLC manualmente via java -cp tla2tools.jar tlc2.TLC

SESSION LOG:
Escribe lab/2-logicist/sessions/2026-03-18_sparse-merkle-tree.md al finalizar.

NO hagas commits de git, el orquestador se encarga.

Comienza con /1-formalize
