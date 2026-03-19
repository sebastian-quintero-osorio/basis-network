# Session Log: Cross-Enterprise Verification

**Date**: 2026-03-18
**Target**: validium
**Unit**: 2026-03-cross-enterprise
**Mode**: Verification (Mode A)
**Status**: COMPLETE -- 13 theorems Qed, 0 Admitted

---

## Input Artifacts

- **TLA+ Specification**: `validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/specs/CrossEnterprise/CrossEnterprise.tla`
  - 251 lines, 6 actions, 3 safety properties, 1 liveness property
  - TLC model-checked with 2 enterprises, 2 batches, 2 state roots
- **TypeScript Implementation**: `validium/node/src/cross-enterprise/cross-reference-builder.ts`
  - 443 lines, 2 exported functions + helpers
  - Enforces NoCrossRefSelfLoop, Consistency gate, Merkle proof verification
- **Solidity Implementation**: `l1/contracts/contracts/verification/CrossEnterpriseVerifier.sol`
  - 451 lines, inline Groth16 verification via EIP-196/197 precompiles
  - Enforces all 3 safety invariants on-chain

## Work Performed

### 1. Verification Unit Creation

Created `validium/proofs/units/2026-03-cross-enterprise/` with:
- `0-input-spec/`: Frozen TLA+ spec (CrossEnterprise.tla)
- `0-input-impl/`: Frozen implementations (cross-reference-builder.ts, CrossEnterpriseVerifier.sol)
- `1-proofs/`: Common.v, Spec.v, Impl.v, Refinement.v
- `2-reports/`: verification.log, SUMMARY.md

### 2. Proof Construction

**Common.v** (207 lines): Standard library for the unit.
- Base types: Enterprise, BatchId, StateRoot (all nat), GenesisRoot parameter
- Status types: batch_status (Idle/Submitted/Verified), crossref_status (CRNone/CRPending/CRVerified/CRRejected)
- CrossRefId record with boolean equality (crossrefid_eqb) and 3 iff lemmas
- Functional updates: fupdate1 (1-level), fupdate2 (2-level), fupdate_cr (CrossRefId-level)
- Key lemmas: fupdate2_neq_pair (pair inequality), fupdate2_to_same (value preservation)
- destruct_match tactic

**Spec.v** (193 lines): Faithful TLA+ translation.
- State record: 4 fields matching TLA+ variables
- 6 action preconditions and 6 action definitions
- Step inductive relation with 6 constructors
- 3 safety property definitions: Isolation, Consistency, NoCrossRefSelfLoop

**Impl.v** (135 lines): Implementation correspondence documentation.
- State mapping: Solidity CrossEnterpriseVerifier state -> Spec.State
- Action correspondence: 5 implementation paths -> 6 TLA+ actions
- Isolation enforcement: both implementations preserve state root immutability
- Consistency enforcement: both check batch verification before cross-ref
- Groth16 abstraction: proof validity modeled as action guard satisfaction

**Refinement.v** (332 lines): Safety property proofs.
- Part 1: 3 initialization theorems
- Part 2: Isolation preservation (6 actions, focus on VerifyBatch witness construction)
- Part 3: Consistency preservation (6 actions, focus on batch monotonicity)
- Part 4: NoCrossRefSelfLoop preservation (6 actions, structural from guards)
- Part 5: Combined inductive invariant
- Part 6: 4 corollaries (root preservation, both-verified, witness existence, distinct endpoints)

### 3. Compilation

All 4 files compiled successfully with Rocq Prover 9.0.1:
```
coqc -Q . CE Common.v      PASS
coqc -Q . CE Spec.v         PASS
coqc -Q . CE Impl.v         PASS
coqc -Q . CE Refinement.v   PASS
```

No Admitted. 13 theorems Qed.

## Key Proof Strategies

### Isolation (Enterprise Data Sovereignty)

The core challenge: proving that `currentRoot[e]` is determined solely by enterprise
`e`'s own verified batches, never by cross-enterprise actions.

- **VerifyBatch**: The only action that advances currentRoot. It sets `currentRoot[e] =
  batchNewRoot[e][b]` while simultaneously marking `batchStatus[e][b] = Verified`.
  The batch `b` itself serves as the existential witness for the Isolation property.

- **SubmitBatch/FailBatch**: These actions modify batches with Idle/Submitted status.
  The witness batch from the induction hypothesis has Verified status. If the witness
  position (e0, b0) coincides with the modified position (e, b), we derive a status
  contradiction (Verified vs Idle/Submitted) via `congruence`. The `fupdate2_neq_pair`
  lemma encapsulates this pair-inequality argument cleanly.

- **Cross-ref actions**: All three (Request, Verify, Reject) have
  `UNCHANGED << currentRoot, batchStatus, batchNewRoot >>`. After unfold and simpl,
  the property reduces to exactly the induction hypothesis. Proved with `exact (HIso e0)`.

### Consistency (Cross-Reference Validity)

The core challenge: proving that a verified cross-reference always has both constituent
batch proofs verified on L1.

- **VerifyCrossRef**: The only action that sets crossRefStatus to CRVerified. Its guard
  explicitly requires `batchStatus[src][srcBatch] = Verified` and
  `batchStatus[dst][dstBatch] = Verified`. When ref0 = ref, the guard provides the
  proof directly. When ref0 <> ref, the IH applies.

- **Batch monotonicity**: The key supporting argument. Once batchStatus reaches Verified,
  no action can downgrade it. SubmitBatch fires only on Idle batches; FailBatch fires
  only on Submitted batches. This means any Verified batch backing a verified cross-ref
  remains Verified after any batch action. The `fupdate2_to_same` lemma handles the
  VerifyBatch case elegantly: updating to Verified preserves any position already at Verified.

- **Request/Reject**: These set crossRefStatus to CRPending/CRRejected respectively.
  Since neither equals CRVerified, the Consistency hypothesis is vacuously false (discriminate).

### NoCrossRefSelfLoop (Structural)

All cross-ref actions require `valid_ref ref` (src <> dst) in their guards. For batch
actions, crossRefStatus is unchanged. The proof pattern uses `crossrefid_eqb` destruct
followed by either guard extraction (true branch) or IH application (false branch).

## Decisions and Rationale

1. **CrossRefId as record with boolean equality**: Used a 4-field record with
   `crossrefid_eqb` and iff lemmas rather than 4 separate function parameters.
   This mirrors the TLA+ CrossRefIds structure and produces cleaner theorems.

2. **fupdate2_neq_pair lemma**: Centralized the "pair inequality from value
   contradiction" argument. This lemma eliminates repeated Nat.eq_dec case splits
   in Isolation and Consistency proofs, reducing proof verbosity significantly.

3. **fupdate2_to_same lemma**: Captured the batch monotonicity argument in a single
   lemma. When updating to Verified, any position already at Verified stays at Verified.
   This made the VerifyBatch case of Consistency a one-liner per conjunct.

4. **Minimal Impl.v**: The TypeScript + Solidity implementation directly realizes the
   TLA+ state machine. Rather than modeling a separate Impl state, Impl.v documents
   the correspondence. The proof effort focuses on safety properties of the Spec.

## Axiom Trust Base

- `GenesisRoot : StateRoot` -- a parameter with no axioms on its value.
  Represents the initial state root for all enterprises.
  Enforced by implementation: genesis block configuration.

No additional axioms. Minimal trust base.

## Next Steps

- This completes RU-V7 (Cross-Enterprise) in the validium verification pipeline.
- All 7 validium units now verified: RU-V1 (SMT), RU-V2 (State Transition),
  RU-V3 (State Commitment), RU-V4 (Batch Aggregation), RU-V5 (Enterprise Node),
  RU-V6 (Data Availability), RU-V7 (Cross-Enterprise).
- The validium MVP verification pipeline is COMPLETE.
