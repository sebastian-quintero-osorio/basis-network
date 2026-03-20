Genera tests de Hardhat para BasisDAC.sol.

CONTEXTO:
- BasisDAC.sol es el contrato de Data Availability Committee del zkl2
- Ya tiene 28 Go tests en zkl2/node/da/dac_test.go que verifican la logica off-chain
- Falta el archivo de tests Solidity (BasisDAC.test.ts) para verificar la logica on-chain
- Todos los demas contratos ya tienen tests: BasisRollup.test.ts, BasisBridge.test.ts, BasisVerifier.test.ts, BasisAggregator.test.ts, BasisHub.test.ts
- El proyecto Hardhat esta en zkl2/contracts/ con Solidity 0.8.24, evmVersion cancun

CONTRACT: zkl2/contracts/contracts/BasisDAC.sol (342 lines)
FEATURES:
- Committee management (addMember, removeMember, setThreshold, transferAdmin)
- Certificate submission with ECDSA signature verification (submitCertificate)
- AnyTrust fallback activation (activateFallback)
- Queries (isDataAvailable, hasCertificate, isFallback, committeeSize, getCommittee)

TLA+ INVARIANTS QUE DEBEN VERIFICARSE:
- CertificateSoundness: submitCertificate requiere >= threshold firmas validas
- AttestationIntegrity: solo miembros registrados pueden firmar
- No duplicate signers (bitmap check)
- AnyTrust fallback: activateFallback establece certState=2

DESTINO: zkl2/contracts/test/BasisDAC.test.ts

TESTS REQUERIDOS:
1. Deployment: constructor con threshold y members
2. Committee management: addMember, removeMember, setThreshold
3. Certificate submission: firmas validas ECDSA, threshold check
4. Invalid scenarios: insufficient signatures, non-member signer, duplicate signer
5. Fallback: activateFallback, double fallback rejection
6. Access control: onlyAdmin modifier
7. Query functions: isDataAvailable, hasCertificate, isFallback

PATRON: seguir el mismo estilo de los otros test files (ethers v6, chai expect).

NO hagas commits.
