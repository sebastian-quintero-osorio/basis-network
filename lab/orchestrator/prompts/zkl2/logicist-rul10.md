Formaliza la investigacion sobre agregacion de proofs en TLA+.

Unidad: proof-aggregation. Materiales en research-history/2026-03-proof-aggregation/0-input/.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19

Formaliza AggregateProof(proof1, ..., proofN) -> aggregatedProof.

Invariantes:
- AggregationSoundness: proof agregado valido sii todos los proofs componentes son validos
- IndependencePreservation: fallo de un proof de empresa no invalida los demas
- OrderIndependence: el resultado de la agregacion es independiente del orden de inputs
- GasMonotonicity: el costo por empresa disminuye con N

Model check con 3 empresas, 2 proofs cada una, 1 agregacion. Simular:
- Proof invalido en posicion 2
- Intento de incluir proof duplicado
- Agregacion parcial (solo 2 de 3 empresas)
- Verificacion del proof agregado en L1

Comienza con /1-formalize
