# Phase 1: Formalization Notes -- Production DAC

> Unit: production-dac
> Target: zkl2
> Date: 2026-03-19
> Agent: The Logicist
> Extends: validium/specs/units/2026-03-data-availability/ (RU-V6)

---

## 1. Research-to-Spec Mapping

| Research Element | Source | TLA+ Element |
|-----------------|--------|--------------|
| Hybrid AES+RS+Shamir dispersal | REPORT.md Section 8.1, dac.go:152-238 | `DistributeChunks(b)` |
| KZG chunk verification | REPORT.md Section 4 | `VerifyChunk(n, b)` |
| ECDSA/BLS attestation | dac.go:361-385, REPORT.md Section 8.3 | `NodeAttest(n, b)` |
| Malicious chunk corruption | REPORT.md Section 8.2 | `CorruptChunk(n, b)` |
| Certificate production (threshold) | dac.go:222-234, REPORT.md Section 2.2 | `ProduceCertificate(b)` |
| AnyTrust fallback | REPORT.md INV-DA-P5 | `TriggerFallback(b)` |
| Three-step recovery (RS+Shamir+AES) | dac.go:256-327, erasure.go:141-188, shamir.go:89-141 | `RecoverData(b, S)` |
| Node crash/recovery | REPORT.md Section 11.5 | `NodeFail(n)`, `NodeRecover(n)` |
| Data recoverability (5-of-7) | REPORT.md INV-DA-P2 | `DataRecoverability` |
| Attestation liveness | REPORT.md INV-DA-P4 | `AttestationLiveness` |
| Erasure soundness (commitment check) | REPORT.md INV-DA-P1 | `ErasureSoundness` |
| Enterprise privacy (AES+Shamir) | REPORT.md INV-DA-P3 | `Privacy` |
| Fallback safety | REPORT.md INV-DA-P5 | `EventualFallback` |

## 2. Extensions from RU-V6

The ProductionDAC specification extends the Validium RU-V6 DataAvailability module in five dimensions:

### 2.1 Erasure Coding (RS replaces Shamir for data)

RU-V6 used Shamir SSS for both data and key distribution (3.87x storage overhead). ProductionDAC uses Reed-Solomon (5,7) for data chunks (1.4x overhead) with Shamir reserved for the 32-byte AES key. The TLA+ variable `distributedTo` replaces `shareHolders` and represents nodes that received the full package {RS chunk, Shamir key share, KZG proof}.

### 2.2 KZG Verification Gate

New action `VerifyChunk(n, b)` models the KZG polynomial commitment verification step between distribution and attestation. A node must verify its RS chunk against the commitment before attesting. This is absent in RU-V6 (which had no dispersal integrity check).

Guard: `n \notin chunkCorrupted[b]` -- a corrupted chunk fails KZG verification and blocks attestation.

### 2.3 Explicit Corruption Model

New action `CorruptChunk(n, b)` with variable `chunkCorrupted`. In RU-V6, corruption was implicit in RecoverData (any malicious node = corruption). In ProductionDAC, corruption is an explicit, nondeterministic action that:

- Can occur before or after verification (different consequences)
- Before verification: KZG blocks attestation
- After attestation: recovery with corrupted chunk detected by commitment check
- Only malicious nodes can corrupt; only before recovery

### 2.4 Strong Fairness for Verification

RU-V6 required only SF on NodeAttest (honest nodes). ProductionDAC additionally requires SF on VerifyChunk for honest nodes, because the two-step gate (verify then attest) means crashes can block verification in the same way they block attestation.

Initial formalization attempt used WF for VerifyChunk. TLC found a counterexample: honest nodes trapped in crash/recover loops without ever verifying. Corrected to SF.

### 2.5 Two-Phase Integrity

The specification models two integrity check points:
1. KZG check at dispersal (VerifyChunk gate)
2. Commitment hash check at recovery (RecoverData outcome)

## 3. Model Checking Results

### 3.1 Safety Verification (7 nodes, 2 malicious, 5-of-7 threshold)

Configuration: MC_ProductionDAC with MC_Nodes = {n1..n7}, MC_Malicious = {n6, n7}, MC_Threshold = 5, MC_Batches = {b1}.

| Metric | Value |
|--------|-------|
| States generated | 141,526,225 |
| Distinct states | 16,882,176 |
| Depth | 27 |
| Time | 5 min 9 sec |
| Workers | 4 |
| Result | **ALL 8 INVARIANTS PASS** |

Invariants verified:
1. TypeOK -- PASS
2. CertificateSoundness -- PASS
3. DataRecoverability -- PASS
4. ErasureSoundness -- PASS
5. Privacy -- PASS
6. RecoveryIntegrity -- PASS
7. AttestationIntegrity -- PASS
8. VerificationIntegrity -- PASS

### 3.2 Liveness Verification (5 nodes, 2 malicious, 3-of-5 threshold)

Reduced model for temporal property checking (791K state SCC analysis impractical on full 7-node model).

| Metric | Value |
|--------|-------|
| States generated | 2,365,825 |
| Distinct states | 395,520 |
| BFS depth | 21 |
| Interim temporal check (43K states) | **PASS** (6 sec) |
| Final temporal check (791K states) | **PASS** (9 min 52 sec) |
| Total time | 10 min 38 sec |

Properties checked:
1. AttestationLiveness -- **PASS**
2. EventualFallback -- **PASS**

### 3.3 Counterexamples Found and Resolved

**CE-1: WF insufficient for VerifyChunk (liveness violation)**
- Trace: Distribute -> honest nodes trapped in NodeFail/NodeRecover loop -> never verify
- Root cause: WF_vars(VerifyChunk) requires continuous enablement; crashes intermittently disable
- Fix: Changed to SF_vars(VerifyChunk) for honest nodes
- Justification: KZG verification is a fast local operation (~10 ms) that completes between crash/recovery episodes; SF models this correctly

**CE-2: ErasureSoundness violated with sub-threshold recovery (safety violation)**
- Trace: Distribute -> CorruptChunk(n6) -> ProduceCertificate -> RecoverData({n6}) -> "failed"
- Root cause: invariant expected "corrupted" but got "failed" because |S| < Threshold
- Fix: Added `Cardinality(recoveryNodes[b]) >= Threshold` to ErasureSoundness antecedent
- Justification: RS decoding is impossible with < k chunks regardless of corruption; "failed" is the correct outcome

**CE-3: Post-recovery corruption violates ErasureSoundness (safety violation)**
- Trace: Distribute -> Attest -> Certificate -> RecoverData({n1..n4,n6}) -> "success" -> CorruptChunk(n6) -> invariant fails
- Root cause: recovery succeeded with valid chunks, then n6 corrupted post-recovery; invariant checks current chunkCorrupted against past recoveryNodes
- Fix: Added `recoverState[b] = "none"` guard to CorruptChunk
- Justification: post-recovery corruption is semantically irrelevant (data already recovered and stored elsewhere)

## 4. Assumptions

1. **Honest disperser**: The entity that encrypts, encodes, and distributes is not adversarial. All distributed chunks are initially valid. Malicious disperser model (invalid encoding) is left for future work.
2. **Persistent storage**: Nodes retain received chunks and key shares across crashes (consistent with Node.stored map in dac.go).
3. **Single recovery attempt**: One recovery per batch. Retry with different subsets is an implementation detail not modeled.
4. **Corruption abstraction**: `chunkCorrupted` covers both RS chunk corruption and Shamir key share corruption (either one causes commitment mismatch at recovery).
5. **Atomic distribution**: All online nodes receive their packages in a single step (no partial distribution).

## 5. Reproduction Instructions

### Safety (8 invariants, 7 nodes)
```bash
cd zkl2/specs/units/2026-03-production-dac/1-formalization/v0-analysis/experiments/ProductionDAC
mkdir -p _build && cp ../../../v0-analysis/specs/ProductionDAC/ProductionDAC.tla MC_ProductionDAC.tla MC_ProductionDAC_safety.cfg _build/
mv _build/MC_ProductionDAC_safety.cfg _build/MC_ProductionDAC.cfg
cd _build && java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_ProductionDAC -workers 4
```

### Liveness (2 temporal properties, 5 nodes)
```bash
cd _build_liveness
java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_ProductionDAC_liveness -workers 4
```

## 6. Open Issues

1. **Liveness verified on reduced model**: Temporal properties verified on 5-node model (395K distinct states). Full 7-node temporal checking is impractical (~10M+ states for SCC analysis).
2. **Malicious disperser**: Current model assumes honest disperser. A model with adversarial encoding (invalid RS chunks at distribution time) would exercise the KZG verification path more thoroughly.
3. **Multiple recovery attempts**: The model allows one recovery per batch. Real implementations retry with different node subsets when corruption is detected.
4. **KZG commitment verification on-chain**: The on-chain verification path (BasisDAC.sol checking KZG proofs) is not explicitly modeled. The TLA+ spec models verification as a protocol gate, not a smart contract interaction.
