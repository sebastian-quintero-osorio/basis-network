# Verification Summary: Data Availability Committee (RU-V6)

**Unit**: 2026-03-data-availability
**Target**: validium
**Date**: 2026-03-18
**Compiler**: Rocq Prover 9.0.1
**Status**: PASS -- 16 theorems Qed, 0 Admitted

---

## Input Artifacts

| Artifact | Path |
|----------|------|
| TLA+ Spec | `0-input-spec/DataAvailability.tla` (318 lines, TLC-verified) |
| TypeScript Impl | `0-input-impl/{shamir,dac-node,dac-protocol,types}.ts` (1249 lines, 167 tests) |

## Proof Files

| File | Lines | Purpose |
|------|-------|---------|
| `Common.v` | 218 | Types, set operations, functional updates, tactics |
| `Spec.v` | 233 | Faithful translation of DataAvailability.tla to Coq |
| `Impl.v` | 127 | Implementation correspondence documentation |
| `Refinement.v` | 356 | Safety property proofs (16 theorems Qed) |

## Verified Safety Properties

### 1. CertificateSoundness (TLA+ lines 239-241)

```
forall b, certState b = CertValid -> length (attested b) >= Threshold
```

A valid DACCertificate can only be produced when at least `Threshold` nodes
have signed attestations. Corresponds to on-chain verification logic in
`DACProtocol.verify()` (dac-protocol.ts lines 321-373).

**Proof strategy**: Only `ProduceCertificate` sets certState to CertValid,
and its guard requires `length (attested b) >= Threshold`. No action removes
attestations. NodeAttest's guard (`certState b = CertNone`) prevents
attestation changes after certification.

### 2. DataAvailability (TLA+ lines 250-255)

```
forall b,
  recoverState b <> RecNone ->
  subset (recoveryNodes b) Honest ->
  length (recoveryNodes b) >= Threshold ->
  recoverState b = RecSuccess
```

If recovery is attempted with at least `Threshold` honest nodes, the
Lagrange interpolation succeeds and data matches the SHA-256 commitment.
This is the fundamental data availability guarantee: honest supermajority
ensures data recoverability.

**Proof strategy**: `RecoverData` is the only action that modifies
recovery state. When `subset S Honest` and `|S| >= Threshold`:
(1) `Honest = Nodes \ Malicious` implies `disjoint S Malicious`,
(2) `has_member_in S Malicious = false`,
(3) `recover_outcome S = RecSuccess`.

### 3. Privacy (TLA+ lines 264-266)

```
forall b, recoverState b = RecSuccess -> length (recoveryNodes b) >= Threshold
```

Successful data reconstruction requires at least `Threshold` shares.
This models the information-theoretic privacy guarantee of Shamir's
(k,n)-SSS: k-1 shares reveal zero information about the secret, even
against computationally unbounded adversaries (Shamir, CACM 1979).

**Proof strategy**: `recover_outcome S` returns `RecFailed` when
`|S| < Threshold`. Therefore `RecSuccess` implies `|S| >= Threshold`.

### 4. RecoveryIntegrity (TLA+ lines 275-277)

```
forall b, recoverState b = RecSuccess -> disjoint (recoveryNodes b) Malicious
```

Successful recovery implies no malicious node participated. If a malicious
node provides corrupted shares, Lagrange interpolation produces incorrect
data, detected by SHA-256 commitment mismatch (`RecCorrupted`).

**Proof strategy**: `recover_outcome S` returns `RecCorrupted` when
`has_member_in S Malicious = true`. Therefore `RecSuccess` implies
`has_member_in S Malicious = false`, which is `disjoint S Malicious`.

### 5. AttestationIntegrity (TLA+ lines 285-287)

```
forall b, subset (attested b) (shareHolders b)
```

Only nodes that received and stored Shamir shares during Phase 1 can
sign attestations in Phase 2. A node without shares cannot fabricate
a valid attestation.

**Proof strategy**: `NodeAttest` adds `n` to `attested b` only with
guard `In n (shareHolders b)`. `DistributeShares` changes `shareHolders b`
only when it was empty (guard `shareHolders b = []`), and the invariant
ensures `attested b` was also empty, so the subset relation is trivially
maintained.

## Theorem Summary

| # | Theorem | Status |
|---|---------|--------|
| 1 | `cert_soundness_init` | Qed |
| 2 | `data_availability_init` | Qed |
| 3 | `privacy_init` | Qed |
| 4 | `recovery_integrity_init` | Qed |
| 5 | `attestation_integrity_init` | Qed |
| 6 | `cert_soundness_preserved` | Qed |
| 7 | `privacy_preserved` | Qed |
| 8 | `recovery_integrity_preserved` | Qed |
| 9 | `data_availability_preserved` | Qed |
| 10 | `attestation_integrity_preserved` | Qed |
| 11 | `all_invariants_init` | Qed |
| 12 | `all_invariants_preserved` | Qed |
| 13 | `invariants_reachable` | Qed |
| 14 | `no_single_node_reconstruction` | Qed |
| 15 | `honest_recovery_succeeds` | Qed |
| 16 | `recovery_implies_honest` | Qed |

## Axiom Trust Base

| Axiom | Justification |
|-------|--------------|
| `threshold_ge_1 : Threshold >= 1` | TLA+ ASSUME (line 34), config validation (types.ts line 55) |
| `malicious_subset : subset Malicious Nodes` | TLA+ ASSUME (line 36), committee membership definition |

## Key Design Decisions

1. **le_lt_dec for recover_outcome**: Used decidable comparison (`le_lt_dec`)
   instead of boolean `Nat.ltb` for `recover_outcome`. This yields Prop-level
   hypotheses directly in proof decomposition, avoiding boolean-to-Prop
   conversion lemmas.

2. **Functional updates**: Modeled TLA+ `[f EXCEPT ![k] = v]` as
   `fupdate f k v` with `Nat.eqb`-based case split. Each action's proof
   reduces to batch-equality case analysis.

3. **Disjointness via has_member_in**: Connected set disjointness to the
   boolean `has_member_in` function, enabling direct proof of
   RecoveryIntegrity from the `recover_outcome` definition.

## Cross-Reference

| TLA+ Property | Coq Theorem | Implementation Check |
|---------------|-------------|---------------------|
| CertificateSoundness | `cert_soundness_preserved` | `DACProtocol.verify()` checks signatureCount >= threshold |
| DataAvailability | `data_availability_preserved` | `DACProtocol.recover()` returns SUCCESS with honest shares |
| Privacy | `privacy_preserved` | `shamir.recover()` requires >= k shares for interpolation |
| RecoveryIntegrity | `recovery_integrity_preserved` | SHA-256 commitment check in `DACProtocol.recover()` |
| AttestationIntegrity | `attestation_integrity_preserved` | `DACNode.attest()` requires `nodeState` (shares stored) |
