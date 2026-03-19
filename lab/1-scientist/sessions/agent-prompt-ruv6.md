Investiga modelos de Data Availability Committee (DAC) para un sistema validium empresarial.

HIPOTESIS: Un DAC de 3 nodos con asuncion de minoria honesta (2-of-3) puede atestar disponibilidad de datos de batch en < 2 segundos, con almacenamiento gestionado por la empresa, sin exponer datos a ningun nodo individual, y con mecanismo de recovery si un nodo falla.

CONTEXTO:
- El sistema validium procesa datos empresariales privados (mantenimiento industrial, ERP comercial)
- Los datos NUNCA pueden ser publicos
- Ya tenemos: SMT (RU-V1), state transition circuit (RU-V2), batch aggregation (RU-V4)
- Target: validium (MVP), Fecha: 2026-03-18

TAREAS:

1. CREAR ESTRUCTURA: validium/research/experiments/2026-03-18_data-availability/
   hypothesis.json, state.json, journal.md, findings.md, code/, results/, memory/session.md

2. LITERATURE REVIEW:
   - Polygon Avail DAC, EigenDA, Celestia (comparar modelos)
   - Secret sharing: Shamir's Secret Sharing (SSS)
   - Erasure coding: Reed-Solomon
   - Attestation protocols
   - Honest minority vs honest majority en contexto empresarial

3. CODIGO EXPERIMENTAL:
   - TypeScript prototype de DACNode (almacena shares)
   - DACProtocol (attestation y recovery)
   - Shamir Secret Sharing implementation (k-of-n threshold)
   - Benchmark: latencia de attestation, overhead de storage, tiempo de recovery

4. EJECUTAR BENCHMARKS

5. SESSION LOG: lab/1-scientist/sessions/2026-03-18_data-availability.md

NO hagas commits. Comienza con /experiment
