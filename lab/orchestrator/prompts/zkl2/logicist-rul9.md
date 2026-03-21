Formaliza la investigacion sobre migracion a PLONK en TLA+.

Unidad: plonk-migration. Materiales en research-history/2026-03-plonk-migration/0-input/.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19

Formaliza las propiedades del proof system como axiomas. Verifica que cambiar de Groth16 a PLONK (halo2-KZG) no rompe invariantes del sistema (Soundness, Completeness, Zero-Knowledge).

Formaliza el proceso de migracion:
- Periodo de verificacion dual (ambos proof systems aceptados)
- Corte a PLONK-only despues de periodo dual
- Invariantes:
  - MigrationSafety: ningun batch queda sin verificar durante migracion
  - BackwardCompatibility: proofs Groth16 existentes siguen siendo verificables durante periodo dual
  - Soundness: el cambio de proof system no introduce falsos positivos
  - Completeness: proofs validos son aceptados por ambos verificadores
  - DualPeriodTermination: el periodo dual eventualmente termina (liveness)

Model check con 3 empresas, 4 batches (2 Groth16, 2 PLONK), simular:
- Intento de submit durante transicion
- Batch sin proof durante migracion
- Groth16 proof despues del corte
- Rollback de migracion si fallo detectado

Comienza con /1-formalize
