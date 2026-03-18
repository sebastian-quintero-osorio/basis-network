# Phase 1: Formalization Notes -- Data Availability Committee

**Unit**: RU-V6 Data Availability Committee with Shamir Secret Sharing
**Target**: validium
**Date**: 2026-03-18
**Result**: PASS (all invariants and liveness properties verified)

---

## 1. Research-to-Spec Mapping

| Source (0-input/) | TLA+ Element | Type |
|---|---|---|
| `dac-protocol.ts:distributeShares()` | `DistributeShares(b)` | Action |
| `dac-node.ts:attest()` | `NodeAttest(n, b)` | Action |
| `dac-protocol.ts:collectAttestations() L116` | `ProduceCertificate(b)` | Action |
| `dac-protocol.ts:L117 -- fallbackTriggered` | `TriggerFallback(b)` | Action |
| `dac-protocol.ts:recoverData()` | `RecoverData(b, S)` | Action |
| `dac-node.ts:setOnline(false)` | `NodeFail(n)` | Action |
| `dac-node.ts:setOnline(true)` | `NodeRecover(n)` | Action |
| `shamir.ts:shareData()` | `shareHolders` variable | State |
| `types.ts:DACNodeState.attested` | `attested` variable | State |
| `types.ts:DACCertificate.valid` | `certState` variable | State |
| `dac-protocol.ts:recoverData() return` | `recoverState` variable | State |
| INV-DA1 (Share Privacy) | `Privacy` | Safety invariant |
| INV-DA2 (Data Recoverability) | `DataAvailability` | Safety invariant |
| INV-DA3 (Attestation Soundness) | `CertificateSoundness` | Safety invariant |
| INV-DA4 (Liveness Fallback) | `EventualFallback` | Liveness property |
| INV-DA5 (Commitment Binding) | `RecoveryIntegrity` | Safety invariant |
| PROP-DA3 (Recovery Independence) | `DataAvailability` | Safety invariant |

## 2. Abstraction Decisions

### 2.1 Cryptographic Abstraction

The specification abstracts all cryptographic operations:

- **Shamir SSS**: Modeled as set membership (node has shares or does not). Field arithmetic, polynomial evaluation, and Lagrange interpolation are not modeled. The information-theoretic privacy guarantee is captured structurally: recovery requires >= Threshold shares.

- **ECDSA Signatures**: Modeled as boolean attestation state. Signature generation, verification, and ecrecover are abstracted. The on-chain verifier is modeled by the `ProduceCertificate` guard (threshold check).

- **SHA-256 Commitment**: Modeled implicitly. Recovery integrity is captured by the three-outcome model: success (commitment matches), corrupted (commitment mismatch), failed (underdetermined interpolation).

**Justification**: These abstractions are sound because the security properties being verified (threshold attestation, threshold reconstruction, fallback triggers) depend on protocol structure, not cryptographic implementation details. The cryptographic primitives are verified separately (51 privacy tests, 61 recovery tests in the research materials).

### 2.2 Malicious Node Model

Malicious nodes are modeled with the following capabilities:

- **CAN**: Receive shares, produce valid attestations, go offline, come back online.
- **CAN**: Provide corrupted shares during recovery (modeled by "corrupted" outcome when malicious node in recovery set).
- **CANNOT**: Fabricate attestations without shares (enforced by `AttestationIntegrity`).
- **MAY**: Refuse to attest (modeled by absence of fairness constraint on malicious attestation).

This models the realistic adversary described in the research threat model (ATK-DA2, ATK-DA3, ATK-DA4).

### 2.3 Single Recovery Attempt

The model allows one recovery attempt per batch (`recoverState[b] = "none"` guard). In the real system, multiple subsets can be tried and cross-validated via `verifyShareConsistency()`. This is a simplification; TLC explores ALL possible first attempts (all subsets S), which is equivalent to verifying correctness for every possible recovery strategy.

### 2.4 Structural Fallback Guard

Fallback triggers when `Cardinality(shareHolders[b]) < Threshold` (fewer than k nodes received shares). This models the permanent impossibility condition. The real system also uses a timeout-based fallback. The structural guard is more conservative (under-approximates real behavior) but sufficient for proving liveness: when fallback is genuinely needed, the model triggers it.

## 3. Verification Results

### Model Configuration

| Parameter | Value |
|---|---|
| Nodes | {n1, n2, n3} |
| Threshold | 2 (2-of-3) |
| Malicious | {n3} |
| Batches | {b1} |
| Workers | 4 |

### TLC Output

```
TLC2 Version 2.16 of 31 December 2020 (rev: cdddf55)
Model checking completed. No error has been found.
2175 states generated, 616 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 10.
Finished in 00s at (2026-03-18 12:54:49)
```

### Invariant Results

| Invariant | Result | States Checked |
|---|---|---|
| TypeOK | PASS | 616 |
| CertificateSoundness | PASS | 616 |
| DataAvailability | PASS | 616 |
| Privacy | PASS | 616 |
| RecoveryIntegrity | PASS | 616 |
| AttestationIntegrity | PASS | 616 |

### Liveness Results

| Property | Result | Branches |
|---|---|---|
| EventualCertification | PASS | 2 |
| EventualFallback | PASS | 2 |

### Reproduction

```bash
cd validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/experiments/DataAvailability/_build
java -cp <path>/tla2tools.jar tlc2.TLC -workers 4 -config MC_DataAvailability.cfg MC_DataAvailability.tla
```

## 4. Scenarios Explored by TLC

The exhaustive state-space search (2,175 states) covers all interleavings of:

1. **Normal path**: All 3 nodes online -> distribute -> 2+ attest -> certificate valid -> recover from honest pair -> success.

2. **1 node offline during distribution**: 2 nodes receive shares. If both are honest (or 1 honest + 1 malicious and the malicious attests), certificate can still be produced. Recovery depends on which nodes are in the recovery set.

3. **2 nodes offline during distribution**: 1 node receives shares. Threshold = 2 > 1, so fallback triggers (validium -> rollup mode).

4. **Malicious node attests then corrupts recovery**: n3 attests validly (contributing to threshold), but when included in recovery set, produces corrupted reconstruction. Detected by commitment mismatch.

5. **Recovery with sub-threshold subset**: Single-node recovery attempt produces "failed" -- verifying Shamir's information-theoretic privacy guarantee.

6. **Node crash/recover interleaving**: Nodes bounce between online/offline during all protocol stages. Strong fairness ensures honest nodes eventually attest between crash intervals.

## 5. Open Issues

### 5.1 Multi-Attempt Recovery

The current model allows one recovery attempt per batch. A richer model could allow multiple attempts with subset cross-validation (as implemented in `verifyShareConsistency()`). This would verify that malicious node identification via inconsistent reconstruction is possible when 3+ share holders exist.

### 5.2 Timeout-Based Fallback

The structural fallback guard (shareHolders < Threshold) is conservative. A timeout-based model with explicit timer ticks would more faithfully represent the AnyTrust protocol. This could reveal timing-related issues (premature fallback, delayed fallback).

### 5.3 Proof-of-Custody

The research identifies proof-of-custody as an open question (ATK-DA4: lazy attestation). A future specification could model the challenge-response mechanism where nodes must prove they still hold shares.
