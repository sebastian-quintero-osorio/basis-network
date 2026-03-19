Implementa la especificacion verificada del DAC de produccion con erasure coding para el zkEVM L2 empresarial.

SAFETY LATCH: TLC log en implementation-history/node-production-dac/tlc-evidence/ muestra PASS (16.8M distinct states, 141M states generated).

CONTEXTO:
- TLA+ spec: implementation-history/node-production-dac/specs/ProductionDAC.tla
- Scientist research + prototype: implementation-history/node-production-dac/research/
- Scientist Go prototype: implementation-history/node-production-dac/research/code/ (erasure/, dac/, shamir/, main.go)
- TLC evidence: implementation-history/node-production-dac/tlc-evidence/MC_ProductionDAC_safety.log + MC_ProductionDAC_liveness.log
- Destinos: zkl2/node/da/ (Go DAC module), zkl2/contracts/contracts/BasisDAC.sol (attestation on-chain)
- Existing contracts: zkl2/contracts/contracts/BasisRollup.sol, BasisBridge.sol, IEnterpriseRegistry.sol

QUE IMPLEMENTAR:

1. zkl2/node/da/ (Go, production-grade):
   - dac_node.go: DACNode with persistent storage, chunk management, KZG verification
   - erasure.go: Reed-Solomon (5,7) encoder/decoder using Go standard library or klauspost/reedsolomon
   - shamir.go: Shamir (5,7) secret sharing for AES key distribution (BN254 field)
   - attestation.go: Attestation protocol (ECDSA signatures, bitmap verification)
   - certificate.go: DACCertificate production (threshold aggregation, on-chain submission)
   - recovery.go: Three-step recovery (RS decode -> Shamir key recovery -> AES-GCM decrypt -> commitment verify)
   - fallback.go: AnyTrust fallback (validium -> rollup mode when threshold unreachable)
   - types.go: Shared types and interfaces
   - dac_test.go: Comprehensive test suite

   KEY INVARIANTS FROM TLA+ (MUST be preserved):
   - CertificateSoundness: valid cert only when >= 5 attestations
   - DataRecoverability: recovery succeeds from any 5 uncorrupted nodes
   - ErasureSoundness: corrupted chunks detected by commitment check
   - Privacy: successful recovery requires >= Threshold participants
   - RecoveryIntegrity: success => all contributing nodes have authentic data
   - AttestationIntegrity: only KZG-verified nodes can attest
   - VerificationIntegrity: KZG verification requires prior distribution

   ARCHITECTURE (from TLA+ spec):
   - Disperse: encrypt(AES-256-GCM) -> RS-encode(5,7) -> Shamir-share(key, 5-of-7) -> KZG-commit -> distribute
   - Verify: node verifies RS chunk against KZG polynomial commitment
   - Attest: node signs attestation (only after KZG verification)
   - Certify: aggregate >= k attestations into DACCertificate
   - Recover: collect k chunks -> RS-decode -> collect k key shares -> Shamir-recover(key) -> AES-decrypt -> verify hash

2. zkl2/contracts/contracts/BasisDAC.sol (Solidity 0.8.24, evmVersion: cancun):
   - Committee member registration and rotation
   - On-chain attestation verification (signature count >= k, no duplicates, valid committee members)
   - DACCertificate submission and storage
   - Integration with BasisRollup.sol for batch finalization
   - AnyTrust fallback trigger
   - Events for indexing

3. Tests (comprehensive + adversarial):
   - Recovery from 5 of 7 nodes (all uncorrupted)
   - Recovery with 2 nodes offline
   - Recovery with 1 malicious node corrupting chunk post-attestation
   - Attestation with only 4 nodes (should fail threshold)
   - AnyTrust fallback trigger (< 5 nodes received distribution)
   - Double-attestation prevention
   - Committee rotation
   - KZG verification failure (corrupted chunk before attestation)
   - Concurrent batch processing
   - Full E2E: disperse -> attest -> certify -> recover cycle

4. ADVERSARIAL-REPORT.md with all vectors tested

5. Session log en lab/3-architect/sessions/2026-03-19_production-dac.md

QUALITY REQUIREMENTS:
- Go: idiomatic, no unwrap-equivalents, proper error handling with wrapped errors
- Solidity: NatSpec on all public/external functions, evmVersion cancun
- Every invariant from the TLA+ spec must map to a test case
- Code must integrate with existing zkl2/node/pipeline/ orchestrator

NO hagas commits. Comienza con /implement
