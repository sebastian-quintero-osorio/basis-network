# Verification Summary: Production DAC (2026-03-production-dac)

## Verdict: PASS

All 8 safety invariants of the Production DAC protocol are machine-checked
inductive invariants. Zero `Admitted` statements. All proofs compile under
Rocq Prover 9.0.1.

## Scope

| Item | Detail |
|------|--------|
| **Target** | zkl2 (Enterprise zkEVM L2) |
| **Unit** | 2026-03-production-dac |
| **Spec** | ProductionDAC.tla (493 lines) |
| **Implementation** | Go (10 files) + Solidity (BasisDAC.sol) |
| **TLC Evidence** | Safety: 141.5M states PASS, Liveness: 2.3M states PASS |
| **Coq Development** | 4 files, ~1360 lines, 0 Admitted |

## Theorems Proved

### Primary Safety Invariants (requested)

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 1 | `certificate_soundness_holds` | `certSt[b] = Valid => card(attested[b]) >= Threshold` | PROVED |
| 2 | `data_recoverability_holds` | `recoveryNodes subset (dist \ corrupt) /\ card >= Threshold => recoverSt = Success` | PROVED |
| 3 | `erasure_soundness_holds` | `card >= Threshold /\ inter(recoveryNodes, corrupt) non-empty => recoverSt = Corrupted` | PROVED |
| 4 | `privacy_holds` | `recoverSt = Success => card(recoveryNodes) >= Threshold` | PROVED |

### Supporting Safety Invariants

| # | Theorem | Statement | Status |
|---|---------|-----------|--------|
| 5 | `recovery_integrity_holds` | `recoverSt = Success => inter(recoveryNodes, corrupt) = empty` | PROVED |
| 6 | `attestation_integrity_holds` | `attested[b] subset chunkVerified[b]` | PROVED |
| 7 | `verification_integrity_holds` | `chunkVerified[b] subset distributedTo[b]` | PROVED |
| 8 | `no_recovery_before_dist_holds` | `distributedTo[b] = empty => recoverSt[b] = None` | PROVED |

### Cryptographic Property Theorems

| # | Theorem | Property |
|---|---------|----------|
| 9 | `rs_aes_data_recovery` | RS + AES-GCM composition enables data recovery from k authentic chunks |
| 10 | `shamir_threshold_property` | Shamir (k,n)-SS: k shares recover, < k shares reveal nothing |
| 11 | `aes_integrity_detection` | AES-GCM detects tampering (wrong key -> decrypt fails) |

## Proof Architecture

```
Common.v (types, axiomatized finite sets, tactics)
    |
    v
Spec.v (TLA+ -> Coq: state, 9 actions, 8 invariants)
    |
    v
Impl.v (Go/Solidity model, crypto axioms: RS MDS, AES-GCM, Shamir)
    |
    v
Refinement.v (inductive invariant proofs, crypto property theorems)
```

## Proof Methodology

Each safety invariant is proved as an **inductive invariant**:

1. **Init**: Show `Init s -> Invariant s` (8 proofs, all by unfolding Init and
   observing empty sets / RecNone satisfy vacuous implications).

2. **Preservation**: Show `AllSafety s -> Next s s' -> Invariant s'` (8 proofs,
   each with 9 action cases). Most cases discharge via helper lemmas that
   handle "unchanged field" scenarios in 1-2 lines. Critical cases:
   - `ProduceCertificate` for CertificateSoundness: guard `card >= Threshold`
     directly establishes the invariant.
   - `RecoverData` for DataRecoverability/ErasureSoundness/Privacy/RecoveryIntegrity:
     case analysis on the three-way disjunction (failed/corrupted/success)
     matches each invariant's conditions.
   - `CorruptChunk` for RecoveryIntegrity: guard `recoverSt = RecNone`
     makes the invariant's antecedent false.

3. **Induction**: `Reachable s -> AllSafety s` by induction on the derivation.

## Cryptographic Modeling

| Primitive | Model | Key Axiom |
|-----------|-------|-----------|
| **Reed-Solomon (5,7)** | `rs_encode/rs_decode` with MDS correctness | Any k authentic chunks reconstruct original |
| **AES-256-GCM** | `aes_encrypt/aes_decrypt` with correctness + authenticity | Correct key decrypts; tampered ciphertext -> auth failure |
| **Shamir (5,7)-SS** | `shamir_split/shamir_recover` with threshold property | k shares recover secret; < k shares -> None |

## Trust Base

The proof trusts:
1. The Rocq/Coq kernel (type-checked proof terms)
2. 16 finite set axioms (standard mathematical properties, TLC-validated)
3. 8 cryptographic axioms (standard properties of RS, AES-GCM, Shamir)
4. 3 specification assumptions (threshold bounds, malicious subset of nodes)

## Correspondence to Implementation

| TLA+ Action | Go Implementation | Coq Action |
|-------------|-------------------|------------|
| `DistributeChunks` | `Committee.Disperse` (committee.go:41-148) | `Spec.DistributeChunks` |
| `VerifyChunk` | `DACNode.Verify` (dac_node.go:63-90) | `Spec.VerifyChunk` |
| `NodeAttest` | `DACNode.Attest` (dac_node.go:94-124) | `Spec.NodeAttest` |
| `CorruptChunk` | `DACNode.CorruptChunk` (dac_node.go:188-204) | `Spec.CorruptChunk` |
| `ProduceCertificate` | `Committee.ProduceCertificate` (certificate.go:13-62) | `Spec.ProduceCertificate` |
| `TriggerFallback` | `Committee.TriggerFallback` (fallback.go:33-45) | `Spec.TriggerFallback` |
| `RecoverData` | `Committee.Recover` (recovery.go:18-129) | `Spec.RecoverData` |
| `NodeFail` | `DACNode.SetOffline` (dac_node.go:39-45) | `Spec.NodeFail` |
| `NodeRecover` | `DACNode.SetOnline` (dac_node.go:33-37) | `Spec.NodeRecover` |

On-chain: `BasisDAC.sol:submitCertificate` enforces CertificateSoundness
(threshold check, member check, duplicate check, signature verification).
