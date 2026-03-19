Verifica la implementacion del Data Availability Committee contra su especificacion TLA+.

CONTEXTO:
- Target: validium, Fecha: 2026-03-18, Unidad: data-availability

INPUTS:
1. TLA+ spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla
2. TypeScript impl: validium/node/src/da/ (shamir.ts, dac-node.ts, dac-protocol.ts)
3. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en validium/proofs/units/2026-03-data-availability/:
0-input-spec/, 0-input-impl/, 1-proofs/ (Common.v, Spec.v, Impl.v, Refinement.v), 2-reports/

ENFOQUE:
- Probar DataAvailability: datos recuperables si 2/3 atestan
- Probar Privacy: ningun nodo individual reconstruye datos (Shamir threshold)
- Modelar protocolo de attestation como sistema distribuido con mensajes

SESSION LOG: lab/4-prover/sessions/2026-03-18_data-availability.md
NO hagas commits. Comienza con /verify
