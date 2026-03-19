Verifica la implementacion del DAC de produccion contra su especificacion TLA+.

CONTEXTO: Target: zkl2, Fecha: 2026-03-19, Unidad: production-dac

INPUTS:
1. TLA+ spec: verification-history/2026-03-production-dac/specs/ProductionDAC.tla
2. Go impl: verification-history/2026-03-production-dac/impl/ (types.go, committee.go, dac_node.go, erasure.go, shamir.go, attestation.go, certificate.go, recovery.go, fallback.go)
3. Solidity: verification-history/2026-03-production-dac/impl/BasisDAC.sol
4. TLC evidence: verification-history/2026-03-production-dac/tlc-evidence/
5. Coq: C:\Rocq-Platform~9.0~2025.08\bin\coqc

OUTPUT en zkl2/proofs/units/2026-03-production-dac/

ENFOQUE:
- Probar DataRecoverability: datos recuperables desde cualquier 5 de 7 nodos no corruptos
- Probar IntegrityVerification (ErasureSoundness): datos recuperados con nodos corruptos son detectados
- Probar CertificateSoundness: certificado valido solo con >= threshold attestations
- Probar Privacy: recovery exitoso requiere >= Threshold participantes
- Modelar erasure coding como funcion de codificacion/decodificacion con propiedades algebraicas
- Modelar AES-GCM como cifrado autenticado (decrypt corrupcion -> auth fail)
- Modelar Shamir SS con propiedad de threshold: k-1 shares revelan 0 info

SESSION LOG: lab/4-prover/sessions/2026-03-19_production-dac.md
NO hagas commits. Comienza con /verify
