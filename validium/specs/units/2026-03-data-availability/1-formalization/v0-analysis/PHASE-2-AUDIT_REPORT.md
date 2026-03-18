# Phase 2: Audit Report -- Data Availability Committee

**Unit**: RU-V6 Data Availability Committee with Shamir Secret Sharing
**Target**: validium
**Date**: 2026-03-18
**Verdict**: PASS -- Formalization faithfully represents the source protocol

---

## 1. Structural Mapping

### 1.1 State Variables

| Source (0-input/) | Specification | Faithful? |
|---|---|---|
| `DACNode.online` (dac-node.ts) | `nodeOnline: [Nodes -> BOOLEAN]` | YES |
| `DACNode.state` map (dac-node.ts) | `shareHolders: [Batches -> SUBSET Nodes]` | YES -- abstracts Map<batchId, DACNodeState> to set membership |
| `DACNodeState.attested` (types.ts) | `attested: [Batches -> SUBSET Nodes]` | YES -- per-node boolean lifted to per-batch set |
| `DACCertificate.valid` (types.ts) | `certState: [Batches -> {"none","valid","fallback"}]` | YES -- adds "fallback" state for AnyTrust path |
| Recovery result (dac-protocol.ts) | `recoverState: [Batches -> ...]` | YES -- 4-valued enum for outcome classification |
| Recovery set (dac-protocol.ts L184) | `recoveryNodes: [Batches -> SUBSET Nodes]` | YES -- tracks which nodes contributed shares |

### 1.2 State Transitions (Actions)

| Source Function | TLA+ Action | Guards Match? | Effects Match? |
|---|---|---|---|
| `DACProtocol.distributeShares()` | `DistributeShares(b)` | YES: checks not-yet-distributed | YES: sets shareHolders to online nodes |
| `DACNode.attest()` | `NodeAttest(n, b)` | YES: online, has shares, not attested | YES: adds to attested set |
| `DACProtocol.collectAttestations()` | `ProduceCertificate(b)` | YES: attestation count >= threshold | YES: sets certState to "valid" |
| Fallback logic (L117) | `TriggerFallback(b)` | CONSERVATIVE: uses structural impossibility vs timeout | YES: sets certState to "fallback" |
| `DACProtocol.recoverData()` | `RecoverData(b, S)` | YES: post-certificate, online share-holders | ENRICHED: models corrupted outcome |
| `DACNode.setOnline(false)` | `NodeFail(n)` | YES: node must be online | YES: sets offline |
| `DACNode.setOnline(true)` | `NodeRecover(n)` | YES: node must be offline | YES: sets online, shares preserved |

### 1.3 Invariant Mapping

| Research Invariant | TLA+ Property | Faithful? |
|---|---|---|
| INV-DA1 (Share Privacy) | `Privacy` | YES -- Shamir k-1 threshold modeled structurally |
| INV-DA2 (Data Recoverability) | `DataAvailability` | YES -- k honest shares => success |
| INV-DA3 (Attestation Soundness) | `CertificateSoundness` | YES -- valid cert => threshold met |
| INV-DA4 (Liveness Fallback) | `EventualFallback` | YES -- structural impossibility => eventual fallback |
| INV-DA5 (Commitment Binding) | `RecoveryIntegrity` | YES -- success => no malicious in set (commitment check abstraction) |

## 2. Hallucination Detection

### 2.1 Mechanisms Checked Against Source

| Mechanism in Spec | Present in Source? | Verdict |
|---|---|---|
| Share distribution to online nodes only | YES: `DACNode.receiveShares()` returns false when `!this.online` | FAITHFUL |
| Both honest and malicious can attest | YES: `attest()` has no honesty check, only online + has shares | FAITHFUL |
| Malicious corrupts recovery | ENRICHED: source uses `verifyShareConsistency()` for detection; spec models outcome directly | SOUND ENRICHMENT |
| Structural fallback condition | CONSERVATIVE: source uses timeout; spec uses permanent impossibility | SOUND UNDER-APPROXIMATION |
| Persistent share storage across crashes | YES: `DACNodeState` is stored in `Map`, no volatile annotation; spec preserves `shareHolders` across NodeFail/NodeRecover | FAITHFUL |
| Single recovery attempt | SIMPLIFICATION: source allows multiple subset attempts via `verifyShareConsistency()` | DOCUMENTED |

### 2.2 Invented Mechanisms

**None found.** Every action, guard, and variable in the specification traces to a concrete function, condition, or data structure in the source code. The three enrichments (corrupted recovery outcome, structural fallback, single recovery attempt) are documented abstractions that are conservative with respect to the source protocol.

## 3. Omission Detection

### 3.1 Source Features Not Modeled

| Feature | Source Location | Impact | Justification for Omission |
|---|---|---|---|
| Batch ID generation | `dac-protocol.ts:69-73` | None -- IDs are opaque identifiers | Abstracted as CONSTANT set |
| SHA-256 commitment computation | `shamir.ts:187` | None -- commitment is a protocol detail | Abstracted into recovery outcome |
| ECDSA signature generation | `dac-node.ts:82-85` | None -- signature correctness is per-node | Abstracted as boolean attestation |
| Attestation timeout | `types.ts:DACConfig.attestationTimeoutMs` | MINOR -- timeout-based fallback not modeled | Structural fallback is more conservative |
| Share verification at receive time | `dac-node.ts:56-64` | None -- honest distribution assumed | Source also trusts distributor |
| Storage overhead tracking | `dac-node.ts:121-130` | None -- performance metric, not protocol | Not a safety/liveness concern |
| Multiple recovery attempts with cross-validation | `shamir.ts:verifyShareConsistency()` | MINOR -- single-attempt model is weaker | TLC explores all possible subsets anyway |
| BLS signature aggregation (future) | REPORT.md | None -- not implemented in current design | Out of scope for (2,3) committee |
| KZG commitment verification (future) | REPORT.md, open question OQ-11 | None -- not implemented | Future extension, not current protocol |

### 3.2 Critical Side-Effects Checked

| Side-Effect | Modeled? | Notes |
|---|---|---|
| Online node receives shares -> stored persistently | YES | `shareHolders` persists across NodeFail/NodeRecover |
| Offline node misses share distribution | YES | `DistributeShares` filters by `nodeOnline[n]` |
| Node that missed distribution can never attest | YES | `NodeAttest` requires `n \in shareHolders[b]` |
| Attestation is irreversible (once attested, always attested) | YES | `attested` set only grows, never shrinks |
| Certificate production is irreversible | YES | `certState` transitions: none -> valid or none -> fallback, no reversal |
| Recovery outcome depends on subset composition | YES | Three-way outcome based on |S|, S vs Malicious |

## 4. Consistency Verification

### 4.1 Fairness Analysis

| Action | Fairness | Justification |
|---|---|---|
| `NodeAttest(n, b)` for honest n | SF (strong) | Honest nodes cooperate but crashes interrupt -- SF handles intermittent enabling |
| `ProduceCertificate(b)` | WF (weak) | Once threshold met, guard holds continuously until certificate produced |
| `TriggerFallback(b)` | WF (weak) | Structural impossibility is permanent -- guard holds continuously once true |
| `NodeRecover(n)` | WF (weak) | Only action enabled when offline; nothing can preempt it |
| `NodeFail(n)` | None | Environmental event -- no obligation to crash |
| `NodeAttest(n, b)` for malicious n | None | Adversarial choice -- may refuse indefinitely |
| `RecoverData(b, S)` | None | Recovery is an operational choice, not a protocol obligation |
| `DistributeShares(b)` | None | Initiated by the system operator, not a fairness concern |

The fairness assignment is consistent with standard distributed systems modeling (Lamport, "Specifying Systems", Ch. 8).

### 4.2 Symmetry Check

- **Nodes**: n1 and n2 are symmetric (both honest). n3 is distinct (malicious). TLC explores all permutations.
- **Batches**: Single batch, so no symmetry reduction needed.
- **Recovery subsets**: All 2^3 = 8 subsets of {n1, n2, n3} are explored by TLC's existential quantification.

### 4.3 State Space Coverage

The 616 distinct states (2,175 total) at depth 10 cover:

| Node Configuration | Share Distribution | Certificate | Recovery | States |
|---|---|---|---|---|
| All online | All 3 have shares | Valid | All outcomes | Majority |
| 1 offline (each node) | 2 have shares | Valid or None | Subset outcomes | Significant |
| 2 offline (each pair) | 1 has shares | Fallback | None (sub-threshold) | Small set |
| All offline | None | None | None | Minimal |

## 5. Verdict

**PASS.** The formalization faithfully represents the Data Availability Committee protocol as defined in the research materials. All source state transitions, guard conditions, and invariants are accounted for. The three documented abstractions (cryptographic operations, structural fallback, single recovery attempt) are sound and conservative. No hallucinated mechanisms were introduced. No critical omissions were found.

The specification is ready for downstream consumption by the Prime Architect (implementation) and the Prover (Coq certification).
